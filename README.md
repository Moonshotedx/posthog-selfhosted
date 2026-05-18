# PostHog on Two Bare Metals — Docker Swarm Deployment

A turn-key, opinionated deployment of [PostHog](https://posthog.com/docs/self-host) across two bare-metal servers using Docker Swarm and `docker stack`. Designed for a small-to-mid-scale production install (low-millions of events/day) with a single-command deploy and a clear operations runbook.

> Refer to [`docs/runbook.md`](docs/runbook.md) for day-2 operations (restarts, scaling, backup/restore, troubleshooting).

---

## 1. Hardware & Role Assignment

| Node | Spec | Role label | Workload |
|------|------|------------|----------|
| **BM1** | i7-14700 (20C/28T), 64 GB DDR5, 2×500 GB NVMe | `posthog.role=data` | ClickHouse, Kafka, Zookeeper, MinIO, plugin-server, worker |
| **BM2** | Xeon Silver 4208 (8C/16T), 48 GB DDR4 ECC, 1×500 GB NVMe | `posthog.role=app` | Postgres, Redis, web (handles UI + capture endpoints), Caddy (TLS), async-migrations |

Rationale:

- **ClickHouse is the heaviest** consumer of CPU + RAM + sequential NVMe I/O. The i7-14700 has more cores, a faster memory bus (DDR5), and double the local storage — it gets ClickHouse, Kafka (the consumer pair), MinIO (session recordings live here), and the Node.js plugin-server which does heavy event transforms.
- **PostgreSQL** stores transactional metadata, projects, feature-flag definitions, async-migrations state. It benefits from **ECC RAM** which BM2 provides. It is small (<10 GB typically) and lives comfortably on BM2.
- **Caddy** (TLS) lives on BM2 — that's where DNS will point. PostHog's bundled **web** image (`posthog/posthog`) serves both the dashboard *and* the event-ingestion endpoints (`/capture`, `/e`, `/batch`, `/s`), so we run 2 replicas of `web` on BM2 to absorb capture load and provide hot-redundancy. The single inter-node hop in the hot path is web(BM2) → Kafka(BM1). If you outgrow this — typically >5M events/day — split out the Rust `posthog/capture` service into its own task; placement constraints stay on BM2.
- **Redis** lives next to the web tier (BM2) because that is its primary consumer; latency from web → cache is what matters.

### Memory budget

| BM1 service | Reserved | Limit |
|---|---|---|
| ClickHouse | 16 GB | 28 GB |
| Kafka | 3 GB | 6 GB |
| Zookeeper | 512 MB | 1 GB |
| MinIO | 512 MB | 2 GB |
| Plugin-server | 4 GB | 8 GB |
| Worker | 2 GB | 4 GB |
| **Total reserved / limit** | **26 GB** | **49 GB** (of 64 GB) |

| BM2 service | Reserved | Limit |
|---|---|---|
| Postgres | 4 GB | 8 GB |
| Redis | 512 MB | 2 GB |
| Web (×2 replicas, UI + capture) | 6 GB | 12 GB |
| Caddy | 128 MB | 256 MB |
| **Total reserved / limit** | **10.6 GB** | **22.2 GB** (of 48 GB) |

Headroom on both nodes covers OS, page cache (critical for ClickHouse/Postgres), and burst.

---

## 2. Network Topology

```
                       Internet
                          │
                       443/80
                          ▼
           ┌───────────────────────────┐
           │           BM2             │   (host net: Caddy)
           │   ┌────────────────────┐  │
           │   │  Caddy (TLS)       │  │
           │   └──────────┬─────────┘  │
           │              │ overlay    │
           │   ┌──────────▼─────────┐  │
           │   │  web (x2: ui+cap)  │  │
           │   │  postgres | redis  │  │
           │   └──────────┬─────────┘  │
           └──────────────┼────────────┘
                          │  overlay  (Swarm encrypted)
           ┌──────────────┼────────────┐
           │              ▼            │
           │   ┌────────────────────┐  │
           │   │  Kafka + Zookeeper │  │
           │   │  ClickHouse        │  │
           │   │  MinIO             │  │
           │   │  plugin-server     │  │
           │   │  worker            │  │
           │   └────────────────────┘  │
           │           BM1             │
           └───────────────────────────┘
```

- **`posthog_net`**: a single Swarm overlay network, encrypted, for all internal traffic.
- **Caddy** runs in `network_mode: host` on BM2 so it can bind directly to ports 80/443 and preserve client IPs.
- No application port is published except 80/443 on BM2.
- Inter-node traffic should ideally run on a private LAN (10 GbE recommended; 1 GbE is workable). At minimum, configure UFW/nftables to allow only the Swarm/Overlay ports between BM1 and BM2 (see `scripts/bootstrap-host.sh`).

---

## 3. Storage Layout

### BM1 — `/opt/posthog/data`

The script auto-detects spare NVMes (anything that isn't the root disk) and picks one of two paths:

| Layout on BM1 | What `bootstrap-host.sh` does | Capacity | Drive-failure tolerance |
|---|---|---|---|
| OS on `nvme0n1`, data on `nvme1n1` *(typical — this is what we have)* | XFS directly on `nvme1n1`, mounted at `/opt/posthog/data` | ~500 GB | **None** — backups to BM2 are the only durability layer |
| OS on a separate boot SSD, `nvme0n1` + `nvme1n1` both free | mdadm RAID-1 mirror, XFS on `/dev/md0` | ~500 GB | Yes (single-disk failure survives) |
| OS on a separate boot SSD, 2 NVMes, capacity > redundancy | Set `BM1_STORAGE_MODE=stripe` in `.env` | ~1 TB | None |

Override the auto-detection by setting `BM1_DATA_DEVICES="/dev/nvme1n1"` in `.env`.

```
/opt/posthog/data/
├── clickhouse/        # 200–300 GB typical, grows with retention
├── kafka/             # ~10 GB (1 h retention as per defaults)
├── zookeeper/
├── minio/             # session recordings, exports — biggest growth driver
└── plugin-server/     # tiny, ephemeral cache
```

> ⚠ With OS-on-nvme0n1 + data-on-nvme1n1, **a single disk failure on `nvme1n1` means full restore from BM2 backups.** Make sure `scripts/backup.sh` is in cron and tested before you put real traffic on the box.

### BM2 — `/opt/posthog/data` (single NVMe, ext4)

```
/opt/posthog/data/
├── postgres/          # <10 GB
├── redis/             # <1 GB
├── caddy/             # certs, ~MBs
└── backups/           # nightly rsync from BM1 — see scripts/backup.sh
```

All bind mounts are pinned to their node via Swarm placement constraints — a service cannot accidentally be scheduled where its data does not exist.

---

## 4. Repository Layout

```
.
├── README.md                          # this file
├── .env.example                       # copy to .env and edit
├── docker-stack.yml                   # the single source of truth for Swarm
├── config/
│   ├── caddy/Caddyfile                # reverse proxy + automatic TLS
│   ├── clickhouse/config.d/posthog.xml
│   ├── clickhouse/users.d/posthog.xml
│   └── postgres/init.sql              # PostHog DB bootstrap
├── scripts/
│   ├── bootstrap-host.sh              # run on EACH bm: OS prep, docker, raid, dirs
│   ├── init-swarm.sh                  # run on BM1: swarm init + join + labels
│   ├── deploy.sh                      # run on BM1: deploy/update the stack
│   ├── backup.sh                      # nightly cron on BM1
│   └── restore.sh                     # disaster recovery
└── docs/
    └── runbook.md                     # day-2 operations manual
```

---

## 5. Deployment Procedure

### Prerequisites (one-time)

- Ubuntu 24.04 LTS (or Debian 12) on both nodes
- A DNS A record (e.g. `posthog.example.com`) pointing to BM2's public IP
- Inbound 80/443 open on BM2; nothing else internet-facing
- A private LAN or trusted link between BM1 and BM2 (use the LAN IPs in `.env`)

### Step 1 — Prepare each host

On **both** BM1 and BM2 (as root):

```bash
git clone <this repo> /opt/posthog-selfhosted
cd /opt/posthog-selfhosted
cp .env.example .env
$EDITOR .env                   # set domain, passwords, LAN IPs

# Installs docker, hardens sysctl, creates /opt/posthog/data, sets up RAID on BM1
sudo ./scripts/bootstrap-host.sh
```

`bootstrap-host.sh` auto-detects which node it is from the `NODE_ROLE` value in `.env` (`data` vs `app`). On BM1 it builds the mdadm mirror; on BM2 it just creates directories.

### Step 2 — Initialize the Swarm

On **BM1**:

```bash
sudo ./scripts/init-swarm.sh
```

This:

1. `docker swarm init --advertise-addr <BM1_LAN_IP>`
2. Prints the worker join command — copy it.
3. SSH to BM2 and paste/run that join command.
4. Back on BM1, runs `docker node update --label-add posthog.role=data bm1` and `... =app bm2`.

(Or the script will offer to ssh to BM2 and label both nodes for you if you put `BM2_SSH=user@bm2` in `.env`.)

### Step 3 — Deploy

On **BM1**:

```bash
sudo ./scripts/deploy.sh
```

This:

1. Loads `.env` into the shell.
2. `docker stack deploy -c docker-stack.yml --with-registry-auth posthog`
3. Waits for all services to converge and reports status.

First-time bring-up takes ~5–10 min while ClickHouse/Postgres migrations run. Watch with `docker service ls` and `docker service logs posthog_web -f`.

### Step 4 — Create the first user

```bash
docker exec -it $(docker ps -qf name=posthog_web) python manage.py createsuperuser
```

Then visit `https://<your-domain>/`.

---

## 6. Updating

```bash
# pull new image tag (edit POSTHOG_IMAGE_TAG in .env)
sudo ./scripts/deploy.sh
```

Swarm performs a rolling update — services with `update_config.order: stop-first` are taken down one at a time; stateless services (`start-first`) ramp up new tasks before draining old ones.

---

## 7. Backups (see `scripts/backup.sh`)

Nightly cron on BM1 runs:

1. `pg_dump` (over the overlay network to BM2's Postgres) → gzip → `/opt/posthog/data/backups/postgres/`
2. `clickhouse-backup create` → tarball → same dir
3. `mc mirror` MinIO → `backups/minio/` (only changed objects)
4. `rsync` the whole `backups/` directory to BM2's `/opt/posthog/data/backups/` over the LAN

Retention: 7 daily + 4 weekly. Adjust in `.env`.

For off-site durability, add an S3/B2/Wasabi target — there is a stub at the bottom of `backup.sh`.

---

## 8. What's intentionally *not* here

- **Kubernetes** — PostHog has sunset official k8s charts for self-host; Swarm matches the supported topology and is far simpler for 2 nodes.
- **Prometheus/Grafana stack** — out of scope; the runbook documents how to bolt on `node_exporter` + an external Grafana Cloud free tier if desired.
- **HA Postgres / ClickHouse cluster** — at this scale, single-instance + nightly logical backups + a tested restore is more reliable than running a 2-node Patroni/keeper quorum (which needs a 3rd witness anyway).
- **Temporal, PersonHog, livestream** — the newer hobby compose bundles these for feature parity with cloud; they are optional and can be enabled later by uncommenting the relevant block in `docker-stack.yml`.

---

## 9. License

Apache-2.0 for the deployment scripts in this repo. PostHog itself is dual-licensed (MIT + Enterprise) — review their license terms before enabling Enterprise features.
