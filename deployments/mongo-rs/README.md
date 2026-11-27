# MongoDB replica sets (#164)

Every MongoDB database of the services (Credential, Discord DMs) runs as a replica set `rs0` of three members, with
MongoDB's own election as the failover (contract decision 3 of #163, README "Database replication"). Everything runs
on the official `mongo:7` image; this folder is bind-mounted read-only into the containers.

| File | What it is |
| --- | --- |
| `node.sh` | Entrypoint of every member: writes the shared key file with the owner and mode mongod accepts, then starts `mongod --replSet rs0 --keyFile ...` |
| `init.sh` | One-shot init: `rs.initiate` once (election timeout 5 s), waits for a primary, creates or updates `etl_reader` |
| `docker-compose.test.yml`, `failover-test.sh` | A throw-away replica set and the test that proves all of this |

## How it works

- **Members.** Only the first member gets the root user (`MONGO_INITDB_ROOT_*`); the other two start empty and receive
  the users by initial sync. A member that already has data cannot join a new set ("has data already").
- **Key file.** With authentication on, the members authenticate to each other with a shared key file that mongod
  accepts only when the `mongodb` user owns it with mode 400. A bind-mounted file keeps the host's owner, so the key
  comes from `MONGO_REPLICA_KEY` (6 to 1024 base64 characters, the same for every member; generate one with
  `openssl rand -base64 48`) and `node.sh` writes it.
- **Failover.** MongoDB elects a new primary when the old one stops; `electionTimeoutMillis` is 5000. Measured with
  `failover-test.sh`: **writes work again about 1.6 s after `docker stop` of the primary** (it steps down cleanly; a
  crashed primary takes about the election timeout), every acknowledged write is on the new primary, and the old
  primary rejoins as a secondary by itself.
- **Clients.** A service lists the members and names the set; the driver finds the primary and retries a write once
  across an election (`retryWrites` is on by default):
  `mongodb://<user>:<pw>@<db>-1:27017,<db>-2:27017,<db>-3:27017/<name>?authSource=admin&replicaSet=rs0&retryWrites=true`.
  The ETL adds `readPreference=secondaryPreferred`. A tool on the host reaching one published member needs
  `directConnection=true` (the set's member names resolve only inside `student-id-net`).

## Converting a service's database

1. Replace the database block with three members and the init container below; one named volume per member.
2. Change the service's `MONGODB_URI` to the replica set form above, and make it wait for the init container
   (`depends_on: <db>-init: { condition: service_completed_successfully }`). Give its block
   `dns_opt: ["timeout:1", "attempts:1"]`, so the lookup of a stopped member fails at once on Docker Desktop for
   Windows (see "1 s timeouts and `dns_opt`" in `deployments/postgres-ha/README.md`).
3. Start with **new volumes**: the first member's root user and the set are created only on empty data directories.

```yaml
x-dms-mongo-member: &dms_mongo_member
  image: mongo:7
  restart: unless-stopped
  entrypoint: ["bash", "/rs/node.sh"]
  networks: [student-id-net]
  healthcheck:
    test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
    interval: 5s
    timeout: 5s
    retries: 20

services:
  dms-mongo-1:
    <<: *dms_mongo_member
    environment:
      MONGO_REPLICA_KEY: ${MONGO_REPLICA_KEY:?set MONGO_REPLICA_KEY in .env}
      MONGO_INITDB_ROOT_USERNAME: ${DMS_MONGO_USER:-dms_user}
      MONGO_INITDB_ROOT_PASSWORD: ${DMS_MONGO_PASSWORD:?set DMS_MONGO_PASSWORD in .env}
    ports: ["27019:27017"]          # optional, debugging only (directConnection=true)
    volumes: [dms_mongodata_1:/data/db, "./deployments/mongo-rs:/rs:ro"]
  dms-mongo-2:                      # MONGO_REPLICA_KEY only, volume dms_mongodata_2, no ports
  dms-mongo-3:                      # MONGO_REPLICA_KEY only, volume dms_mongodata_3, no ports

  dms-mongo-init:
    image: mongo:7
    restart: "no"
    entrypoint: ["bash", "/rs/init.sh"]
    networks: [student-id-net]
    environment:
      MONGO_RS_MEMBERS: "dms-mongo-1 dms-mongo-2 dms-mongo-3"
      MONGO_ROOT_USER: ${DMS_MONGO_USER:-dms_user}
      MONGO_ROOT_PASSWORD: ${DMS_MONGO_PASSWORD:?set DMS_MONGO_PASSWORD in .env}
      MONGO_APP_DB: dms_db
      ETL_READER_PASSWORD: ${ETL_READER_PASSWORD:?set ETL_READER_PASSWORD in .env}
    volumes: ["./deployments/mongo-rs:/rs:ro"]
    depends_on:
      dms-mongo-1: { condition: service_healthy }
      dms-mongo-2: { condition: service_healthy }
      dms-mongo-3: { condition: service_healthy }
```

## Test

```bash
./failover-test.sh          # replication, refused secondary write, failover under load, rejoin, etl_reader
```

It needs Docker and `python3` on the host, uses its own compose project (`mongors-test`) and removes it at the end
(`--keep` keeps it).
