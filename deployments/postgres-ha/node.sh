#!/usr/bin/env bash
# Entrypoint of every node of a replicated PostgreSQL cluster (#164), on the official postgres image (16 or 17).
#
# The node decides its role BEFORE PostgreSQL starts, from the leader file that the failover agent keeps in the shared
# state volume (/ha-state/<cluster>/primary; absent before the first failover, which means the first listed node).
# That is the guard against two primaries: an old primary that comes back after a failover reads the new leader's
# name, rewinds onto its timeline and starts as its standby, so it never takes a write.
#
#   leader is me      start as the primary; an empty data directory is initialised by the image's entrypoint, which
#                     also runs initdb.sh (the replicator, failover and etl_reader roles)
#   leader is a peer  wait until the peer answers as a primary; an empty data directory is cloned with
#                     pg_basebackup; an existing one is rewound with pg_rewind (a no-op when nothing diverged) and,
#                     when the rewind fails, cloned again; then standby.signal and primary_conninfo, and start
#
# Environment: PGHA_CLUSTER (name of the cluster, e.g. moderation-postgres), PGHA_NODE (this node, e.g.
# moderation-postgres-2), PGHA_NODES (all nodes, space-separated, the initial primary first), REPLICATION_PASSWORD,
# FAILOVER_PASSWORD, ETL_READER_PASSWORD, and the image's POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB.
# Passwords must not contain a single quote (they are written into primary_conninfo).
set -euo pipefail

. /ha/lib.sh
: "${PGHA_CLUSTER:?}" "${PGHA_NODE:?}" "${PGHA_NODES:?}" "${REPLICATION_PASSWORD:?}" "${FAILOVER_PASSWORD:?}"
PGHA_SERVICE=pg-node
PGHA_INSTANCE=$PGHA_NODE
PGDATA=${PGDATA:-/var/lib/postgresql/data}
STATE_FILE=/ha-state/$PGHA_CLUSTER/primary
FIRST_NODE=${PGHA_NODES%% *}

# Settings every node runs with, primary or standby. hba_file: the pattern's own client authentication (with the
# replication line); wal_log_hints: pg_rewind needs it from the first start; hot_standby_feedback: long reads of the
# ETL on a standby are not cancelled by recovery. synchronous_standby_names is managed at run time by the agent
# (ALTER SYSTEM), never here: a primary with no standby yet would otherwise block every write, initdb's included.
SETTINGS=(
  -c hba_file=/ha/pg_hba.conf
  -c wal_log_hints=on
  -c wal_keep_size=256MB
  -c max_wal_senders=10
  -c hot_standby_feedback=on
)

as_postgres() { gosu postgres "$@"; }

leader() {
  if [ -s "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo "$FIRST_NODE"; fi
}

has_data() { [ -s "$PGDATA/PG_VERSION" ]; }

clear_data() { find "$PGDATA" -mindepth 1 -delete; }

# Points this node at PRIMARY as a standby: standby.signal plus one primary_conninfo line (as the replicator) in
# postgresql.auto.conf, where the agent's ALTER SYSTEM can change it later without a restart.
become_standby_of() {
  local primary=$1 conf=$PGDATA/postgresql.auto.conf
  as_postgres touch "$PGDATA/standby.signal" "$conf"
  as_postgres sed -i -e '/^primary_conninfo/d' -e '/^default_transaction_read_only/d' "$conf"
  printf "primary_conninfo = 'host=%s port=5432 user=replicator password=%s application_name=%s'\n" \
    "$primary" "$REPLICATION_PASSWORD" "$PGHA_NODE" | as_postgres tee -a "$conf" >/dev/null
}

clone_from() {
  local primary=$1
  clear_data
  log info node.cloning "cloning the data directory from the primary" primary "$primary"
  PGPASSWORD=$REPLICATION_PASSWORD as_postgres pg_basebackup -h "$primary" -p 5432 -U replicator \
    -D "$PGDATA" -X stream -c fast --no-password
}

mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

current=$(leader)

if [ "$current" = "$PGHA_NODE" ]; then
  if has_data; then
    # A standby the agent promoted, or the primary restarting: start as the primary. A leftover standby.signal
    # (the agent wrote the leader file, then died before pg_promote) is removed, which promotes it here.
    rm -f "$PGDATA/standby.signal"
    if [ -f "$PGDATA/postgresql.auto.conf" ]; then
      as_postgres sed -i '/^default_transaction_read_only/d' "$PGDATA/postgresql.auto.conf"
    fi
    log info node.role "starting as the primary" role primary
  else
    log info node.role "initialising an empty data directory as the primary" role primary
  fi
  exec docker-entrypoint.sh postgres "${SETTINGS[@]}"
fi

waited=0
until is_primary "$current"; do
  if [ $((waited % 10)) -eq 0 ]; then
    log info node.waiting "waiting for the primary before starting as its standby" primary "$current"
  fi
  sleep 1
  waited=$((waited + 1))
  current=$(leader)
  if [ "$current" = "$PGHA_NODE" ]; then
    log warn node.promoted_while_waiting "the agent made this node the primary while it waited; restarting the decision"
    exec bash "$0"
  fi
done

if ! has_data; then
  clone_from "$current"
else
  log info node.rewinding "rewinding onto the primary's timeline (a no-op when nothing diverged)" primary "$current"
  if ! as_postgres pg_rewind -D "$PGDATA" \
      --source-server="host=$current port=5432 user=failover password=$FAILOVER_PASSWORD dbname=postgres"; then
    log warn node.rewind_failed "pg_rewind failed; cloning the data directory again" primary "$current"
    clone_from "$current"
  fi
fi

become_standby_of "$current"
log info node.role "starting as a standby" role standby primary "$current"
exec docker-entrypoint.sh postgres "${SETTINGS[@]}"
