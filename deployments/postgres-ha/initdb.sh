#!/usr/bin/env bash
# Runs once, when the first node of a cluster initialises an empty data directory (mounted into
# /docker-entrypoint-initdb.d by the compose block). Creates the three roles of the pattern (#164); the standbys get
# them by streaming replication, so they exist on every node:
#   replicator   REPLICATION, for pg_basebackup and streaming (REPLICATION_PASSWORD)
#   failover     SUPERUSER, for the failover agent: pg_promote(), ALTER SYSTEM, pg_rewind (FAILOVER_PASSWORD)
#   etl_reader   LOGIN with no table rights; each service's own migrations grant what the ETL may read (#165)
# and stores wal_log_hints = on in the data directory (see the comment at the end).
# Passwords go through psql variables and format(%L), so no quoting of their own is needed.
set -euo pipefail

psql -v ON_ERROR_STOP=1 -X --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v repl="$REPLICATION_PASSWORD" -v fail="$FAILOVER_PASSWORD" -v etl="${ETL_READER_PASSWORD:-}" <<'SQL'
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'repl')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('CREATE ROLE failover WITH SUPERUSER LOGIN PASSWORD %L', :'fail')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'failover') \gexec
SELECT format('CREATE ROLE etl_reader WITH LOGIN PASSWORD %L', :'etl')
WHERE :'etl' <> '' AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'etl_reader') \gexec
-- In the data directory (postgresql.auto.conf, copied to the standbys by pg_basebackup and pg_rewind), not only on
-- the command line: the crash recovery that pg_rewind runs in single-user mode after an unclean stop reads only the
-- configuration files. It refuses to rewind without wal_log_hints, and with the default wal_keep_size of 0 its
-- end-of-recovery checkpoint recycles the WAL that pg_rewind then needs to find where the timelines forked.
ALTER SYSTEM SET wal_log_hints = on;
ALTER SYSTEM SET wal_keep_size = '512MB';
SQL
