#!/usr/bin/env bash
# The failover agent of the replicated PostgreSQL clusters (#164): one container, the official postgres image, for
# every cluster listed in PGHA_CLUSTERS (space-separated cluster names; the nodes of cluster C are C-1, C-2, C-3).
#
# Every PGHA_CHECK_INTERVAL seconds (2) and for every cluster:
#   - the leader answers as a primary: the cluster is healthy. The agent then keeps synchronous replication on while a
#     standby streams (synchronous_standby_names = 'ANY 1 (*)', so every acknowledged commit is on a standby too) and
#     turns it off after PGHA_SYNC_DEGRADE_SECONDS (10) with no streaming standby (or every write would block), and
#     fences any other node that also claims to be a primary (a paused old primary that woke up): read-only and its
#     client sessions ended, so clients with target_session_attrs=read-write skip it;
#   - the leader does not answer as a primary PGHA_FAILED_CHECKS times in a row (3): the agent picks the standby with
#     the highest received WAL position, writes its name to the leader file FIRST (so a returning old primary
#     already knows it is not the leader, see node.sh), promotes it with pg_promote(), and re-points the other
#     standby to it with ALTER SYSTEM SET primary_conninfo and pg_reload_conf().
# Before the first healthy check of a cluster (its first boot) nothing is promoted; a leader file left by an earlier
# run arms the agent at once.
#
# Environment: PGHA_CLUSTERS, FAILOVER_PASSWORD and REPLICATION_PASSWORD (the same in every cluster). The leader
# files live in the shared volume mounted at /ha-state. Logs: one JSON line per event, service "pg-failover".
set -uo pipefail

. /ha/lib.sh
PGHA_SERVICE=pg-failover
PGHA_INSTANCE="pg-failover-$(hostname)"
CLUSTERS=${PGHA_CLUSTERS:-}
if [ -z "${CLUSTERS// /}" ]; then
  # No cluster converted yet (the stack before #171-#178 deliver): idle, so the block can sit in the compose
  # without the passwords in .env.
  log info failover.idle "no cluster in PGHA_CLUSTERS; nothing to watch"
  trap 'exit 0' TERM INT
  while true; do sleep 3600 & wait $!; done
fi
: "${FAILOVER_PASSWORD:?}" "${REPLICATION_PASSWORD:?}"
INTERVAL=${PGHA_CHECK_INTERVAL:-2}
THRESHOLD=${PGHA_FAILED_CHECKS:-3}
SYNC_DEGRADE_SECONDS=${PGHA_SYNC_DEGRADE_SECONDS:-10}

declare -A LEADER FAILS ARMED NO_STANDBY_SINCE

nodes_of() { echo "$1-1 $1-2 $1-3"; }

state_file() { echo "/ha-state/$1/primary"; }

write_leader() {
  local cluster=$1 node=$2 file
  file=$(state_file "$cluster")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$node" > "$file.tmp" && mv "$file.tmp" "$file"
}

ensure_sync() {
  local cluster=$1 primary=$2 streaming current now
  streaming=$(sql "$primary" "select count(*) from pg_stat_replication where state = 'streaming'") || return
  current=$(sql "$primary" "show synchronous_standby_names") || return
  now=${EPOCHREALTIME%.*}
  if [ "${streaming:-0}" -ge 1 ]; then
    NO_STANDBY_SINCE[$cluster]=""
    if [ -z "$current" ]; then
      sql "$primary" "alter system set synchronous_standby_names = 'ANY 1 (*)'" >/dev/null &&
        sql "$primary" "select pg_reload_conf()" >/dev/null &&
        log info failover.sync_on "synchronous replication on: a commit waits for one standby" \
          cluster "$cluster" primary "$primary" streaming "$streaming"
    fi
    return
  fi
  [ -z "$current" ] && return
  if [ -z "${NO_STANDBY_SINCE[$cluster]:-}" ]; then
    NO_STANDBY_SINCE[$cluster]=$now
  elif [ $((now - NO_STANDBY_SINCE[$cluster])) -ge "$SYNC_DEGRADE_SECONDS" ]; then
    sql "$primary" "alter system reset synchronous_standby_names" >/dev/null &&
      sql "$primary" "select pg_reload_conf()" >/dev/null &&
      log warn failover.sync_off "no standby streams: synchronous replication off so that writes do not block" \
        cluster "$cluster" primary "$primary" seconds "$SYNC_DEGRADE_SECONDS"
    NO_STANDBY_SINCE[$cluster]=""
  fi
}

