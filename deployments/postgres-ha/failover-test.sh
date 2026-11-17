#!/usr/bin/env bash
# Proves the PostgreSQL replication pattern (#164) on a throw-away cluster (docker-compose.test.yml, project
# pgha-test):
#   1. replication to both standbys, a refused write on a standby;
#   2. with both standbys stopped, a write waits only until the agent turns synchronous replication off;
#   3. a failover while a writer runs: the time until writes work again, and no acknowledged commit lost;
#   4. the old primary rejoins as a standby of the new one by itself (failover.rejoined);
#   5. with --pause, a paused primary is replaced, and when it wakes up as a second primary the agent stops it; its
#      restart rejoins it as a standby with no manual step.
#
#   ./failover-test.sh [--kill] [--pause] [--keep]
#       --kill   stop the primary with SIGKILL (docker kill) instead of a clean stop: the rejoin then goes through
#                crash recovery and pg_rewind
#   PGHA_TEST_IMAGE=postgres:16-alpine ./failover-test.sh    (PostgreSQL 16)
#
# Runs on the host with docker compose and python3 (for millisecond timing); every SQL runs in the client container.
set -euo pipefail
cd "$(dirname "$0")"

KILL=false
PAUSE=false
KEEP=false
for arg in "$@"; do
  case $arg in
    --kill) KILL=true ;;
    --pause) PAUSE=true ;;
    --keep) KEEP=true ;;
    *) echo "usage: $0 [--kill] [--pause] [--keep]"; exit 2 ;;
  esac
done

COMPOSE=(docker compose -f docker-compose.test.yml)
CLUSTER=ha-test-postgres
TARGET_MS=15000

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAIL: %s\n' "$*"; exit 1; }

# q SQL: through the multi-host connection string (target_session_attrs=read-write), as a service connects.
q() { printf '%s\n' "$1" | "${COMPOSE[@]}" exec -T client sh -c 'psql "$DSN" -XAtq -v ON_ERROR_STOP=1' 2>&1; }
# on NODE SQL: on one node, as the failover superuser.
on() {
  printf '%s\n' "$2" | "${COMPOSE[@]}" exec -T client \
    sh -c "PGPASSWORD=failover-password PGCONNECT_TIMEOUT=2 psql -h $1 -U failover -d app_db -XAtq -v ON_ERROR_STOP=1" 2>&1
}
leader() { "${COMPOSE[@]}" exec -T pg-failover cat "/ha-state/$CLUSTER/primary" </dev/null 2>/dev/null | tr -d '\r'; }
agent_events() { # EVENT: how many times the agent logged it
  "${COMPOSE[@]}" logs --no-log-prefix pg-failover 2>/dev/null | { grep -o "\"event\":\"$1\"" || true; } | wc -l | tr -d ' '
}
node_events() { # NODE EVENT
  "${COMPOSE[@]}" logs --no-log-prefix "$1" 2>/dev/null | { grep -o "\"event\":\"$2\"" || true; } | wc -l | tr -d ' '
}
wait_for() { # SECONDS DESCRIPTION COMMAND...
  local limit=$1 what=$2 start
  shift 2
  start=$(now_ms)
  until "$@" >/dev/null 2>&1; do
    if [ $(( $(now_ms) - start )) -gt $((limit * 1000)) ]; then fail "$what (waited ${limit}s)"; fi
    sleep 1
  done
}
in_recovery() { [ "$(on "$1" 'select pg_is_in_recovery()')" = "t" ]; }
count_on() { on "$1" 'select count(*) from t'; }
events_at_least() { [ "$(agent_events "$1")" -ge "$2" ]; }
leader_moved_from() { local l; l=$(leader); [ -n "$l" ] && [ "$l" != "$1" ]; }
refuses_write() { # NODE ID: true when NODE answers the insert with the read-only error
  local out
  out=$(on "$1" "insert into t (id) values ($2)" || true)
  case $out in *"read-only transaction"*) return 0 ;; *) return 1 ;; esac
}
others() { local n; for n in "$CLUSTER-1" "$CLUSTER-2" "$CLUSTER-3"; do [ "$n" = "$1" ] || echo "$n"; done; }
writer_stopped() { ! "${COMPOSE[@]}" exec -T client sh -c 'ps' </dev/null 2>/dev/null | grep -q '[w]riter.sh'; }

step "fresh cluster: three nodes, the agent, a client"
"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d >/dev/null 2>&1
wait_for 120 "the agent turns synchronous replication on" events_at_least failover.sync_on 1
ok "primary $(leader), both standbys streaming, synchronous replication on"

step "writes through the multi-host connection string reach both standbys"
q 'create table t (id int primary key, at timestamptz default now())' >/dev/null
q 'insert into t (id) select generate_series(1, 100)' >/dev/null
sleep 1
for n in $(others "$(leader)"); do
  [ "$(count_on "$n")" = "100" ] || fail "$n has $(count_on "$n") rows, expected 100"
done
ok "100 rows on both standbys within 1 s"

step "a write on a standby is refused"
refuses_write "$(others "$(leader)" | sed -n 1p)" -1 && ok "cannot execute INSERT in a read-only transaction" \
  || fail "a standby accepted a write"

