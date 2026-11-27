# PostgreSQL replication and failover (#164)

Every PostgreSQL database of the services runs as one primary and two hot standbys, with an agent that promotes a
standby when the primary stops (contract decision 3 of #163, README "Database replication"). Everything runs on the
official `postgres` image (16 or 17); this folder is bind-mounted read-only into the containers.

| File | What it is |
| --- | --- |
| `node.sh` | Entrypoint of every node. Decides the node's role before PostgreSQL starts (see "No second primary") |
| `initdb.sh` | Run once by the first node on an empty data directory: the `replicator`, `failover` and `etl_reader` roles |
| `pg_hba.conf` | Client authentication of every node (the image's lines plus the replication line) |
| `pg-failover.sh` | The failover agent, one container for every cluster |
| `lib.sh` | JSON log lines in the team's format, `psql` helpers bounded by a wall-clock timeout |
| `roles.sh` | Prints every node's role, WAL position and upstream, for the demonstration |
| `docker-compose.test.yml`, `failover-test.sh` | A throw-away cluster and the test that proves all of this |

## How it works

- **Replication.** Physical streaming replication. `<db>-1` starts as the primary; `<db>-2` and `<db>-3` clone it with
  `pg_basebackup` (then `node.sh` writes their `primary_conninfo` itself, as the replicator) and follow it as hot
  standbys (they answer reads, refuse writes). `wal_log_hints` and `wal_keep_size = 512MB` are stored in the data
  directory by `initdb.sh`, so they also hold for the crash recovery `pg_rewind` runs after an unclean stop.
- **Synchronous commit.** While a standby streams, the agent sets `synchronous_standby_names = 'ANY 1 (*)'` on the
  primary: a commit returns only when one standby has it, so a failover never loses an acknowledged write. With no
  streaming standby for 4 s (`PGHA_SYNC_DEGRADE_SECONDS`) the agent resets it, because every write would otherwise
  wait until a standby is back; it turns it on again when one is (`failover.sync_on`, `failover.sync_off`). Measured:
  with both standbys stopped, a write goes through after about 4 to 5 s.
- **Failover.** Each cluster has its own loop in the agent, so a node that hangs in one cluster never delays another,
  and every database call is bounded by a 3 s wall-clock `timeout`: `PGCONNECT_TIMEOUT` does not cover the DNS
  lookup of a stopped container, which takes 5 to 10 s on Docker Desktop for Windows, and a frozen server never
  enforces its own statement timeout. When the primary has not answered as a primary for 6 s
  (`PGHA_FAILOVER_AFTER_SECONDS`), the agent asks every other node whose name resolves (its container exists, running
  or paused) for its received WAL position, 3 tries each. If one does not answer, nothing is promoted that round
  (`failover.candidate_unreachable`): it may be the standby that holds the last acknowledged commits. Otherwise the
  most advanced standby is written to the leader file, promoted (`pg_promote()`, with its own 20 s bound), and the other
  standby is re-pointed to it (`ALTER SYSTEM SET primary_conninfo`, `pg_reload_conf()`). Measured with
  `failover-test.sh` on Docker Desktop for macOS: **writes work again about 5.8 s after the primary stops**, with
  `docker stop` and with `docker kill`, PostgreSQL 17 and 16, and every acknowledged write is on the new primary.
- **No second primary.** The agent keeps the current primary's name in a shared volume (`/ha-state/<cluster>/primary`).
  `node.sh` reads it before PostgreSQL starts: an old primary that comes back sees another leader, runs `pg_rewind`
  (or a fresh `pg_basebackup` when the rewind fails) and starts as that leader's standby, so it never takes a write;
  the agent logs `failover.rejoined` when it streams again. A primary that was paused rather than stopped
  (`docker pause`) and wakes up after the failover is stopped by the agent, once (`failover.fenced`:
  `COPY ... TO PROGRAM 'kill -INT 1'`, a fast shutdown of its postmaster); its restart policy starts it again, and
  `node.sh` rewinds it into a standby with no manual step.
- **Which node is the primary.** `docker ps` shows every node as `healthy` (a standby must not block `depends_on`),
  so the healthcheck prints the role into its output (`docker inspect`), and
  `docker compose exec pg-failover bash /ha/roles.sh` prints a table: node, role, WAL position, and the primary each
  standby streams from, with the leader file's choice marked.
- **Clients.** A service lists the three nodes and asks for the read-write one; the driver tries them in order and
  skips the standbys, so no proxy sits in between:
  - pgx (Go): `postgres://<user>:<pw>@<db>-1:5432,<db>-2:5432,<db>-3:5432/<name>?sslmode=disable&target_session_attrs=read-write&connect_timeout=1`
  - Npgsql (C#): `Host=<db>-1,<db>-2,<db>-3;Port=5432;Database=<name>;Username=<user>;Password=<pw>;Target Session Attributes=read-write;Timeout=1;Host Recheck Seconds=2`
  - the ETL reads with `target_session_attrs=prefer-standby`.

  **1 s timeouts and `dns_opt`.** On Docker Desktop for Windows the DNS lookup of a stopped container's name fails
  only after 5 to 16 s, and no connect timeout covers DNS, so a longer timeout made every new connection wait while
  `<db>-1` was down, with the new primary up (measured on #184: `408` on every create with `Timeout=3`). Every
  compose block that connects to a replicated database (the services, `pg-failover`, the ETL) therefore also gets
  `dns_opt: ["timeout:1", "attempts:1"]`, and a request takes one connection from the pool, never one per query.
  While no primary answers, the service answers `500 DEPENDENCY_UNAVAILABLE` (`details.dependency` naming the
  database) and its `/status` says `degraded`; see the shared brief and decision 3.

## Converting a service's database

1. Replace the database block with three nodes from the block below (one named volume per node), and add the cluster
   to `PGHA_CLUSTERS` of `pg-failover`.
2. Change the service's connection string to the multi-host form above; point its `depends_on` at `<db>-1`, and
   give its block `dns_opt: ["timeout:1", "attempts:1"]`.
3. Start with **new volumes** (`docker compose down -v` or new volume names): `initdb.sh` runs only on an empty data
   directory, and the roles of the pattern must exist. The services seed their data again on start.
4. Grant `etl_reader` in the service's own migrations what the ETL may read (never secrets; see #165).

```yaml
x-moderation-pg-env: &moderation_pg_env
  POSTGRES_USER: ${MODERATION_POSTGRES_USER:-moderation_user}
  POSTGRES_PASSWORD: ${MODERATION_POSTGRES_PASSWORD:?set MODERATION_POSTGRES_PASSWORD in .env}
  POSTGRES_DB: ${MODERATION_POSTGRES_DB:-moderation_db}
  PGHA_CLUSTER: moderation-postgres
  PGHA_NODES: "moderation-postgres-1 moderation-postgres-2 moderation-postgres-3"
  REPLICATION_PASSWORD: ${REPLICATION_PASSWORD:?set REPLICATION_PASSWORD in .env}
  FAILOVER_PASSWORD: ${FAILOVER_PASSWORD:?set FAILOVER_PASSWORD in .env}
  ETL_READER_PASSWORD: ${ETL_READER_PASSWORD:?set ETL_READER_PASSWORD in .env}

x-moderation-pg-node: &moderation_pg_node
  image: postgres:17-alpine
  restart: unless-stopped
  entrypoint: ["bash", "/ha/node.sh"]
  stop_grace_period: 30s
  networks: [student-id-net]
  healthcheck:              # healthy as a primary and as a standby; the output names the role
    test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\" && psql -h 127.0.0.1 -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\" -XAtc \"select case when pg_is_in_recovery() then 'standby' else 'primary' end\""]
    interval: 5s
    timeout: 5s
    retries: 20

services:
  moderation-postgres-1:
    <<: *moderation_pg_node
    environment: { <<: *moderation_pg_env, PGHA_NODE: moderation-postgres-1 }
    ports: ["5436:5432"]            # optional: one node keeps the old host port, for debugging only
    volumes:
      - moderation_pgdata_1:/var/lib/postgresql/data
      - ./deployments/postgres-ha:/ha:ro
      - ./deployments/postgres-ha/initdb.sh:/docker-entrypoint-initdb.d/10-replication.sh:ro
      - pg_ha_state:/ha-state:ro
  moderation-postgres-2:             # the same with PGHA_NODE: moderation-postgres-2, volume moderation_pgdata_2, no ports
  moderation-postgres-3:             # the same with PGHA_NODE: moderation-postgres-3, volume moderation_pgdata_3, no ports
```

The scripts must keep their executable bit (`git` stores it): Docker Desktop on macOS reports a
bind-mounted script as executable even when it is not, and the image's entrypoint then fails to run `initdb.sh`.

## Test

```bash
./failover-test.sh                  # PostgreSQL 17: replication, refused standby write, both standbys down,
                                    # failover under load, no acknowledged write lost, rejoin through pg_rewind
./failover-test.sh --kill --pause   # SIGKILL instead of a clean stop; a paused primary stopped once and rejoining
PGHA_TEST_IMAGE=postgres:16-alpine ./failover-test.sh
```

It needs Docker and `python3` on the host, uses its own compose project (`pgha-test`) and removes it at the end
(`--keep` keeps it).

## Limits

- The agent is one container: while it is down, nobody promotes a standby (the cluster keeps working as long as its
  primary does). It restarts with `restart: unless-stopped` and reads the leader files again.
- **A lost `pg_ha_state` volume** after a failover makes `<db>-1` the leader again on start, on the old timeline: the
  writes since the failover would be rewound away on the node that had them. Do not remove that volume while a
  cluster's volumes are kept (`docker compose down -v` removes them all together).
- **A leader file that names a dead node** while the other nodes restart leaves them waiting (`node.waiting`) and the
  agent at `failover.no_candidate`: start the dead node, or put a live node's name in the file.
- **No replication slots** (they do not follow a failover before PostgreSQL 17): a standby that falls more than
  `wal_keep_size` (512 MB) behind stops streaming; remove its volume and it clones itself again on start.
- `failover` is a superuser reachable inside `student-id-net`, like every database user of the stack; its password is
  never on a command line (`PGPASSWORD`). Passwords must not contain a single quote (they are written into
  `primary_conninfo`).
