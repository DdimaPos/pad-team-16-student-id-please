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
| `lib.sh` | JSON log lines in the team's format, `psql` helpers |
| `docker-compose.test.yml`, `failover-test.sh` | A throw-away cluster and the test that proves all of this |

## How it works

- **Replication.** Physical streaming replication. `<db>-1` starts as the primary; `<db>-2` and `<db>-3` clone it with
  `pg_basebackup` and follow it as hot standbys (they answer reads, refuse writes).
- **Synchronous commit.** While a standby streams, the agent sets `synchronous_standby_names = 'ANY 1 (*)'` on the
  primary: a commit returns only when one standby has it, so a failover never loses an acknowledged write. With no
  streaming standby for 10 s the agent resets it, because every write would otherwise wait forever; it turns it on
  again when a standby is back (`failover.sync_on`, `failover.sync_off`).
- **Failover.** Every 2 s the agent checks each cluster's primary. After 3 failed checks it picks the standby with the
  highest received WAL position, writes its name to the leader file, promotes it (`pg_promote()`), and re-points the
  other standby to it (`ALTER SYSTEM SET primary_conninfo`, `pg_reload_conf()`). Measured with `failover-test.sh`:
  **writes work again about 6.3 s after `docker stop` of the primary** (PostgreSQL 17 and 16), and every acknowledged
  write is on the new primary.
- **No second primary.** The agent keeps the current primary's name in a shared volume (`/ha-state/<cluster>/primary`).
  `node.sh` reads it before PostgreSQL starts: an old primary that comes back sees another leader, runs `pg_rewind`
  (or a fresh `pg_basebackup` when the rewind fails) and starts as that leader's standby, so it never takes a write.
  A primary that was paused rather than stopped (`docker pause`) and wakes up after the failover is fenced by the
  agent: `default_transaction_read_only = on` and its client sessions ended, so clients skip it; restart it to rejoin
  (`failover.fenced`).
- **Clients.** A service lists the three nodes and asks for the read-write one; the driver tries them in order and
  skips the standbys, so no proxy sits in between:
  - pgx (Go): `postgres://<user>:<pw>@<db>-1:5432,<db>-2:5432,<db>-3:5432/<name>?sslmode=disable&target_session_attrs=read-write&connect_timeout=2`
  - Npgsql (C#): `Host=<db>-1,<db>-2,<db>-3;Port=5432;Database=<name>;Username=<user>;Password=<pw>;Target Session Attributes=read-write;Timeout=3;Host Recheck Seconds=2`
  - the ETL reads with `target_session_attrs=prefer-standby`.
  While no primary answers, the service answers `500 DEPENDENCY_UNAVAILABLE` (`details.dependency` naming the
  database) and its `/status` says `degraded`; see the shared brief and decision 3.

## Converting a service's database

1. Replace the database block with three nodes from the block below (one named volume per node), and add the cluster
   to `PGHA_CLUSTERS` of `pg-failover`.
2. Change the service's connection string to the multi-host form above; point its `depends_on` at `<db>-1`.
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
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
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
./failover-test.sh            # PostgreSQL 17: replication, refused standby write, failover under load, rejoin
./failover-test.sh --pause    # also: a paused primary that wakes up after the failover is fenced
PGHA_TEST_IMAGE=postgres:16-alpine ./failover-test.sh
```

It needs Docker and `python3` on the host, uses its own compose project (`pgha-test`) and removes it at the end
(`--keep` keeps it).

## Limits

- The agent is one container: while it is down, nobody promotes a standby (the cluster keeps working as long as its
  primary does). It restarts with `restart: unless-stopped` and reads the leader files again.
- A node that comes back while the leader in the file is gone waits for the agent's next promotion before it starts.
- Passwords must not contain a single quote (they are written into `primary_conninfo`).