fence_others() {
  local cluster=$1 primary=$2 node
  for node in $(nodes_of "$cluster"); do
    [ "$node" = "$primary" ] && continue
    if is_primary "$node"; then
      sql "$node" "alter system set default_transaction_read_only = on" >/dev/null
      sql "$node" "select pg_reload_conf()" >/dev/null
      sql "$node" "select count(pg_terminate_backend(pid)) from pg_stat_activity
                   where backend_type = 'client backend' and pid <> pg_backend_pid()" >/dev/null
      log error failover.fenced "a second primary was made read-only; restart it to rejoin as a standby" \
        cluster "$cluster" node "$node" primary "$primary"
    fi
  done
}

fail_over() {
  local cluster=$1 old=$2 node row lsn best="" best_lsn=-1 promoted
  for node in $(nodes_of "$cluster"); do
    [ "$node" = "$old" ] && continue
    row=$(sql "$node" "select pg_is_in_recovery(),
                       pg_wal_lsn_diff(coalesce(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()), '0/0')::bigint") || continue
    [ "${row%%|*}" = "t" ] || continue
    lsn=${row#*|}
    if [ "$lsn" -gt "$best_lsn" ]; then best=$node; best_lsn=$lsn; fi
  done
  if [ -z "$best" ]; then
    log error failover.no_candidate "the primary is gone and no standby answers; nothing to promote" \
      cluster "$cluster" primary "$old"
    return
  fi
  write_leader "$cluster" "$best"
  promoted=$(sql "$best" "select pg_promote(true, 15)")
  if [ "$promoted" != "t" ]; then
    log error failover.promote_failed "pg_promote did not finish; the leader file already names the standby" \
      cluster "$cluster" node "$best"
  fi
  log warn failover.promoted "the primary stopped answering; the most advanced standby is the new primary" \
    cluster "$cluster" old_primary "$old" new_primary "$best" lsn "$best_lsn"
  LEADER[$cluster]=$best
  FAILS[$cluster]=0
  NO_STANDBY_SINCE[$cluster]=""
  for node in $(nodes_of "$cluster"); do
    [ "$node" = "$best" ] || [ "$node" = "$old" ] && continue
    if sql "$node" "alter system set primary_conninfo =
          'host=$best port=5432 user=replicator password=$REPLICATION_PASSWORD application_name=$node'" >/dev/null &&
        sql "$node" "select pg_reload_conf()" >/dev/null; then
      log info failover.repointed "the other standby now streams from the new primary" \
        cluster "$cluster" node "$node" primary "$best"
    else
      log warn failover.repoint_failed "the other standby did not answer; it follows the new primary when it restarts" \
        cluster "$cluster" node "$node" primary "$best"
    fi
  done
}

check() {
  local cluster=$1 leader=${LEADER[$1]}
  if is_primary "$leader"; then
    if [ "${FAILS[$cluster]}" -gt 0 ]; then
      log info failover.recovered "the primary answers again" cluster "$cluster" primary "$leader"
    fi
    FAILS[$cluster]=0
    if [ -z "${ARMED[$cluster]}" ]; then
      ARMED[$cluster]=1
      write_leader "$cluster" "$leader"
      log info failover.watching "watching the cluster" cluster "$cluster" primary "$leader"
    fi
    ensure_sync "$cluster" "$leader"
    fence_others "$cluster" "$leader"
    return
  fi
  [ -n "${ARMED[$cluster]}" ] || return
  FAILS[$cluster]=$((FAILS[$cluster] + 1))
  log warn failover.check_failed "the primary does not answer as a primary" \
    cluster "$cluster" primary "$leader" failed_checks "${FAILS[$cluster]}"
  if [ "${FAILS[$cluster]}" -ge "$THRESHOLD" ]; then
    fail_over "$cluster" "$leader"
  fi
}

for cluster in $CLUSTERS; do
  file=$(state_file "$cluster")
  if [ -s "$file" ]; then
    LEADER[$cluster]=$(cat "$file")
    ARMED[$cluster]=1
  else
    LEADER[$cluster]="$cluster-1"
    ARMED[$cluster]=""
  fi
  FAILS[$cluster]=0
  NO_STANDBY_SINCE[$cluster]=""
done
log info failover.started "failover agent started" clusters "$CLUSTERS" interval_s "$INTERVAL" failed_checks "$THRESHOLD"

trap 'log info failover.stopped "failover agent stopped"; exit 0' TERM INT
while true; do
  for cluster in $CLUSTERS; do
    check "$cluster"
  done
  sleep "$INTERVAL" &
  wait $!
done
