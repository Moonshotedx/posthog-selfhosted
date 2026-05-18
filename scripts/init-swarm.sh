#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  init-swarm.sh — runs ONCE on BM1.
#
#  Initializes the Docker Swarm, prints the join command, optionally ssh's to
#  BM2 to join automatically, and then applies node role labels.
#
#  Idempotent: rerun to re-label nodes.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found"; exit 1; }
set -a; source .env; set +a

: "${BM1_LAN_IP:?BM1_LAN_IP must be set}"
: "${BM2_LAN_IP:?BM2_LAN_IP must be set}"

log() { printf '\e[1;34m▶\e[0m %s\n' "$*"; }

# ── 1. Initialize the swarm (or detect we are already in one) ────────────────
if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
    log "Initializing swarm on $BM1_LAN_IP"
    docker swarm init --advertise-addr "$BM1_LAN_IP"
else
    log "Swarm already initialized — skipping init"
fi

JOIN_TOKEN=$(docker swarm join-token -q worker)
JOIN_CMD="docker swarm join --token $JOIN_TOKEN $BM1_LAN_IP:2377"

# ── 2. Join BM2 ──────────────────────────────────────────────────────────────
if [[ -n "${BM2_SSH:-}" ]]; then
    log "Joining BM2 via ssh ($BM2_SSH)"
    ssh -o StrictHostKeyChecking=accept-new "$BM2_SSH" "$JOIN_CMD || true"
else
    cat <<EOF

────────────────────────────────────────────────────────────────────────────────
 Run this command on BM2 to join the swarm:

   $JOIN_CMD

 Then press ENTER here to continue.
────────────────────────────────────────────────────────────────────────────────
EOF
    read -r
fi

# ── 3. Wait for both nodes ───────────────────────────────────────────────────
log "Waiting for 2 nodes to be Ready..."
for _ in $(seq 1 30); do
    READY=$(docker node ls --format '{{.Status}}' | grep -c Ready || true)
    [[ "$READY" -ge 2 ]] && break
    sleep 2
done
[[ "$READY" -ge 2 ]] || { echo "BM2 did not join in time"; docker node ls; exit 1; }

# ── 4. Apply node labels ─────────────────────────────────────────────────────
log "Applying node labels"
# Find each node's ID by its ManagerStatus / Address
while IFS= read -r line; do
    ID=$(echo "$line" | awk '{print $1}')
    ADDR=$(docker node inspect "$ID" --format '{{.Status.Addr}}')
    case "$ADDR" in
        "$BM1_LAN_IP") ROLE=data ;;
        "$BM2_LAN_IP") ROLE=app ;;
        *) echo "unexpected node addr $ADDR — skipping"; continue ;;
    esac
    docker node update --label-add "posthog.role=$ROLE" "$ID" >/dev/null
    echo "  $ADDR → posthog.role=$ROLE"
done < <(docker node ls --format '{{.ID}}')

docker node ls
log "swarm ready"
