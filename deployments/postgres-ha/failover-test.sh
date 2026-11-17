#!/usr/bin/env bash
# Proves the PostgreSQL replication pattern (#164) on a throw-away cluster (docker-compose.test.yml, project
# pgha-test): replication to both standbys, a refused write on a standby, a failover while a writer runs (the time
# until writes work again and no acknowledged commit lost), the old primary rejoining as a standby, and with --pause a
# paused primary that wakes up after the failover being fenced read-only by the agent.
#
#   ./failover-test.sh [--pause] [--keep]     PGHA_TEST_IMAGE=postgres:16-alpine ./failover-test.sh  (PostgreSQL 16)
#
# Runs on the host with docker compose and python3 (for millisecond timing); every SQL runs in the client container.
set -euo pipefail
cd "$(dirname "$0")"

PAUSE=false
KEEP=false
for arg in "$@"; do
  case $arg in
    --pause) PAUSE=true ;;
    --keep) KEEP=true ;;
    *) echo "usage: $0 [--pause] [--keep]"; exit 2 ;;
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
leader() { "${COMPOSE[@]}" exec -T pg-failover cat "/ha-state/$CLUSTER/primary" 2>/dev/null | tr -d '\r'; }
agent_events() { # EVENT: how many times the agent logged it
  "${COMPOSE[@]}" logs --no-log-prefix pg-failover 2>/dev/null | { grep -o "\"event\":\"$1\"" || true; } | wc -l | tr -d ' '
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
refuses_write() { # NODE ID: true when NODE answers the insert with the read-only error
  local out
  out=$(on "$1" "insert into t (id) values ($2)" || true)
  case $out in *"read-only transaction"*) return 0 ;; *) return 1 ;; esac
}
in_recovery() { [ "$(on "$1" 'select pg_is_in_recovery()')" = "t" ]; }
count_on() { on "$1" 'select count(*) from t'; }
sync_is_on() { [ "$(agent_events failover.sync_on)" -ge 1 ]; }
leader_moved_from() { [ "$(leader)" != "$1" ] && [ -n "$(leader)" ]; }
fenced_more_than() { [ "$(agent_events failover.fenced)" -gt "$1" ]; }

step "fresh cluster: three nodes, the agent, a client"
"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d >/dev/null 2>&1
wait_for 120 "the agent turns synchronous replication on" sync_is_on
ok "primary $(leader), both standbys streaming, synchronous replication on"

step "writes through the multi-host connection string reach both standbys"
q 'create table t (id int primary key, at timestamptz default now())' >/dev/null
q 'insert into t (id) select generate_series(1, 100)' >/dev/null
sleep 1
for n in 2 3; do
  [ "$(count_on "$CLUSTER-$n")" = "100" ] || fail "$CLUSTER-$n has $(count_on "$CLUSTER-$n") rows, expected 100"
done
ok "100 rows on $CLUSTER-2 and $CLUSTER-3 within 1 s"

step "a write on a standby is refused"
if refuses_write "$CLUSTER-2" -1; then
  ok "cannot execute INSERT in a read-only transaction"
else
  fail "a standby accepted a write"
fi

step "stop the primary while a writer runs"
old=$(leader)
"${COMPOSE[@]}" exec -T -d client sh -c 'rm -f /tmp/acked; i=1000; while [ $i -lt 1600 ]; do
  psql "$DSN" -XAtq -c "insert into t (id) values ($i)" >/dev/null 2>&1 && echo $i >> /tmp/acked; i=$((i + 1)); done'
sleep 2
start=$(now_ms)
"${COMPOSE[@]}" stop "$old" >/dev/null 2>&1
probe=5000
until q "insert into t (id) values ($probe)" >/dev/null 2>&1 && [ "$(q "select count(*) from t where id = $probe")" = "1" ]; do
  probe=$((probe + 1))
  sleep 0.2
done
took=$(( $(now_ms) - start ))
new=$(leader)
[ "$new" != "$old" ] || fail "the leader file still names $old"
[ "$(agent_events failover.promoted)" -ge 1 ] || fail "no failover.promoted event"
in_recovery "$new" && fail "$new is still in recovery"
if [ "$took" -le "$TARGET_MS" ]; then ok "writes work again after ${took} ms (target ${TARGET_MS} ms); new primary $new"
else fail "writes worked again only after ${took} ms (target ${TARGET_MS} ms)"; fi

step "no acknowledged commit was lost"
sleep 3
acked=$("${COMPOSE[@]}" exec -T client sh -c 'cat /tmp/acked 2>/dev/null' | tr -d '\r' | paste -sd, -)
total=$(printf '%s' "$acked" | tr ',' '\n' | grep -c . || true)
present=$(q "select count(*) from t where id in (${acked:-0})")
[ "$present" = "$total" ] || fail "$total writes were acknowledged, $present are on the new primary"
ok "all $total acknowledged writes are on the new primary"

step "the old primary rejoins as a standby of the new one"
"${COMPOSE[@]}" start "$old" >/dev/null 2>&1
wait_for 120 "$old answers as a standby" in_recovery "$old"
q 'insert into t (id) values (7000)' >/dev/null
sleep 1
for n in 1 2 3; do
  [ "$(count_on "$CLUSTER-$n")" = "$(q 'select count(*) from t')" ] || fail "$CLUSTER-$n is behind the primary"
done
refuses_write "$old" -2 || fail "$old accepted a write"
ok "$old is a standby again, all three nodes hold the same rows, and it refuses writes"

if $PAUSE; then
  step "a paused primary that wakes up after the failover is fenced"
  paused=$(leader)
  fenced_before=$(agent_events failover.fenced)
  "${COMPOSE[@]}" pause "$paused" >/dev/null 2>&1
  wait_for 60 "the agent promotes a standby" leader_moved_from "$paused"
  promoted=$(leader)
  "${COMPOSE[@]}" unpause "$paused" >/dev/null 2>&1
  wait_for 30 "the agent fences the woken primary" fenced_more_than "$fenced_before"
  q 'insert into t (id) values (8000)' >/dev/null || fail "no write after the fencing"
  [ "$(on "$paused" 'show default_transaction_read_only')" = "on" ] || fail "$paused is not read-only"
  ok "$promoted took over, $paused is read-only and clients write to $promoted"
  "${COMPOSE[@]}" restart "$paused" >/dev/null 2>&1
  wait_for 120 "$paused rejoins as a standby after a restart" in_recovery "$paused"
  ok "$paused rejoined as a standby after a restart"
fi

step "agent events"
"${COMPOSE[@]}" logs --no-log-prefix pg-failover 2>/dev/null | grep -o '"event":"[a-z_.]*"' | sort | uniq -c

if $KEEP; then
  echo; echo "kept: ${COMPOSE[*]} down -v   to remove it"
else
  "${COMPOSE[@]}" down -v >/dev/null 2>&1
fi
echo; echo "PASS"
