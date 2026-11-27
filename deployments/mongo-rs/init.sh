#!/usr/bin/env bash
# One-shot init of a MongoDB replica set (#164), run by a short-lived container of the mongo image after the members
# start (`restart: "no"`; the services wait for it with `condition: service_completed_successfully`).
#
#   1. waits until every member answers a ping;
#   2. initiates the replica set once, through the first member, as its root user (a set that is already initiated is
#      left as it is), with electionTimeoutMillis 5000, so a new primary is elected about 5 s after the old one stops
#      (MongoDB's default is 10 s);
#   3. waits for a primary;
#   4. creates `etl_reader` (role `read` on MONGO_APP_DB, in `admin`) for the ETL (#165), or updates its password.
# Running it again changes nothing but the password, so `docker compose up -d` may start it any number of times.
#
# Environment: MONGO_RS_MEMBERS (member host names, space-separated, the first one with the root user),
# MONGO_ROOT_USER, MONGO_ROOT_PASSWORD, MONGO_APP_DB, ETL_READER_PASSWORD (empty: no etl_reader), MONGO_REPLSET (rs0).
set -euo pipefail

: "${MONGO_RS_MEMBERS:?}" "${MONGO_ROOT_USER:?}" "${MONGO_ROOT_PASSWORD:?}" "${MONGO_APP_DB:?}"
export MONGO_REPLSET=${MONGO_REPLSET:-rs0}
export TZ=UTC
first=${MONGO_RS_MEMBERS%% *}
hosts=""
for member in $MONGO_RS_MEMBERS; do hosts+="$member:27017,"; done
hosts=${hosts%,}

log() {
  local level=$1 event=$2 msg=$3 now=$EPOCHREALTIME ts
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' "${now%.*}"
  printf '{"time":"%s.%sZ","level":"%s","service":"mongo-rs-init","instance_id":"%s","version":"5.0.0","event":"%s","msg":"%s","replica_set":"%s"}\n' \
    "$ts" "$(printf '%s' "${now#*.}" | cut -c1-3)" "$level" "$(hostname)" "$event" "$msg" "$MONGO_REPLSET"
}

as_root() { mongosh --quiet -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin "$@"; }

for member in $MONGO_RS_MEMBERS; do
  until mongosh --quiet --host "$member" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; do sleep 1; done
done
log info rs.members_up "every member answers"

state=$(as_root --host "$first" --eval '
  try { rs.status(); print("initiated"); }
  catch (e) {
    if (e.codeName !== "NotYetInitialized") throw e;
    const members = process.env.MONGO_RS_MEMBERS.trim().split(/\s+/);
    rs.initiate({
      _id: process.env.MONGO_REPLSET,
      settings: { electionTimeoutMillis: 5000 },
      members: members.map((host, i) => ({ _id: i, host: host + ":27017" })),
    });
    print("initiating");
  }')
log info "rs.$state" "replica set $state"

until [ "$(as_root --host "$MONGO_REPLSET/$hosts" --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = "true" ]; do
  sleep 1
done
log info rs.primary "the replica set has a primary"

if [ -n "${ETL_READER_PASSWORD:-}" ]; then
  as_root --host "$MONGO_REPLSET/$hosts" --eval '
    const admin = db.getSiblingDB("admin");
    const roles = [{ role: "read", db: process.env.MONGO_APP_DB }];
    if (admin.getUser("etl_reader")) admin.updateUser("etl_reader", { pwd: process.env.ETL_READER_PASSWORD, roles });
    else admin.createUser({ user: "etl_reader", pwd: process.env.ETL_READER_PASSWORD, roles });' >/dev/null
  log info rs.etl_reader "etl_reader can read the service database"
fi
