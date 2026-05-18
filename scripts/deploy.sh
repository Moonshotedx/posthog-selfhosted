#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  deploy.sh — apply the stack to the swarm.
#
#  Run on BM1 (the manager) after bootstrap-host.sh + init-swarm.sh.
#  Idempotent: safe to run repeatedly to roll new image tags / config changes.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found"; exit 1; }
set -a; source .env; set +a

STACK_NAME="${STACK_NAME:-posthog}"

log() { printf '\e[1;34m▶\e[0m %s\n' "$*"; }

# Sanity: both labels present?
DATA_NODES=$(docker node ls -q -f node.label=posthog.role=data | wc -l)
APP_NODES=$(docker node ls -q -f node.label=posthog.role=app | wc -l)
if [[ "$DATA_NODES" -ne 1 || "$APP_NODES" -ne 1 ]]; then
    echo "expected exactly one node labelled 'data' and one 'app' — got data=$DATA_NODES app=$APP_NODES" >&2
    docker node ls
    exit 1
fi

# Pre-pull images on each node so the rollout doesn't stall on download.
log "Pre-pulling images on all nodes"
docker stack config -c docker-stack.yml 2>/dev/null | \
    grep -E '^\s+image:' | awk '{print $2}' | sort -u | \
    while read -r img; do
        echo "  pulling $img"
        # Push to both nodes by running a temporary global service that does
        # a docker pull. The image cache persists per-node.
        docker service create --name pull-$$ --mode global --restart-condition none \
            --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
            docker:cli pull "$img" >/dev/null 2>&1 || true
        docker service rm pull-$$ >/dev/null 2>&1 || true
    done

log "Deploying stack '$STACK_NAME'"
docker stack deploy \
    --detach=false \
    --with-registry-auth \
    --resolve-image=always \
    -c docker-stack.yml \
    "$STACK_NAME"

log "Waiting for services to converge..."
for _ in $(seq 1 60); do
    PENDING=$(docker stack services "$STACK_NAME" --format '{{.Replicas}}' | \
        awk -F/ '$1!=$2 {n++} END{print n+0}')
    [[ "$PENDING" == "0" ]] && break
    sleep 5
done

echo
docker stack services "$STACK_NAME"
echo
log "Deployment complete. Watch logs with:  docker service logs -f ${STACK_NAME}_web"
