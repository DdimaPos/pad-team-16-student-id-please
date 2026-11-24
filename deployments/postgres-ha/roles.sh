#!/usr/bin/env bash
# Prints the role of every node of every cluster the agent watches, for the demonstration (`docker ps` shows only
# "healthy" for a primary and a standby alike; the healthcheck's own output, in `docker inspect`, also names it):
#   docker compose exec pg-failover bash /ha/roles.sh
# One line per node: the cluster, the node (the leader file's choice marked), primary / standby / no answer, its WAL
# position, and for a standby the primary it streams from.
set -uo pipefail
. /ha/lib.sh
: "${FAILOVER_PASSWORD:?}"
printf '%-24s %-38s %-10s %-12s %s\n' CLUSTER NODE ROLE WAL STREAMS_FROM
for cluster in ${PGHA_CLUSTERS:-}; do
  leader=$(cat "/ha-state/$cluster/primary" 2>/dev/null || echo "$cluster-1")
  for node in "$cluster-1" "$cluster-2" "$cluster-3"; do
    row=$(sql "$node" "select case when pg_is_in_recovery() then 'standby' else 'primary' end,
                      case when pg_is_in_recovery()
                           then coalesce(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::text
                           else pg_current_wal_lsn()::text end,
                      coalesce((select sender_host from pg_stat_wal_receiver where status = 'streaming'), '-')") || row=""
    mark=""
    [ "$node" = "$leader" ] && mark=" (leader file)"
    if [ -z "$row" ]; then
      printf '%-24s %-38s %-10s %-12s %s\n' "$cluster" "$node$mark" "no answer" "-" "-"
    else
      IFS='|' read -r role wal from <<< "$row"
      printf '%-24s %-38s %-10s %-12s %s\n' "$cluster" "$node$mark" "$role" "$wal" "$from"
    fi
  done
done
