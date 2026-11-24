#!/usr/bin/env bash
# The failover agent of the replicated PostgreSQL clusters (#164): one container, the official postgres image, for
# every cluster listed in PGHA_CLUSTERS (space-separated cluster names; the nodes of cluster C are C-1, C-2, C-3).
# Each cluster is watched by its own loop (a background subshell), so a node that hangs in one cluster never delays
# another cluster's failover, and every database call is bounded by a wall-clock timeout (lib.sh, `sql`).
#
# Every PGHA_CHECK_INTERVAL seconds (1), for its cluster, a loop:
#   - leader answers as a primary: the cluster is healthy. The loop then
#       * keeps synchronous replication on while a standby streams (synchronous_standby_names = 'ANY 1 (*)': every
#         acknowledged commit is on a standby too) and turns it off after PGHA_SYNC_DEGRADE_SECONDS (4) with no
#         streaming standby, or every write would wait until a standby is back;
#       * stops any other node that also claims to be a primary (an old primary that was paused and woke up after
#         the failover): `COPY ... TO PROGRAM 'kill -INT 1'` asks its postmaster for a fast shutdown, once; the
#         container's restart policy starts it again, and node.sh then rewinds it onto the leader as a standby;
#       * logs failover.rejoined when a node that was the primary (or was stopped above) streams again as a standby;
#   - no good answer from the leader for PGHA_FAILOVER_AFTER_SECONDS (6): fail over. Every other node whose name
#     resolves (its container exists, running or paused) must report its received WAL position, 3 tries each; if
#     one does not answer, nothing is promoted this round (failover.candidate_unreachable): it may be the standby
#     that holds the last acknowledged commits. Otherwise the most advanced standby is written to the leader file
#     FIRST (so a returning old primary already knows it is not the leader, see node.sh), promoted with
#     pg_promote(), and the other standby is re-pointed to it with ALTER SYSTEM SET primary_conninfo.
# Before the first healthy check of a cluster (its first boot) nothing is promoted; a leader file left by an earlier
# run arms the loop at once.
#
# Environment: PGHA_CLUSTERS, FAILOVER_PASSWORD and REPLICATION_PASSWORD (the same in every cluster). The leader
# files live in the shared volume mounted at /ha-state. Logs: one JSON line per event, service "pg-failover".
set -uo pipefail

. /ha/lib.sh
PGHA_SERVICE=pg-failover
PGHA_INSTANCE="pg-failover-$(hostname)"
CLUSTERS=${PGHA_CLUSTERS:-}
INTERVAL=${PGHA_CHECK_INTERVAL:-1}
FAILOVER_AFTER=${PGHA_FAILOVER_AFTER_SECONDS:-6}
SYNC_DEGRADE_SECONDS=${PGHA_SYNC_DEGRADE_SECONDS:-4}
PROMOTE_SECONDS=${PGHA_PROMOTE_SECONDS:-20}

if [ -z "${CLUSTERS// /}" ]; then
  # No cluster converted yet (the stack before #171-#178 deliver): idle, so the block can sit in the compose
  # without the passwords in .env.
  log info failover.idle "no cluster in PGHA_CLUSTERS; nothing to watch"
  trap 'exit 0' TERM INT
  while true; do sleep 3600 & wait $!; done
fi
: "${FAILOVER_PASSWORD:?}" "${REPLICATION_PASSWORD:?}"

state_file() { echo "/ha-state/$1/primary"; }

write_leader() {
  local cluster=$1 node=$2 file
  file=$(state_file "$cluster")
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$node" > "$file.tmp" && mv "$file.tmp" "$file"
}

