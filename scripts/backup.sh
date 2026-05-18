#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  backup.sh — nightly backup of Postgres + ClickHouse + MinIO.
#
#  Cron entry (on BM1):
#    0 2 * * * /opt/posthog-selfhosted/scripts/backup.sh >> /var/log/posthog-backup.log 2>&1
#
#  Output layout (under /opt/posthog/data/backups/):
#    postgres/posthog-YYYY-MM-DD.sql.gz
#    clickhouse/posthog-YYYY-MM-DD.tar.zst
#    minio/                 (rsync-style mirror of bucket)
#
#  After local capture, the whole backups/ dir is rsync'd to BM2 for off-host
#  durability. If BACKUP_S3_* env vars are set, a second copy goes off-site.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found"; exit 1; }
set -a; source .env; set +a

DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)   # 1=Mon ... 7=Sun  (we keep Mondays as the weekly snapshot)
DEST=/opt/posthog/data/backups
RETAIN_DAILY="${BACKUP_RETAIN_DAILY:-7}"
RETAIN_WEEKLY="${BACKUP_RETAIN_WEEKLY:-4}"

log() { printf '\e[1;34m[backup %s]\e[0m %s\n' "$(date -Is)" "$*"; }

mkdir -p "$DEST"/{postgres,clickhouse,minio}

# ── 1. Postgres ──────────────────────────────────────────────────────────────
log "dumping postgres"
PG_FILE="$DEST/postgres/posthog-$DATE.sql.gz"
docker run --rm --network posthog_posthog_net \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres:${POSTGRES_IMAGE_TAG:-15.12-alpine} \
    pg_dump -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --clean --if-exists \
    | gzip -9 > "$PG_FILE.tmp"
mv "$PG_FILE.tmp" "$PG_FILE"
log "  → $(ls -lh "$PG_FILE" | awk '{print $5}')  $PG_FILE"

# ── 2. ClickHouse ────────────────────────────────────────────────────────────
log "snapshotting clickhouse"
CH_FILE="$DEST/clickhouse/posthog-$DATE.tar.zst"
# Use BACKUP TABLE syntax (CH 22.8+) into a temp dir, then archive.
TMPDIR=$(docker exec "$(docker ps -qf name=posthog_clickhouse)" mktemp -d)
docker exec "$(docker ps -qf name=posthog_clickhouse)" \
    clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --query "BACKUP DATABASE $CLICKHOUSE_DATABASE TO Disk('default', '$TMPDIR/backup')"
# Archive the on-disk backup to the host
docker exec "$(docker ps -qf name=posthog_clickhouse)" \
    tar -C "$TMPDIR" -cf - backup | zstd -3 -T0 > "$CH_FILE.tmp"
mv "$CH_FILE.tmp" "$CH_FILE"
docker exec "$(docker ps -qf name=posthog_clickhouse)" rm -rf "$TMPDIR"
log "  → $(ls -lh "$CH_FILE" | awk '{print $5}')  $CH_FILE"

# ── 3. MinIO ─────────────────────────────────────────────────────────────────
log "mirroring minio"
docker run --rm --network posthog_posthog_net \
    -v "$DEST/minio:/mirror" \
    minio/mc:latest \
    sh -c "mc alias set s http://objectstorage:9000 '$OBJECT_STORAGE_ACCESS_KEY_ID' '$OBJECT_STORAGE_SECRET_ACCESS_KEY' && \
           mc mirror --overwrite --remove s/$OBJECT_STORAGE_BUCKET /mirror/"
log "  → $(du -sh "$DEST/minio" | awk '{print $1}')  $DEST/minio/"

# ── 4. Rotation ──────────────────────────────────────────────────────────────
log "rotating old backups"
# Daily: keep $RETAIN_DAILY most recent per dir
for sub in postgres clickhouse; do
    ls -1t "$DEST/$sub/" 2>/dev/null \
        | tail -n +$((RETAIN_DAILY + 1)) \
        | while read -r f; do rm -f "$DEST/$sub/$f"; log "  removed $sub/$f"; done
done

# Weekly: every Monday, copy that day's files into weekly/ dir
if [[ "$DOW" == "1" ]]; then
    mkdir -p "$DEST/weekly"
    cp -an "$PG_FILE" "$DEST/weekly/" || true
    cp -an "$CH_FILE" "$DEST/weekly/" || true
    ls -1t "$DEST/weekly/" \
        | tail -n +$((RETAIN_WEEKLY * 2 + 1)) \
        | while read -r f; do rm -f "$DEST/weekly/$f"; done
fi

# ── 5. Off-host rsync to BM2 ─────────────────────────────────────────────────
if [[ -n "${BACKUP_REMOTE_RSYNC_TARGET:-}" ]]; then
    log "rsync to $BACKUP_REMOTE_RSYNC_TARGET"
    rsync -aHz --delete-after "$DEST/" "$BACKUP_REMOTE_RSYNC_TARGET"
fi

# ── 6. Optional off-site S3 ──────────────────────────────────────────────────
if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
    log "mirroring to off-site $BACKUP_S3_BUCKET"
    docker run --rm \
        -v "$DEST:/backups" \
        -e MC_HOST_off="https://$BACKUP_S3_ACCESS_KEY:$BACKUP_S3_SECRET_KEY@${BACKUP_S3_ENDPOINT#https://}" \
        minio/mc:latest \
        mc mirror --overwrite /backups "off/$BACKUP_S3_BUCKET/"
fi

log "done"
