#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  deploy.sh — apply the stack to the swarm.
#
#  Run on BM1 (the manager) after bootstrap-host.sh + init-swarm.sh.
#  Idempotent: safe to run repeatedly to roll new image tags / config changes.
#
#  Flags:
#    --no-prepull   skip the per-node docker pull (faster reruns)
#    --quiet        less progress output during convergence wait
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found"; exit 1; }
set -a; source .env; set +a

STACK_NAME="${STACK_NAME:-posthog}"
PREPULL=1
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --no-prepull) PREPULL=0 ;;
        --quiet)      QUIET=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 1 ;;
    esac
done

c_blu='\e[1;34m'; c_grn='\e[1;32m'; c_yel='\e[1;33m'; c_red='\e[1;31m'; c_off='\e[0m'
log()   { printf "${c_blu}▶${c_off} %s\n" "$*"; }
ok()    { printf "${c_grn}✓${c_off} %s\n" "$*"; }
warn()  { printf "${c_yel}!${c_off} %s\n" "$*"; }
err()   { printf "${c_red}✗${c_off} %s\n" "$*" >&2; }

# ─── Sanity ───────────────────────────────────────────────────────────────────
DATA_NODES=$(docker node ls -q -f node.label=posthog.role=data | wc -l)
APP_NODES=$(docker node ls -q -f node.label=posthog.role=app  | wc -l)
if [[ "$DATA_NODES" -ne 1 || "$APP_NODES" -ne 1 ]]; then
    err "expected exactly one 'data' and one 'app' node — got data=$DATA_NODES app=$APP_NODES"
    docker node ls
    exit 1
fi
ok "node labels look correct (data=$DATA_NODES, app=$APP_NODES)"

# ─── Discover images from the resolved stack config ───────────────────────────
log "Resolving image list from docker-stack.yml"
mapfile -t IMAGES < <(
    docker stack config -c docker-stack.yml 2>/dev/null \
      | grep -E '^\s+image:' | awk '{print $2}' | sort -u
)
for i in "${IMAGES[@]}"; do echo "    • $i"; done

# ─── Pre-pull: stream output, pull on each node directly ──────────────────────
if [[ "$PREPULL" == "1" ]]; then
    log "Pre-pulling on BM1 (local)"
    for img in "${IMAGES[@]}"; do
        printf "  ${c_blu}↓${c_off} %s ... " "$img"
        if docker pull --quiet "$img" >/dev/null 2>&1; then
            printf "${c_grn}done${c_off}\n"
        else
            printf "${c_red}FAILED${c_off} — retrying with full output\n"
            docker pull "$img" || warn "pull failed for $img — stack deploy will retry"
        fi
    done

    if [[ -n "${BM2_SSH:-}" ]]; then
        log "Pre-pulling on BM2 via ssh ($BM2_SSH)"
        for img in "${IMAGES[@]}"; do
            printf "  ${c_blu}↓${c_off} %s ... " "$img"
            if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$BM2_SSH" \
                   "docker pull --quiet $img" >/dev/null 2>&1; then
                printf "${c_grn}done${c_off}\n"
            else
                printf "${c_red}FAILED${c_off} — retrying with full output\n"
                ssh "$BM2_SSH" "docker pull $img" || warn "pull failed for $img on BM2"
            fi
        done
    else
        warn "BM2_SSH not set in .env — skipping remote pre-pull (Swarm will pull on demand)"
    fi
else
    warn "skipping pre-pull (--no-prepull)"
fi

# ─── Deploy ──────────────────────────────────────────────────────────────────
log "Deploying stack '$STACK_NAME'"
docker stack deploy \
    --detach=false \
    --with-registry-auth \
    --resolve-image=always \
    -c docker-stack.yml \
    "$STACK_NAME"

# ─── Convergence wait with live status ────────────────────────────────────────
log "Waiting for services to converge..."
DEADLINE=$(( $(date +%s) + 600 ))   # 10 min
PREV=""
while (( $(date +%s) < DEADLINE )); do
    STATUS=$(docker stack services "$STACK_NAME" \
        --format '{{.Name}}\t{{.Replicas}}\t{{.Image}}' \
        | awk '{printf "%-32s %-10s %s\n", $1, $2, $3}')
    PENDING=$(echo "$STATUS" | awk '$2 !~ /^([0-9]+)\/\1$/ {n++} END{print n+0}')
    if [[ "$QUIET" == "0" && "$STATUS" != "$PREV" ]]; then
        clear
        echo "── stack: $STACK_NAME ──────────────────────────────────────────────"
        echo "$STATUS"
        echo "── pending: $PENDING service(s)"
        PREV="$STATUS"
    fi
    [[ "$PENDING" == "0" ]] && break
    sleep 3
done

echo
if [[ "$PENDING" -ne 0 ]]; then
    warn "$PENDING service(s) still not at desired replicas after 10 min"
    log "Inspecting failing tasks:"
    docker stack ps "$STACK_NAME" --no-trunc --filter "desired-state=running" \
        | awk 'NR==1 || $0 ~ /Error|Reject|Failed|Preparing|Starting/'
    echo
    log "For details:  docker service ps posthog_<name> --no-trunc"
    exit 1
fi

ok "all services converged"
echo
docker stack services "$STACK_NAME"
echo
log "Logs:        docker service logs -f ${STACK_NAME}_web"
log "Migrations:  docker service logs ${STACK_NAME}_migrate"
log "First user:  docker exec -it \$(docker ps -qf name=${STACK_NAME}_web) python manage.py createsuperuser"
