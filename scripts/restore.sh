#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  restore.sh — disaster recovery from a backup snapshot.
#
#  Usage:
#    ./scripts/restore.sh <YYYY-MM-DD>      # restore from local backups/
#    ./scripts/restore.sh <YYYY-MM-DD> /mnt/external/backups
#
#  Run on BM1 with the stack already deployed (services up). The script will
#  put the relevant service into maintenance, restore data, and bring it back.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found"; exit 1; }
set -a; source .env; set +a

DATE="${1:?usage: restore.sh <YYYY-MM-DD> [backups-dir]}"
SRC="${2:-/opt/posthog/data/backups}"

PG_FILE="$SRC/postgres/posthog-$DATE.sql.gz"
CH_FILE="$SRC/clickhouse/posthog-$DATE.tar.zst"

[[ -f "$PG_FILE" ]] || { echo "missing $PG_FILE"; exit 1; }
[[ -f "$CH_FILE" ]] || { echo "missing $CH_FILE"; exit 1; }

log() { printf '\e[1;31m[restore]\e[0m %s\n' "$*"; }

read -rp "This will OVERWRITE the live Postgres and ClickHouse data from $DATE. Type 'yes' to proceed: " ANS
[[ "$ANS" == "yes" ]] || { echo aborted; exit 1; }

# Scale down consumers so they can't write during restore.
log "scaling down web/worker/plugin-server"
for svc in web worker plugin-server; do
    docker service scale "posthog_$svc=0" >/dev/null
done

# ── Postgres ─────────────────────────────────────────────────────────────────
log "restoring postgres from $PG_FILE"
gunzip -c "$PG_FILE" | \
    docker run --rm -i --network posthog_posthog_net \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        postgres:${POSTGRES_IMAGE_TAG:-15.12-alpine} \
        psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1

# ── ClickHouse ───────────────────────────────────────────────────────────────
log "restoring clickhouse from $CH_FILE"
CH_CTR=$(docker ps -qf name=posthog_clickhouse)
TMP=$(docker exec "$CH_CTR" mktemp -d)
zstd -dc "$CH_FILE" | docker exec -i "$CH_CTR" tar -C "$TMP" -xf -
docker exec "$CH_CTR" clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --query "RESTORE DATABASE $CLICKHOUSE_DATABASE FROM Disk('default', '$TMP/backup')"
docker exec "$CH_CTR" rm -rf "$TMP"

# ── Scale back up ────────────────────────────────────────────────────────────
log "scaling services back up"
docker service scale \
    posthog_web=2 \
    posthog_worker=1 \
    posthog_plugin-server=1 >/dev/null

log "restore complete"
