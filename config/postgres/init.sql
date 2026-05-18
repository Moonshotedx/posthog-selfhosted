-- Bootstrap for the PostHog Postgres instance.
-- The official image runs every *.sql file in /docker-entrypoint-initdb.d/
-- on the FIRST boot only (empty data dir). Subsequent boots are a no-op.

-- PostHog uses pg_trgm for text search and citext for case-insensitive cols.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;

-- Tune autovacuum a touch more aggressively for the high-churn person table.
ALTER SYSTEM SET autovacuum_naptime = '20s';
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = '0.05';
ALTER SYSTEM SET autovacuum_analyze_scale_factor = '0.02';