step "both standbys stopped: a write waits only until synchronous replication goes off"
primary=$(leader)
standbys=$(others "$primary" | tr '\n' ' ')
off_before=$(agent_events failover.sync_off)
# shellcheck disable=SC2086
"${COMPOSE[@]}" stop $standbys >/dev/null 2>&1
start=$(now_ms)
q 'insert into t (id) values (200)' >/dev/null || fail "the write failed instead of waiting"
waited=$(( $(now_ms) - start ))
[ "$(agent_events failover.sync_off)" -gt "$off_before" ] || fail "no failover.sync_off"
[ "$waited" -le 9000 ] || fail "the write waited ${waited} ms"
ok "the write went through after ${waited} ms, when the agent turned synchronous replication off"
# shellcheck disable=SC2086
"${COMPOSE[@]}" start $standbys >/dev/null 2>&1
wait_for 120 "the standbys stream again and synchronous replication is back" events_at_least failover.sync_on 2
ok "the standbys stream again; synchronous replication on"

step "stop the primary while a writer runs ($($KILL && echo 'docker kill' || echo 'docker stop'))"
old=$(leader)
"${COMPOSE[@]}" exec -T client sh -c 'cat > /tmp/writer.sh <<"EOS"
rm -f /tmp/acked /tmp/stop; i=1000
while [ ! -f /tmp/stop ] && [ $i -lt 9000 ]; do
  psql "$DSN" -XAtq -c "insert into t (id) values ($i)" >/dev/null 2>&1 && echo $i >> /tmp/acked; i=$((i + 1))
done
EOS
' </dev/null
"${COMPOSE[@]}" exec -T -d client sh /tmp/writer.sh </dev/null
sleep 2
start=$(now_ms)
if $KILL; then "${COMPOSE[@]}" kill "$old" >/dev/null 2>&1; else "${COMPOSE[@]}" stop "$old" >/dev/null 2>&1; fi
probe=50000
until q "insert into t (id) values ($probe)" >/dev/null 2>&1 && [ "$(q "select count(*) from t where id = $probe")" = "1" ]; do
  probe=$((probe + 1))
  sleep 0.2
done
took=$(( $(now_ms) - start ))
new=$(leader)
[ "$new" != "$old" ] || fail "the leader file still names $old"
[ "$(agent_events failover.promoted)" -ge 1 ] || fail "no failover.promoted event"
[ "$(agent_events failover.promote_failed)" = "0" ] || fail "failover.promote_failed was logged"
in_recovery "$new" && fail "$new is still in recovery"
if [ "$took" -le "$TARGET_MS" ]; then ok "writes work again after ${took} ms (target ${TARGET_MS} ms); new primary $new"
else fail "writes worked again only after ${took} ms (target ${TARGET_MS} ms)"; fi

step "no acknowledged commit was lost"
sleep 2
"${COMPOSE[@]}" exec -T client touch /tmp/stop </dev/null
wait_for 30 "the writer stops" writer_stopped
acked=$("${COMPOSE[@]}" exec -T client sh -c 'cat /tmp/acked 2>/dev/null' </dev/null | tr -d '\r' | paste -sd, -)
total=$(printf '%s' "$acked" | tr ',' '\n' | grep -c . || true)
present=$(q "select count(*) from t where id in (${acked:-0})")
[ "$present" = "$total" ] || fail "$total writes were acknowledged, $present are on the new primary"
ok "all $total acknowledged writes are on the new primary"

step "the old primary rejoins as a standby of the new one"
rejoined_before=$(agent_events failover.rejoined)
if $KILL; then "${COMPOSE[@]}" start "$old" >/dev/null 2>&1; else "${COMPOSE[@]}" start "$old" >/dev/null 2>&1; fi
wait_for 120 "$old answers as a standby" in_recovery "$old"
wait_for 30 "failover.rejoined" events_at_least failover.rejoined $((rejoined_before + 1))
q 'insert into t (id) values (60000)' >/dev/null
sleep 1
for n in "$CLUSTER-1" "$CLUSTER-2" "$CLUSTER-3"; do
  [ "$(count_on "$n")" = "$(q 'select count(*) from t')" ] || fail "$n is behind the primary"
done
refuses_write "$old" -2 || fail "$old accepted a write"
if [ "$(node_events "$old" node.rewind_failed)" != "0" ]; then fail "pg_rewind failed on $old (a re-clone was needed)"; fi
ok "$old rewound and streams as a standby (failover.rejoined); all three nodes hold the same rows; it refuses writes"

if $PAUSE; then
  step "a paused primary that wakes up after the failover is stopped and rejoins by itself"
  paused=$(leader)
  fenced_before=$(agent_events failover.fenced)
  rejoined_before=$(agent_events failover.rejoined)
  "${COMPOSE[@]}" pause "$paused" >/dev/null 2>&1
  wait_for 60 "the agent promotes a standby" leader_moved_from "$paused"
  promoted=$(leader)
  "${COMPOSE[@]}" unpause "$paused" >/dev/null 2>&1
  wait_for 30 "the agent stops the woken primary" events_at_least failover.fenced $((fenced_before + 1))
  q 'insert into t (id) values (70000)' >/dev/null || fail "no write after the fencing"
  wait_for 120 "$paused rejoins as a standby with no manual restart" in_recovery "$paused"
  wait_for 30 "failover.rejoined" events_at_least failover.rejoined $((rejoined_before + 1))
  [ "$(agent_events failover.fenced)" = "$((fenced_before + 1))" ] || fail "the woken primary was fenced more than once"
  ok "$promoted took over, $paused was stopped once and rejoined as a standby by its restart"
fi

step "agent events"
"${COMPOSE[@]}" logs --no-log-prefix pg-failover 2>/dev/null | grep -o '"event":"[a-z_.]*"' | sort | uniq -c

if $KEEP; then
  echo; echo "kept: ${COMPOSE[*]} down -v   to remove it"
else
  "${COMPOSE[@]}" down -v >/dev/null 2>&1
fi
echo; echo "PASS"
