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

# Content-hash each config file. Swarm configs are immutable, so the only
# way to update them is to create a new one — we use the hash as the suffix
# so identical content → identical name → no-op redeploy.
hashf() { sha256sum "$1" | cut -c1-12; }
export CADDY_CONFIG_VERSION=$(hashf config/caddy/Caddyfile)
export CLICKHOUSE_CONFIG_VERSION=$(hashf config/clickhouse/config.d/posthog.xml)
export CLICKHOUSE_USERS_VERSION=$(hashf config/clickhouse/users.d/posthog.xml)
log "Config versions:"
echo "    caddyfile=$CADDY_CONFIG_VERSION  clickhouse_config=$CLICKHOUSE_CONFIG_VERSION  clickhouse_users=$CLICKHOUSE_USERS_VERSION"

# One-shot services that exit 0 after completing their job. The convergence
# loop must NOT block on these — they live in 0/1 replicas once "Complete".
ONESHOTS=( migrate objectstorage-init )

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

# ─── Pre-pull on BM1 and BM2 ──────────────────────────────────────────────────
pull_local() {
    local img=$1
    printf "  ${c_blu}↓${c_off} %-60s " "$img"
    if docker pull "$img" >/tmp/pull.log 2>&1; then
        printf "${c_grn}done${c_off}\n"
    else
        printf "${c_red}FAILED${c_off}\n"
        sed 's/^/      /' /tmp/pull.log
        return 1
    fi
}

pull_remote() {
    local img=$1
    printf "  ${c_blu}↓${c_off} %-60s " "$img"
    if ssh -o StrictHostKeyChecking=accept-new "$BM2_SSH" "docker pull '$img'" >/tmp/pull.log 2>&1; then
        printf "${c_grn}done${c_off}\n"
    else
        printf "${c_red}FAILED${c_off}\n"
        sed 's/^/      /' /tmp/pull.log
        return 1
    fi
}

PULL_FAILED=0
if [[ "$PREPULL" == "1" ]]; then
    log "Pre-pulling on BM1"
    for img in "${IMAGES[@]}"; do
        pull_local "$img" || PULL_FAILED=$((PULL_FAILED + 1))
    done

    if [[ -n "${BM2_SSH:-}" ]]; then
        # Detect once whether key-based auth works; if not, warn and continue
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$BM2_SSH" true 2>/dev/null; then
            log "Pre-pulling on BM2 ($BM2_SSH) [key auth]"
        else
            warn "BM2 SSH wants a password — you'll be prompted ${#IMAGES[@]}x. To fix:"
            warn "  ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519   # one-time"
            warn "  ssh-copy-id $BM2_SSH"
        fi
        for img in "${IMAGES[@]}"; do
            pull_remote "$img" || PULL_FAILED=$((PULL_FAILED + 1))
        done
    else
        warn "BM2_SSH not set in .env — skipping remote pre-pull (Swarm will pull on demand)"
    fi

    if [[ "$PULL_FAILED" -gt 0 ]]; then
        err "$PULL_FAILED pull(s) failed. Fix .env image tags before continuing."
        exit 1
    fi
else
    warn "skipping pre-pull (--no-prepull)"
fi

# ─── Deploy (detached — we run our own convergence loop) ──────────────────────
log "Deploying stack '$STACK_NAME'"
docker stack deploy \
    --with-registry-auth \
    --resolve-image=always \
    -c docker-stack.yml \
    "$STACK_NAME"

# ─── Convergence wait ─────────────────────────────────────────────────────────
# A long-running service is "converged" when running == desired.
# A one-shot is "converged" when its last task is Complete (or it failed
# after exhausting retries, which we surface clearly).
log "Waiting for long-running services to converge (timeout 10 min)..."
DEADLINE=$(( $(date +%s) + 600 ))
PREV=""

is_oneshot() {
    local name=$1
    for o in "${ONESHOTS[@]}"; do
        [[ "$name" == "${STACK_NAME}_$o" ]] && return 0
    done
    return 1
}

while (( $(date +%s) < DEADLINE )); do
    STATUS=$(docker stack services "$STACK_NAME" \
        --format '{{.Name}}|{{.Replicas}}|{{.Image}}' 2>/dev/null || true)

    PENDING=0
    while IFS='|' read -r name reps img; do
        [[ -z "$name" ]] && continue
        is_oneshot "$name" && continue
        if ! [[ "$reps" =~ ^([0-9]+)/\1$ ]]; then
            PENDING=$((PENDING + 1))
        fi
    done <<< "$STATUS"

    if [[ "$QUIET" == "0" && "$STATUS" != "$PREV" ]]; then
        clear
        printf "── stack: %s  (pending: %d)\n" "$STACK_NAME" "$PENDING"
        printf '%-35s %-10s %s\n' NAME REPLICAS IMAGE
        echo "$STATUS" | awk -F'|' '{printf "%-35s %-10s %s\n", $1, $2, $3}'
        PREV="$STATUS"
    fi

    [[ "$PENDING" == "0" ]] && break
    sleep 3
done

if [[ "$PENDING" -ne 0 ]]; then
    err "$PENDING long-running service(s) did not converge in 10 min"
    docker stack ps "$STACK_NAME" --no-trunc --filter desired-state=running \
        | awk 'NR==1 || /Error|Reject|Failed|Preparing|Starting/'
    exit 1
fi
ok "long-running services converged"

# ─── One-shot status ─────────────────────────────────────────────────────────
echo
log "One-shot job status"
for o in "${ONESHOTS[@]}"; do
    svc="${STACK_NAME}_$o"
    if ! docker service ls --format '{{.Name}}' | grep -qx "$svc"; then
        warn "  $svc: not in stack (skipped)"
        continue
    fi
    state=$(docker service ps "$svc" --format '{{.CurrentState}}' --no-trunc | head -1)
    case "$state" in
        Complete*|Shutdown*)            ok "  $svc: $state" ;;
        Running*|Preparing*|Starting*)  warn "  $svc: still $state — check 'docker service logs $svc'" ;;
        Failed*|Rejected*)              err "  $svc: $state"; docker service logs "$svc" --tail 30 ;;
        *)                              warn "  $svc: $state" ;;
    esac
done

echo
docker stack services "$STACK_NAME"

# Cleanup orphaned configs (older versions that no service references).
# Safe: `docker config rm` refuses to remove a config that's still in use.
echo
log "Cleaning up orphaned config versions"
for cfg in $(docker config ls --format '{{.Name}}' | grep "^posthog_\(caddyfile\|clickhouse_\(config\|users\)\)_"); do
    if docker config rm "$cfg" >/dev/null 2>&1; then
        echo "    removed orphan: $cfg"
    fi
done

echo
log "Next steps:"
echo "    docker service logs -f ${STACK_NAME}_web"
echo "    docker exec -it \$(docker ps -qf name=${STACK_NAME}_web) python manage.py createsuperuser"
