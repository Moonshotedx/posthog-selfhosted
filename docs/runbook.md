# PostHog Swarm — Operations Runbook

Day-2 operations for the 2-node bare-metal PostHog deployment. Assumes you can ssh into BM1 (manager) as root.

---

## Quick reference

| What | Command |
|------|---------|
| Stack status | `docker stack services posthog` |
| All tasks (incl. failed) | `docker stack ps posthog --no-trunc` |
| Per-service logs | `docker service logs -f posthog_<service>` |
| Shell in a running container | `docker exec -it $(docker ps -qf name=posthog_<service>) sh` |
| Roll the stack | `./scripts/deploy.sh` |
| Force-restart one service | `docker service update --force posthog_<service>` |
| Scale a service | `docker service scale posthog_web=3` |
| Node health | `docker node ls && docker node inspect self --pretty` |

---

## 1. Common operations

### 1.1 Update PostHog to a new release

```bash
$EDITOR .env                      # bump POSTHOG_IMAGE_TAG
./scripts/deploy.sh
```

Swarm performs a rolling update. `web` and `capture` use `order: start-first` (zero-downtime). `worker`, `plugin-server`, `migrate` use `stop-first` so only one runs at a time during deploy. `migrate` runs once on every deploy and exits — that's expected.

### 1.2 Restart a single service

```bash
docker service update --force posthog_web
```

### 1.3 Open a Django shell / run a manage.py command

```bash
docker exec -it $(docker ps -qf name=posthog_web) python manage.py shell_plus
docker exec -it $(docker ps -qf name=posthog_web) python manage.py createsuperuser
```

### 1.4 Open a SQL shell

Postgres:

```bash
docker exec -it $(docker ps -qf name=posthog_postgres) psql -U posthog
```

ClickHouse (note: container runs on BM1):

```bash
ssh bm1 docker exec -it \
    \$(docker ps -qf name=posthog_clickhouse) \
    clickhouse-client -u posthog --password $CLICKHOUSE_PASSWORD
```

### 1.5 Flush Kafka backlog (events stuck)

```bash
# inspect lag
docker exec -it $(docker ps -qf name=posthog_kafka) \
    kafka-consumer-groups --bootstrap-server localhost:9092 --describe --all-groups
```

If plugin-server is healthy but lag is growing, scale it: `docker service scale posthog_plugin-server=2` — but note BM1 needs RAM headroom.

---

## 2. Health checks

Every service has a Docker healthcheck. To see the current state:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Look for `(healthy)` after each service. `(unhealthy)` triggers automatic restart under the configured restart policy.

External smoke test (run from anywhere):

```bash
curl -fsSL https://posthog.example.com/_health
curl -fsSL https://posthog.example.com/decide/?v=3
```

---

## 3. Backup & restore

### 3.1 Backups

Configure cron on BM1:

```cron
0 2 * * * /opt/posthog-selfhosted/scripts/backup.sh >> /var/log/posthog-backup.log 2>&1
```

Daily snapshots land in `/opt/posthog/data/backups/` and are rsync'd to BM2. Weekly snapshots (Mondays) are kept for `BACKUP_RETAIN_WEEKLY` weeks.

### 3.2 Test the restore — quarterly

```bash
# scratch instance on BM2 (or any spare host)
./scripts/restore.sh 2026-05-12 /mnt/external/backups
```

A restore drill that you have never run is a backup you do not have.

### 3.3 Disaster scenarios

| Scenario | Recovery |
|----------|----------|
| BM2 NVMe fails | Re-provision BM2, `bootstrap-host.sh`, `docker swarm join`, `restore.sh` from BM1's `/opt/posthog/data/backups/` |
| BM1 NVMe mirror loses one disk | RAID-1 still online; `mdadm --add /dev/md0 /dev/<new-nvme>` to rebuild |
| BM1 NVMe mirror loses both disks | Re-provision BM1, `bootstrap-host.sh`, rejoin swarm, restore CH from BM2's backups dir |
| Both nodes lost | Restore from off-site S3 mirror (requires `BACKUP_S3_*` to be set) |

---

## 4. Scaling guide

Stateless services (`web`, `capture`, `plugin-server`) scale horizontally by adjusting replicas. Replicas land on the labelled node — you cannot scale `web` onto BM1 without adding `posthog.role=app` to BM1 or relaxing the constraint.

