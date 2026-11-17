#!/usr/bin/env bash
# Shared helpers of the PostgreSQL replication pattern (#164), sourced by node.sh, pg-failover.sh and roles.sh.
#
# log LEVEL EVENT MSG [KEY VALUE]...  prints one JSON object per line in the team's log format (README "Logging"):
#   time (UTC, milliseconds, Z), level, service, instance_id, version, event, msg, then the extra keys. Alloy turns
#   level, service and event into Loki labels.
# sql HOST QUERY                      runs one statement as the `failover` superuser on HOST and prints the bare
#   result (psql -XAt). Every call is bounded by a wall-clock `timeout` (PGHA_SQL_TIMEOUT, 3 s): PGCONNECT_TIMEOUT
#   does not cover the DNS lookup of a stopped container (5 to 10 s on Docker Desktop for Windows), and a frozen
#   server (docker pause, an I/O stall) never enforces its own statement_timeout.
# sql_long HOST QUERY SECONDS          the same with a longer bound, for pg_promote().
# resolves HOST                        true when the container's name resolves, i.e. the container exists (running
#   or paused); a stopped container's name stops resolving in Docker's DNS.

export TZ=UTC
PGHA_VERSION="${PGHA_VERSION:-5.0.0}"
PGHA_SERVICE="${PGHA_SERVICE:-pg-ha}"
PGHA_INSTANCE="${PGHA_INSTANCE:-$(hostname)}"
PGHA_SQL_TIMEOUT="${PGHA_SQL_TIMEOUT:-3}"

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

now_s() { echo "${EPOCHREALTIME%.*}"; }

sql_long() {
  local host=$1 query=$2 bound=$3
  PGCONNECT_TIMEOUT=2 PGPASSWORD=$FAILOVER_PASSWORD PGOPTIONS="-c statement_timeout=$((bound * 1000))" \
    timeout -s KILL "$bound" psql -h "$host" -p 5432 -U failover -d postgres -XAtq -v ON_ERROR_STOP=1 -c "$query" 2>/dev/null
}

sql() {
  sql_long "$1" "$2" "$PGHA_SQL_TIMEOUT"
}

# is_primary HOST: true when HOST answers and is not in recovery.
is_primary() {
  [ "$(sql "$1" 'select not pg_is_in_recovery()')" = "t" ]
}

resolves() {
  if command -v getent >/dev/null 2>&1; then
    timeout -s KILL 2 getent hosts "$1" >/dev/null 2>&1
  else
    # No getent (postgres:16-alpine): a refused or timed-out connection still means the name resolved.
    local out
    out=$(timeout -s KILL 2 bash -c ": </dev/tcp/$1/5432" 2>&1) && return 0
    case $out in *"not known"*|*"resolve"*|*"Unknown host"*) return 1 ;; *) return 0 ;; esac
  fi
}