watch_cluster() {
  local cluster=$1
  local nodes="$cluster-1 $cluster-2 $cluster-3"
  local leader armed="" last_ok failing=false no_standby_since="" rejoining="" node
  declare -A fenced_at=()
  local file
  file=$(state_file "$cluster")
  if [ -s "$file" ]; then leader=$(cat "$file"); armed=1; else leader="$cluster-1"; fi
  last_ok=$(now_s)

  ensure_sync() {
    local streaming current now
    streaming=$(sql "$leader" "select count(*) from pg_stat_replication where state = 'streaming'") || return
    current=$(sql "$leader" "show synchronous_standby_names") || return
    now=$(now_s)
    if [ "${streaming:-0}" -ge 1 ]; then
      no_standby_since=""
      if [ -z "$current" ]; then
        sql "$leader" "alter system set synchronous_standby_names = 'ANY 1 (*)'" >/dev/null &&
          sql "$leader" "select pg_reload_conf()" >/dev/null &&
          log info failover.sync_on "synchronous replication on: a commit waits for one standby" \
            cluster "$cluster" primary "$leader" streaming "$streaming"
      fi
      return
    fi
    [ -z "$current" ] && return
    if [ -z "$no_standby_since" ]; then
      no_standby_since=$now
    elif [ $((now - no_standby_since)) -ge "$SYNC_DEGRADE_SECONDS" ]; then
      sql "$leader" "alter system reset synchronous_standby_names" >/dev/null &&
        sql "$leader" "select pg_reload_conf()" >/dev/null &&
        log warn failover.sync_off "no standby streams: synchronous replication off so that writes do not block" \
          cluster "$cluster" primary "$leader" seconds "$SYNC_DEGRADE_SECONDS"
      no_standby_since=""
    fi
  }

  stop_second_primaries() {
    local n now
    now=$(now_s)
    for n in $nodes; do
      [ "$n" = "$leader" ] && continue
      # Once per node per minute: the fast shutdown takes a moment, and the restarted node comes back as a standby.
      if [ -n "${fenced_at[$n]:-}" ] && [ $((now - fenced_at[$n])) -lt 60 ]; then continue; fi
      if is_primary "$n"; then
        sql "$n" "copy (select 1) to program 'kill -INT 1'" >/dev/null
        fenced_at[$n]=$now
        rejoining="$n"
        log error failover.fenced "a second primary was stopped; its restart rejoins it as a standby of the leader" \
          cluster "$cluster" node "$n" primary "$leader"
      fi
    done
  }

  check_rejoin() {
    [ -n "$rejoining" ] || return
    if [ "$(sql "$rejoining" "select pg_is_in_recovery() and exists (select 1 from pg_stat_wal_receiver where status = 'streaming')")" = "t" ]; then
      log info failover.rejoined "the former primary streams again as a standby" \
        cluster "$cluster" node "$rejoining" primary "$leader"
      rejoining=""
    fi
  }

  fail_over() {
    local old=$leader n row lsn try best="" best_lsn=-1 promoted silent=""
    for n in $nodes; do
      [ "$n" = "$old" ] && continue
      resolves "$n" || continue # stopped: not a candidate, and it cannot hold commits the others lack under ANY 1
      row=""
      for try in 1 2 3; do
        row=$(sql "$n" "select pg_is_in_recovery(),
                        pg_wal_lsn_diff(coalesce(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()), '0/0')::bigint") && break
        row=""
      done
      if [ -z "$row" ]; then silent="$silent $n"; continue; fi
      [ "${row%%|*}" = "t" ] || continue
      lsn=${row#*|}
      if [ "$lsn" -gt "$best_lsn" ]; then best=$n; best_lsn=$lsn; fi
    done
    if [ -n "$silent" ]; then
      log error failover.candidate_unreachable "a running standby does not report its WAL position; nothing is promoted until it does" \
        cluster "$cluster" primary "$old" silent "${silent# }"
      return
    fi
    if [ -z "$best" ]; then
      log error failover.no_candidate "the primary is gone and no standby answers; nothing to promote" \
        cluster "$cluster" primary "$old"
      return
    fi
    write_leader "$cluster" "$best"
    promoted=$(sql_long "$best" "select pg_promote(true, $((PROMOTE_SECONDS - 2)))" "$PROMOTE_SECONDS")
    if [ "$promoted" != "t" ] && ! is_primary "$best"; then
      log error failover.promote_failed "pg_promote did not finish; the leader file already names the standby" \
        cluster "$cluster" node "$best"
    fi
    log warn failover.promoted "the primary stopped answering; the most advanced standby is the new primary" \
      cluster "$cluster" old_primary "$old" new_primary "$best" lsn "$best_lsn" \
      seconds_without_primary "$(( $(now_s) - last_ok ))"
    leader=$best
    last_ok=$(now_s)
    failing=false
    no_standby_since=""
    rejoining="$old"
    for n in $nodes; do
      [ "$n" = "$best" ] || [ "$n" = "$old" ] && continue
      if sql "$n" "alter system set primary_conninfo =
            'host=$best port=5432 user=replicator password=$REPLICATION_PASSWORD application_name=$n'" >/dev/null &&
          sql "$n" "select pg_reload_conf()" >/dev/null; then
        log info failover.repointed "the other standby now streams from the new primary" \
          cluster "$cluster" node "$n" primary "$best"
      else
        log warn failover.repoint_failed "the other standby did not answer; it follows the new primary when it restarts" \
          cluster "$cluster" node "$n" primary "$best"
      fi
    done
  }

  while true; do
    if is_primary "$leader"; then
      if $failing; then log info failover.recovered "the primary answers again" cluster "$cluster" primary "$leader"; fi
      failing=false
      last_ok=$(now_s)
      if [ -z "$armed" ]; then
        armed=1
        write_leader "$cluster" "$leader"
        log info failover.watching "watching the cluster" cluster "$cluster" primary "$leader"
      fi
      ensure_sync
      stop_second_primaries
      check_rejoin
    elif [ -n "$armed" ]; then
      failing=true
      local without=$(( $(now_s) - last_ok ))
      log warn failover.check_failed "the primary does not answer as a primary" \
        cluster "$cluster" primary "$leader" seconds_without_primary "$without"
      if [ "$without" -ge "$FAILOVER_AFTER" ]; then
        fail_over
      fi
    fi
    sleep "$INTERVAL"
  done
}

log info failover.started "failover agent started" clusters "$CLUSTERS" interval_s "$INTERVAL" \
  failover_after_s "$FAILOVER_AFTER" sync_degrade_s "$SYNC_DEGRADE_SECONDS"

pids=()
for cluster in $CLUSTERS; do
  watch_cluster "$cluster" &
  pids+=("$!")
done
trap 'kill "${pids[@]}" 2>/dev/null; log info failover.stopped "failover agent stopped"; exit 0' TERM INT
wait
