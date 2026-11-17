#!/usr/bin/env bash
# Shared helpers of the PostgreSQL replication pattern (#164), sourced by node.sh and pg-failover.sh.
#
# log LEVEL EVENT MSG [KEY VALUE]...  prints one JSON object per line in the team's log format (README "Logging"):
#   time (UTC, milliseconds, Z), level, service, instance_id, version, event, msg, then the extra keys. Alloy turns
#   level, service and event into Loki labels.
# sql HOST QUERY                      runs one statement as the `failover` superuser on HOST and prints the bare
#   result (psql -XAt); connect and statement timeouts keep a paused or dead host from hanging the caller.

export TZ=UTC
PGHA_VERSION="${PGHA_VERSION:-5.0.0}"
PGHA_SERVICE="${PGHA_SERVICE:-pg-ha}"
PGHA_INSTANCE="${PGHA_INSTANCE:-$(hostname)}"

json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

log() {
  local level=$1 event=$2 msg=$3
  shift 3
  local now=$EPOCHREALTIME
  local ts frac extra="" key
  frac=${now#*.}
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' "${now%.*}"
  while [ $# -ge 2 ]; do
    key=$1
    extra+=",\"$key\":\"$(json_escape "$2")\""
    shift 2
  done
  printf '{"time":"%s.%sZ","level":"%s","service":"%s","instance_id":"%s","version":"%s","event":"%s","msg":"%s"%s}\n' \
    "$ts" "${frac:0:3}" "$level" "$PGHA_SERVICE" "$PGHA_INSTANCE" "$PGHA_VERSION" "$event" "$(json_escape "$msg")" "$extra"
}

sql() {
  local host=$1 query=$2
  PGCONNECT_TIMEOUT=2 PGPASSWORD=$FAILOVER_PASSWORD PGOPTIONS='-c statement_timeout=3000' \
    psql -h "$host" -p 5432 -U failover -d postgres -XAtq -v ON_ERROR_STOP=1 -c "$query" 2>/dev/null
}

# is_primary HOST: true when HOST answers and is not in recovery.
is_primary() {
  [ "$(sql "$1" 'select not pg_is_in_recovery()')" = "t" ]
}
