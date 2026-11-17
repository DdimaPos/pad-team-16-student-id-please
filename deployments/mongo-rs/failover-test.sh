#!/usr/bin/env bash
# Proves the MongoDB replica set pattern (#164) on a throw-away set (docker-compose.test.yml, project mongors-test):
# replication to both secondaries, a refused write on a secondary, a failover while a writer runs (the time until
# writes work again and no acknowledged write lost), the old primary rejoining as a secondary, and `etl_reader`
# reading but not writing.
#
#   ./failover-test.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")"

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
COMPOSE=(docker compose -f docker-compose.test.yml)
TARGET_MS=15000

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAIL: %s\n' "$*"; exit 1; }

# Every docker compose exec below reads from /dev/null: exec forwards stdin, and inside a pipeline it would swallow
# the pipe meant for the next command.
# m JS: through the replica set URI (the way a service connects), as root.
m() { "${COMPOSE[@]}" exec -T client sh -c "mongosh --quiet \"\$URI\" --eval '$1'" </dev/null 2>&1 | tr -d '\r'; }
# on MEMBER JS: on one member directly, as root, reading from it even when it is a secondary.
on() {
  "${COMPOSE[@]}" exec -T client sh -c "mongosh --quiet 'mongodb://root:root-password@$1:27017/app_db?authSource=admin&directConnection=true&readPreference=secondaryPreferred' --eval '$2'" </dev/null 2>&1 | tr -d '\r'
}
primary() { m 'rs.status().members.filter(x => x.stateStr === "PRIMARY").map(x => x.name.split(":")[0]).join("")'; }
state_of() { m "rs.status().members.filter(x => x.name.startsWith(\"$1:\")).map(x => x.stateStr).join(\"\")"; }
init_done() { "${COMPOSE[@]}" ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}' | grep -q 'ha-test-mongo-init exited 0'; }
is_secondary() { [ "$(state_of "$1")" = "SECONDARY" ]; }
wait_for() {
  local limit=$1 what=$2 start
  shift 2
  start=$(now_ms)
  until "$@" >/dev/null 2>&1; do
    if [ $(( $(now_ms) - start )) -gt $((limit * 1000)) ]; then fail "$what (waited ${limit}s)"; fi
    sleep 1
  done
}

step "fresh replica set: three members, the init, a client"
"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d >/dev/null 2>&1
wait_for 180 "the init container finishes" init_done
ok "primary $(primary), init done"

step "writes through the replica set URI reach both secondaries"
m 'db.t.insertMany(Array.from({ length: 100 }, (_, i) => ({ _id: i + 1 }))).insertedIds.length' >/dev/null
sleep 1
for n in $(printf '%s\n' ha-test-mongo-1 ha-test-mongo-2 ha-test-mongo-3 | grep -v "^$(primary)$"); do
  [ "$(on "$n" 'db.t.countDocuments()')" = "100" ] || fail "$n has $(on "$n" 'db.t.countDocuments()') documents, expected 100"
done
ok "100 documents on both secondaries within 1 s"

step "a write on a secondary is refused"
secondary=$(printf '%s\n' ha-test-mongo-1 ha-test-mongo-2 ha-test-mongo-3 | grep -v "^$(primary)$" | sed -n 1p)
case $(on "$secondary" 'try { db.t.insertOne({ _id: -1 }); "accepted" } catch (e) { e.codeName }') in
  *NotWritablePrimary*) ok "NotWritablePrimary on $secondary" ;;
  *) fail "$secondary accepted a write" ;;
esac

step "stop the primary while a writer runs"
old=$(primary)
"${COMPOSE[@]}" exec -T -d client sh -c "mongosh --quiet \"\$URI\" --eval '
  const fs = require(\"fs\"); fs.writeFileSync(\"/tmp/acked\", \"\");
  const end = Date.now() + 40000; let i = 1000;
  while (Date.now() < end) {
    try { db.t.insertOne({ _id: i }); fs.appendFileSync(\"/tmp/acked\", i + \"\\n\"); } catch (e) {}
    i++; sleep(20);
  }' >/dev/null 2>&1"
sleep 3
start=$(now_ms)
"${COMPOSE[@]}" stop "$old" >/dev/null 2>&1
probe=5000
until [ "$("${COMPOSE[@]}" exec -T client sh -c "mongosh --quiet \"\$URI&serverSelectionTimeoutMS=1000\" --eval 'db.t.insertOne({ _id: $probe }).acknowledged'" </dev/null 2>/dev/null | tr -d '\r')" = "true" ]; do
  probe=$((probe + 1))
done
took=$(( $(now_ms) - start ))
new=$(primary)
[ -n "$new" ] && [ "$new" != "$old" ] || fail "no new primary"
if [ "$took" -le "$TARGET_MS" ]; then ok "writes work again after ${took} ms (target ${TARGET_MS} ms); new primary $new"
else fail "writes worked again only after ${took} ms (target ${TARGET_MS} ms)"; fi

step "no acknowledged write was lost"
sleep 40
acked=$("${COMPOSE[@]}" exec -T client sh -c 'cat /tmp/acked' | tr -d '\r' | grep -c . || true)
present=$(m "const ids = require(\"fs\").readFileSync(\"/tmp/acked\", \"utf8\").trim().split(\"\\n\").map(Number); db.t.countDocuments({ _id: { \$in: ids } })")
[ "$present" = "$acked" ] || fail "$acked writes were acknowledged, $present are on the new primary"
ok "all $acked acknowledged writes are on the new primary"

step "the old primary rejoins as a secondary"
"${COMPOSE[@]}" start "$old" >/dev/null 2>&1
wait_for 120 "$old is a secondary" is_secondary "$old"
total=$(m 'db.t.countDocuments()')
sleep 1
[ "$(on "$old" 'db.t.countDocuments()')" = "$total" ] || fail "$old is behind the primary"
ok "$old is a secondary with all $total documents"

step "etl_reader reads the service database and cannot write"
etl() {
  "${COMPOSE[@]}" exec -T client sh -c "mongosh --quiet 'mongodb://etl_reader:etl-password@ha-test-mongo-1:27017,ha-test-mongo-2:27017,ha-test-mongo-3:27017/app_db?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred' --eval '$1'" </dev/null 2>&1 | tr -d '\r'
}
[ "$(etl 'db.t.countDocuments()')" = "$total" ] || fail "etl_reader cannot read"
case $(etl 'try { db.t.insertOne({ _id: -2 }); "accepted" } catch (e) { e.codeName }') in
  *Unauthorized*) ok "etl_reader reads $total documents and is refused a write" ;;
  *) fail "etl_reader could write" ;;
esac

if $KEEP; then echo; echo "kept: ${COMPOSE[*]} down -v   to remove it"; else "${COMPOSE[@]}" down -v >/dev/null 2>&1; fi
echo; echo "PASS"