| Bottleneck signal | Action |
|---|---|
| 5xx from web, CPU pinned on BM2 | `docker service scale posthog_web=3` |
| Capture latency > 200ms p95 (web is doing capture) | `docker service scale posthog_web=3`; long-term, split out the Rust `posthog/capture` image as a dedicated service |
| Kafka consumer lag growing | More `plugin-server` replicas; check ClickHouse merge backlog first |
| ClickHouse merges piling up (`system.merges`) | Raise `background_pool_size` in `config/clickhouse/config.d/posthog.xml`, redeploy |
| Postgres connection exhaustion | Raise `max_connections` in `docker-stack.yml` postgres command |

Vertical scaling is just editing `resources.limits` in `docker-stack.yml` and `./scripts/deploy.sh`. Swarm performs a rolling update.

---

## 5. Adding monitoring (optional)

A minimal external-friendly setup:

1. On each node:

    ```bash
    docker run -d --restart=always --name node-exporter \
        --pid="host" \
        -v "/:/host:ro,rslave" \
        -p 9100:9100 \
        prom/node-exporter --path.rootfs=/host
    ```

2. Add a Grafana Cloud free account; install their agent on BM1; point it at `bm1:9100` and `bm2:9100`. ClickHouse exposes Prometheus metrics on port 9363 — scrape that too.

3. For PostHog application metrics: web exposes `/api/_system_status` (auth required) — use the periodic Grafana HTTP check.

---

## 6. Troubleshooting

### 6.1 `docker stack deploy` shows a service stuck at `0/1`

```bash
docker service ps posthog_<service> --no-trunc
```

The `ERROR` column will tell you why. Common causes:

- **`no suitable node`** — the node label is missing. `docker node ls --filter node.label=posthog.role=<role>` should show one node.
- **`task: non-zero exit (137)`** — OOM. Increase `resources.limits.memory` and redeploy.
- **`task: rejected`** — image pull failed. Manually `docker pull <image>` on the target node; check registry auth.

### 6.2 ClickHouse migrations failing

```bash
docker service logs posthog_migrate
docker exec -it $(docker ps -qf name=posthog_clickhouse) \
    clickhouse-client -u posthog --password "$CLICKHOUSE_PASSWORD" \
    --query "SELECT * FROM system.errors WHERE last_error_time > now() - 3600"
```

PostHog's async-migrations checker runs in the `web` task. Visit `/instance/async_migrations` as an admin to see failed ones; rerun from the UI.

### 6.3 Caddy not issuing certs

```bash
docker service logs posthog_caddy --tail 200
```

Confirm:

- DNS A record for `$DOMAIN` resolves to BM2's *public* IP
- Port 80 is reachable from the internet (Let's Encrypt HTTP-01 needs it)
- `ACME_EMAIL` is a real address

To force re-issue, delete `/opt/posthog/data/caddy/data/caddy/certificates/` and restart Caddy.

### 6.4 Capture is dropping events

Capture endpoints are served by the `web` task in this deployment. Check:

```bash
docker service logs posthog_web --tail 200 | grep -iE 'capture|kafka.*error'
```

Most likely a Kafka backpressure issue:

```bash
docker exec -it $(docker ps -qf name=posthog_kafka) \
    kafka-topics --bootstrap-server localhost:9092 --describe --topic events_plugin_ingestion
```

Disk full on BM1? `df -h /opt/posthog/data` — Kafka retention is 24 h by default; if you've cranked it up, you may be at capacity.

---

## 7. Security hardening checklist

- [ ] All passwords in `.env` set to ≥32 random chars (`openssl rand -hex 32`)
- [ ] `.env` is `chmod 600 root:root`, never committed
- [ ] UFW configured (`scripts/bootstrap-host.sh` does this) — verify with `ufw status`
- [ ] ssh: key-only auth, no root password, fail2ban installed
- [ ] PostHog admin: 2FA enabled (`Settings → Personal API keys → 2FA`)
- [ ] Caddy is on the latest patch release
- [ ] MinIO console (`/minio/`) is firewalled or behind basic auth — it's an admin surface
- [ ] Backup retention satisfies your RPO/RTO targets and you've actually run `restore.sh` in a drill

---

## 8. Decommissioning

```bash
docker stack rm posthog                       # tear down services
docker swarm leave --force                    # on BM2 first
docker swarm leave --force                    # then on BM1
rm -rf /opt/posthog/data                      # destroy ALL data — irreversible
```
