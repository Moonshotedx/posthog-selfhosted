#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  bootstrap-host.sh — one-shot per-host preparation.
#
#  Run on EACH bare-metal node (BM1 and BM2) as root, after editing .env.
#  Idempotent: rerun freely.
#
#  What it does:
#    1. Validates .env and NODE_ROLE.
#    2. Installs prerequisites (docker, mdadm, rsync, jq, ufw, chrony).
#    3. Tunes sysctl for ClickHouse / Kafka / Postgres.
#    4. On BM1 (NODE_ROLE=data): builds an mdadm RAID-1 mirror across the
#       two NVMes and mounts it at /opt/posthog/data.
#    5. On BM2 (NODE_ROLE=app):   creates /opt/posthog/data on the single NVMe.
#    6. Creates the per-service subdirectories with correct ownership.
#    7. Configures UFW to allow Swarm + 80/443 + nothing else from the WAN.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2; exit 1
fi

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env not found — copy .env.example and edit it first"; exit 1; }
set -a; source .env; set +a

: "${NODE_ROLE:?NODE_ROLE must be 'data' or 'app' in .env}"
: "${BM1_LAN_IP:?BM1_LAN_IP must be set in .env}"
: "${BM2_LAN_IP:?BM2_LAN_IP must be set in .env}"

DATA_ROOT="/opt/posthog/data"
BM1_STORAGE_MODE="${BM1_STORAGE_MODE:-mirror}"   # mirror | stripe

log() { printf '\e[1;34m▶\e[0m %s\n' "$*"; }

# ── 1. Packages ──────────────────────────────────────────────────────────────
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    mdadm rsync jq ufw chrony lvm2 xfsprogs \
    postgresql-client       # used by backup.sh

if ! command -v docker >/dev/null; then
    log "Installing Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
fi
systemctl enable --now chrony

# ── 2. Sysctl tuning ─────────────────────────────────────────────────────────
log "Applying sysctl tuning"
cat >/etc/sysctl.d/99-posthog.conf <<'EOF'
# Networking for high-conn workloads
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15
# File handles
fs.file-max = 2097152
fs.aio-max-nr = 1048576
# Memory: Kafka & Postgres prefer no swap; ClickHouse benefits from lots of cache
vm.swappiness = 1
vm.max_map_count = 262144
vm.overcommit_memory = 1
# Transparent huge pages → off (ClickHouse & Redis both recommend)
EOF
sysctl --system >/dev/null

# Disable THP at runtime (re-applied via systemd service for persistence)
echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  || true
cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

# ── 3. Storage layout ────────────────────────────────────────────────────────
log "Preparing $DATA_ROOT"
mkdir -p "$DATA_ROOT"

if [[ "$NODE_ROLE" == "data" ]] && ! mountpoint -q "$DATA_ROOT"; then
    log "BM1: setting up NVMe array ($BM1_STORAGE_MODE)"
    # Detect NVMe devices that are NOT the root disk
    ROOT_DEV=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
    mapfile -t NVMES < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && /nvme/ {print "/dev/"$1}' | grep -v "$ROOT_DEV" || true)

    if [[ ${#NVMES[@]} -lt 2 ]]; then
        echo "expected 2 spare NVMe devices on BM1, found: ${NVMES[*]:-none}" >&2
        echo "if the OS is on a separate disk, this is fine — otherwise mount $DATA_ROOT yourself and rerun." >&2
        exit 1
    fi

    case "$BM1_STORAGE_MODE" in
        mirror) RAID_LEVEL=1 ;;
        stripe) RAID_LEVEL=0 ;;
        *) echo "invalid BM1_STORAGE_MODE: $BM1_STORAGE_MODE"; exit 1 ;;
    esac

    log "Creating /dev/md0 (raid$RAID_LEVEL) from ${NVMES[*]}"
    mdadm --create --verbose /dev/md0 --level=$RAID_LEVEL --raid-devices=2 "${NVMES[@]}" --metadata=1.2 --force
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u

    mkfs.xfs -f -L posthog-data /dev/md0
    UUID=$(blkid -s UUID -o value /dev/md0)
    echo "UUID=$UUID  $DATA_ROOT  xfs  defaults,noatime,nodiratime  0 0" >> /etc/fstab
    mount "$DATA_ROOT"
elif [[ "$NODE_ROLE" == "app" ]] && ! mountpoint -q "$DATA_ROOT"; then
    log "BM2: $DATA_ROOT is on the OS disk (single NVMe)"
fi

# ── 4. Per-service directories ───────────────────────────────────────────────
log "Creating service directories"
case "$NODE_ROLE" in
    data)
        for d in clickhouse clickhouse-logs kafka zookeeper/data zookeeper/log minio plugin-server backups; do
            install -d -m 0755 "$DATA_ROOT/$d"
        done
        # ClickHouse runs as uid 101
        chown -R 101:101 "$DATA_ROOT/clickhouse" "$DATA_ROOT/clickhouse-logs"
        # Kafka / Zookeeper run as uid 1000
        chown -R 1000:1000 "$DATA_ROOT/kafka" "$DATA_ROOT/zookeeper"
        # MinIO runs as 1000
        chown -R 1000:1000 "$DATA_ROOT/minio"
        ;;
    app)
        for d in postgres redis caddy/data caddy/config backups; do
            install -d -m 0755 "$DATA_ROOT/$d"
        done
        # Postgres runs as 70 (alpine) — image will chown on first boot anyway
        chown -R 70:70 "$DATA_ROOT/postgres" || true
        # Redis runs as 999
        chown -R 999:999 "$DATA_ROOT/redis" || true
        ;;
    *) echo "unknown NODE_ROLE: $NODE_ROLE"; exit 1 ;;
esac

# ── 5. Firewall ──────────────────────────────────────────────────────────────
log "Configuring UFW"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'

# Allow Swarm/overlay traffic between the two nodes
PEER_IP=$([[ "$NODE_ROLE" == "data" ]] && echo "$BM2_LAN_IP" || echo "$BM1_LAN_IP")
for proto_port in tcp/2377 tcp/7946 udp/7946 udp/4789; do
    proto="${proto_port%/*}"; port="${proto_port#*/}"
    ufw allow from "$PEER_IP" to any port "$port" proto "$proto" comment 'swarm'
done

if [[ "$NODE_ROLE" == "app" ]]; then
    ufw allow 80/tcp  comment 'http'
    ufw allow 443/tcp comment 'https'
fi
ufw --force enable

log "host bootstrap complete — node role: $NODE_ROLE"
