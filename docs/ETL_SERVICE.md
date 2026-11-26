# ETL Service - Integration Reference

> **Status:** `5.0.1` (Lab 5, #165, decision 4 of #163; the first release was `5.0.0`). Image
> `d1vinexd/etl-service:5.0.1` and `:latest` (`linux/amd64`, `linux/arm64`), run by the team `docker-compose.yml` next
> to `warehouse-postgres`. The contract is README "Data warehouse and ETL" and "Data Management" (#184); see
> [§14](#14-divergences-from-the-contract) for what the service does beyond it.

## 1. What this service is

The thirteenth component, from Lab 5. It copies the data of every service into one data warehouse, `warehouse_db`,
so a question that spans services (which moderators decide wrongly, on which applicants, in which shifts) is one
query, with no join across services and no load on the databases that serve the game. Grafana's "Analytics"
dashboard reads the warehouse ([§13](#13-grafana-analytics)).

It owns the warehouse and the record of its own runs and of how far it has read each source table. It owns **no
business data**: every warehouse row is a copy whose owner stays the source of truth, and no service and no business
flow reads the warehouse. A stopped ETL costs only fresh analytics.

**The one exception to the data rule.** Every other component reaches a service only through its API or its events.
The ETL reads every service database **directly, read-only**, as the role `etl_reader`, from a standby, and writes
only to `warehouse_db`. Asking every owner's API for all of its rows every minute would load the primaries and the
broker with traffic no player waits for. The exception is safe because nothing is written through it and nothing
depends on it. Each owner decides what `etl_reader` may read and never grants a secret (README "Data Management").

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn, psycopg 3, PyMongo, httpx, pydantic-settings |
| **Container port** | `8075` (host `8075`) |
| **Address in the stack** | `http://etl-service:8075` inside `student-id-net`, and host port `8075` published for the demo; not a Gateway route and no broker queue |
| **Health** | `GET /health`, `GET /status` (no credential); `/status` follows the warehouse only |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential |
| **Logs** | `GET /logs` with `X-Service-Token`, the file `/var/log/etl/etl.jsonl` |
| **Credential** | `X-Service-Token` on `/api/v1/*` and `GET /logs`, checked by the ETL itself |
| **Storage** | `warehouse_db` on `warehouse-postgres` (PostgreSQL 17), the only database it writes |
| **Reads** | the six PostgreSQL and the two MongoDB service databases, as `etl_reader`, from a standby |
| **Calls out** | Service Discovery: registration as `etl` and a heartbeat every 5 s |
| **Callers** | an operator or the demo (`POST /api/v1/runs`, `GET /api/v1/runs`), Service Discovery (`/status`, `/logs`), Prometheus (`/metrics`), Grafana (the warehouse, not the service) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `d1vinexd/etl-service:5.0.1` and `:latest`, published by GitHub Actions on merge to `main` |
| **Instances** | one copy; a second one would never run at the same time (the run lock is in the warehouse) |

**Why Python.** It reuses the logging, status, logs and metrics modules of Service Discovery and the broker, and a
run waits on the databases far more than it computes, so the GIL costs nothing here.

## 3. Running it

```bash
docker run --rm --network student-id-net --name etl-service -p 8075:8075 \
  -e SERVICE_TOKEN=... -e SERVICE_DISCOVERY_URL=http://service-discovery-service:8090 \
  -e WAREHOUSE_DSN=postgresql://warehouse:...@warehouse-postgres:5432/warehouse_db \
  -e MODERATION_DB_DSN=postgresql://etl_reader:...@moderation-postgres:5432/moderation_db \
  d1vinexd/etl-service:5.0.1
curl http://localhost:8075/health
# {"status":"ok","service":"etl","version":"5.0.1"}
```

In the team stack `docker-compose.yml` sets everything from `.env`: `WAREHOUSE_PASSWORD`, `ETL_READER_PASSWORD`,
`ETL_INTERVAL_SECONDS` and `WAREHOUSE_GRAFANA_PASSWORD` (Grafana's read-only role). At startup the ETL waits up to
`WAREHOUSE_STARTUP_TIMEOUT_SECONDS` for the warehouse, applies its migrations, registers with Service Discovery and
starts the first run. Building from source and the test suite (an integration test on a throwaway PostgreSQL 17 and
MongoDB 7) are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVICE_TOKEN` | none, required | The stack's one `X-Service-Token`. The ETL does not start without it |
| `APP_PORT` | `8075` | HTTP port |
| `LOG_LEVEL` | `info` | |
| `LOG_FILE` / `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `/var/log/etl/etl.jsonl` / `50` / `5` | The log file `GET /logs` reads; empty = stdout only, and `GET /logs` answers `503 LOGS_UNAVAILABLE` |
| `INSTANCE_ID` / `INSTANCE_HOST` | `etl-<hostname>` / empty | Overrides for a run outside Docker |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout of `/api/v1` (a run is not a task: it goes on in the background) |
| `MAX_CONCURRENT_TASKS` / `RETRY_AFTER_SECONDS` | `64` / `1` | Concurrent task limit of `/api/v1` |
| `ETL_INTERVAL_SECONDS` | `60` | Time between two scheduled runs; the first run starts right after startup |
| `ETL_OVERLAP_SECONDS` | `5` | A table is read from its watermark minus this ([§6](#6-watermarks-and-increments)) |
| `ETL_PAGE_SIZE` | `1000` | Rows per source query (keyset pages) |
| `ETL_SOURCE_STATEMENT_TIMEOUT_SECONDS` / `ETL_SOURCE_CONNECT_TIMEOUT_SECONDS` | `30` / `1` | Bound every source query (`statement_timeout`, `maxTimeMS`) and every connect; the connect timeout is the contract's 1 s (README "Why a 1 s connect timeout") |
| `WAREHOUSE_DSN` | empty | `warehouse_db`, as its owner; empty = no run and `/status` `503 degraded` |
| `WAREHOUSE_CONNECT_TIMEOUT_SECONDS` / `WAREHOUSE_STARTUP_TIMEOUT_SECONDS` | `1` / `60` | At startup the migrations wait this long for the warehouse, then the ETL exits (the compose restarts it) |
| `PLAYER_DB_DSN`, `SESSION_DB_DSN`, `APPLICANT_DB_DSN`, `RULES_DB_DSN`, `UNIVERSITY_RECORD_DB_DSN`, `MODERATION_DB_DSN` | empty | The PostgreSQL sources, as `etl_reader`; empty = the source is skipped |
| `CREDENTIAL_MONGO_URI`, `DMS_MONGO_URI` | empty | The MongoDB sources, as `etl_reader`; the database is the URI's (`credential_db`, `dms_db`) |
| `SERVICE_DISCOVERY_URL` | empty | Registers as `etl`; empty = no registration (one warning at startup) |
| `SERVICE_DISCOVERY_HEARTBEAT_SECONDS` / `SERVICE_DISCOVERY_TIMEOUT_SECONDS` | `5` / `2` | |

A PostgreSQL DSN gets `target_session_attrs=prefer-standby` and a MongoDB URI `readPreference=secondaryPreferred`
when it names none. The DSN of a replicated database lists the three nodes of its cluster
(`postgresql://etl_reader:<pw>@rules-postgres-1:5432,rules-postgres-2:5432,rules-postgres-3:5432/rules_db`) and the
URI of a replica set adds `replicaSet=rs0`; a database that runs as one container is named alone and read as it is.
In the team compose Server Rules and Moderation are three-node PostgreSQL clusters, and Player, Session, Applicant,
University Record (PostgreSQL), Credential and Discord DMs (MongoDB) run one container each
([§14](#known-gap-sources-without-a-login-capable-etl_reader)). DSNs and URIs hold passwords: they are never logged, and the passwords
must be URL-safe (letters, digits, `-`, `_`, `.`, `~`).

## 5. The warehouse

`warehouse-postgres`: PostgreSQL 17, database `warehouse_db`, owner `warehouse` (`WAREHOUSE_PASSWORD`), host port
`5440`, one node and not replicated: the ETL rebuilds it from the services. The schema is created by the ETL's own
versioned migrations (`app/migrations/0001_star_schema.sql`, `0002_etl_bookkeeping.sql`), applied at startup in
order under an advisory lock and recorded in `schema_migrations`. A star schema: no foreign key between a fact and a
dimension, because a decision may be loaded before its moderator; every key is the id the owning service gives, so a
row is upserted by it whatever order the sources load in.

Every table of the star has `loaded_at`, the time the ETL last changed the row.

| Table | One row per | Natural key | Columns and the source fields they come from |
| --- | --- | --- | --- |
| `dim_date` | calendar day | `date_key` (`YYYYMMDD`) | generated for every day a fact falls on: `date`, `year`, `quarter`, `month`, `day`, `iso_week`, `day_of_week` (ISO, 1 Monday), `is_weekend` |
| `dim_player` | player | `player_id` | Player `players`: `id`, `username`, `display_name`, `xp`, `completed_shifts`, `created_at`, `updated_at` |
| `dim_applicant` | applicant | `applicant_id` | Three sources, each writing only its own columns. Applicant `applicants`: `session_id`, `difficulty`, `origin`, `initialized_by`, `is_honest`, `lie_archetype`, `claimed_university_status`, `actual_university_status`, `claimed_major`, `actual_major`, `claimed_year`, `actual_year`, `applicant_updated_at` (`updated_at`). Credential `applicants` (the document `_id` is the `applicant_id`): `documents_total`, `documents_valid`, `documents_invalid`, `documents_with_problems`, `document_statuses` (`{"valid": 2, ...}`), all counted from `documents.validation_status` and `documents.problems`, and `credential_updated_at`. University Record `applicants`: `record_university_status` (`actual_university_status`), `record_created_at`; `enrollment_records` (the newest of each `owner_applicant_id`): `enrollment_status`, `enrollment_major`, `enrollment_year`, `enrollment_admission_year`; `email_group_records`: `email_group_count`, the number per `owner_applicant_id` |
| `dim_ruleset` | ruleset version | `version` | Server Rules `rulesets`: `version`, `difficulty`, `is_active`, `created_at`, `deleted_at`, `updated_at`; `rules`: `rule_count` and `rules_by_kind` (`{"identity": 3, ...}`), counted per `ruleset_version` and `kind` |
| `fact_decision` | decision | `decision_id` | Moderation `decisions`: `decision_id`, `session_id`, `applicant_id`, `moderator_id`, `action`, `expected_action`, `is_correct`, `penalty`, `ruleset_version` (else the session's), `violated_rules_count` (the length of `violated_rules`), `decided_at`, `date_key`. Joined: `difficulty` and `session_started_at` from its session (Session `sessions`), `moderator_username` from its moderator (Player `players.username`) |
| `fact_shift` | one player's ended shift | `(session_id, player_id)` | Player `shifts`: `role`, `xp_delta`, `score`, `penalties`, `applications_processed`, `ended_at`, `date_key`; Session `session_results`: `role`, `xp_delta`. Joined from Session `sessions`: `session_status`, `difficulty`, `ruleset_version`, `moderator_id`, `session_score` (`score`), `session_started_at`, `session_ended_at`, `duration_seconds` |
| `fact_message` | channel of a session | `(session_id, channel_id)` | Discord DMs `messages`: `message_count`, `first_sent_at`, `last_sent_at`, recomputed from `channel_id`, `session_id` and `sent_at` of every message of the channel (never the text); `channels`: `channel_name` (`name`); `date_key` of the last message, else of the channel's `created_at` |
| `stg_session` | session | `session_id` | Session `sessions`: `status`, `moderator_id`, `difficulty`, `ruleset_version`, `applications_processed`, `score`, `penalties`, `created_at`, `started_at`, `ended_at`. Staging, not part of the star ([§14](#14-divergences-from-the-contract)) |
| `etl_watermark` | source table | `(source, table_name)` | `column_name`, `watermark`, `updated_at`: how far each source table has been read ([§6](#6-watermarks-and-increments)) |
| `etl_run` | run | `run_id` | the runs `GET /api/v1/runs` lists ([§7](#7-http-api)) |

`source` everywhere (`etl_watermark.source`, a run's `failed_sources`, the metric labels) is the service's Gateway
prefix: `player`, `session`, `applicant`, `credential`, `server-rules`, `university-record`, `moderation`,
`discord-dms`.

**Joins.** A decision and a shift take their session side from `stg_session` when they are loaded; a session loaded
or changed later completes the facts already loaded for it, so the order in which the sources load does not matter.
Accuracy per moderator is `avg(is_correct::int)` of `fact_decision` by `moderator_id`.

## 6. Watermarks and increments

| Source | Table or collection | Watermark (best first) |
| --- | --- | --- |
| Player | `players` | `updated_at`, else `created_at` |
| Player | `shifts` | `created_at` |
| Session | `sessions` | `updated_at` where the schema has it, else `GREATEST(created_at, started_at, ended_at)` (Session `4.0.0` has no `updated_at`) |
| Session | `session_results` | `created_at` |
| Applicant | `applicants` | `updated_at`, else `created_at` |
| Credential | `applicants` | `updated_at`, else `created_at` |
| Server Rules | `rulesets` | `updated_at` (Server Rules `5.0.0`); a database without it (before `5.0.0`) is read whole (a handful of rows) |
| Server Rules | `rules` | `id` |
| University Record | `applicants`, `enrollment_records`, `email_group_records` | `created_at` |
| Moderation | `decisions` | `decided_at` |
| Discord DMs | `messages` | `sent_at` |
| Discord DMs | `channels` | `created_at` |

- The first candidate whose columns all exist and are readable is used; a fallback is logged as
  `etl.watermark_fallback`. `etl_watermark.column_name` records which one; when it changes (a service added
  `updated_at`), that table is read again from the beginning (`etl.watermark_reset`), which the upsert absorbs.
- Several services set `created_at` and `updated_at` from their own clock, to the second, before the transaction
  commits, so the timestamps are not commit-ordered: a table is read from `>= watermark - ETL_OVERLAP_SECONDS`, and the
  upsert by natural key absorbs the overlap.
- Every query reads one keyset page of `ETL_PAGE_SIZE` rows, so a hot standby never cancels a long query.
- A source's rows and its new watermarks are written in one warehouse transaction: a watermark never runs ahead of the
  rows it covers.
- `fact_message` recomputes the count of every channel a new message or a new channel touched, never a delta, so a
  re-read never counts a message twice.
- A row read again that did not change is not written and not counted: a run with no new source rows loads nothing.

**What is never read.** Only the columns the warehouse needs, and of those only the ones that exist and `etl_reader`
may read (`information_schema.columns`); MongoDB by projection. Never: `email`, `password_hash` (Player);
`claimed_email`, `actual_email`, `university_emails` (Applicant); the emails, the document `fields` and
`email_reservations` (Credential); `raw_event_json`, `email_group_records.email`, `fcim_log_records` (University
Record); `snapshot` and `bans` (Moderation); message `content` and `ws_tickets` (Discord DMs). The service tests check
the list.

## 7. HTTP API

### `GET /health`

`200 {"status": "ok", "service": "etl", "version": "5.0.1"}`, no credential.

### `GET /status`

The shape of README "Status endpoint", no credential, outside the concurrent task limit:

```json
{ "service": "etl", "instance_id": "etl-3f2a1b9c", "version": "5.0.1", "status": "up", "in_flight": 0, "max_concurrent_tasks": 64 }
```

`200 up` while the warehouse answers, whatever the sources do; `503 degraded` when the warehouse does not answer or
`WAREHOUSE_DSN` is empty. A source that is down only fails its part of a run: a non-`200` would make Service Discovery
list the ETL `down` and Prometheus stop scraping it.

### `GET /metrics`

The Prometheus text format, no credential ([§10](#10-metrics)).

### `GET /logs?since=&until=&level=`

This instance's log lines in the window, oldest first, as `application/x-ndjson`, with `X-Service-Token` (README
"Logs download"). `400 VALIDATION_ERROR` for a malformed window, `503 LOGS_UNAVAILABLE` without a log file.

### `POST /api/v1/runs` - start a run now

`X-Service-Token`; no body. Answers at once; the run goes on in the background.

`202 Accepted`:

```json
{ "run_id": "0b6f7c3e-2a1d-4c5b-9e8f-7a6b5c4d3e2f" }
```

`409 RUN_IN_PROGRESS` while a run (scheduled or manual, in any copy) holds the run lock, with the running run's id:

```json
{ "error": { "code": "RUN_IN_PROGRESS", "message": "A run is in progress; try again when it has ended.", "details": { "run_id": "0b6f7c3e-2a1d-4c5b-9e8f-7a6b5c4d3e2f" } } }
```

`500 DEPENDENCY_UNAVAILABLE` with `details.dependency: "postgres"` (the engine, as the contract names a database) when the warehouse does not answer.

### `GET /api/v1/runs?limit=&offset=` - the runs

`X-Service-Token`. Newest first; `limit` 1 to 100 (default 20), `offset` from 0. `200 OK`:

```json
{
  "items": [
    {
      "run_id": "0b6f7c3e-2a1d-4c5b-9e8f-7a6b5c4d3e2f",
      "trigger": "schedule",
      "status": "partial",
      "started_at": "2026-11-27T12:00:00Z",
      "ended_at": "2026-11-27T12:00:02Z",
      "duration_ms": 2140,
      "rows": { "dim_applicant": 12, "fact_decision": 9, "fact_shift": 1 },
      "failed_sources": [ { "source": "credential", "error": "no member of the replica set answered" } ]
    }
  ],
  "total": 12
}
```

- `trigger`: `schedule` or `manual`.
- `status`: `running`, `succeeded`, `partial` (some sources failed, the others loaded) or `failed` (every
  configured source failed).
- `ended_at` and `duration_ms` are `null` while the run is `running`.
- `rows`: the rows inserted or changed per warehouse table; a table with none is left out, so a run with no new
  source rows has `{}`.
- `failed_sources`: one entry per source that could not be loaded, with the error's class and message (never a DSN).
- `400 VALIDATION_ERROR` for a `limit` or `offset` out of range; `500 DEPENDENCY_UNAVAILABLE` (`postgres`) as above.

## 8. Errors and limits

| Situation | Answer |
| --- | --- |
| No `X-Service-Token` on `/api/v1/*` or `GET /logs` | `403 SERVICE_TOKEN_REQUIRED` |
| Wrong `X-Service-Token` | `401 INVALID_SERVICE_TOKEN` |
| `limit`, `offset` or the logs window malformed | `400 VALIDATION_ERROR` with `details.errors` |
| `POST /api/v1/runs` while a run holds the lock | `409 RUN_IN_PROGRESS` with `details.run_id` |
| The warehouse does not answer (run routes) | `500 DEPENDENCY_UNAVAILABLE`, `details.dependency: "postgres"` |
| `GET /logs` without a log file | `503 LOGS_UNAVAILABLE` |
| Unknown route, wrong method | `404 NOT_FOUND`, `405 METHOD_NOT_ALLOWED` |
| Concurrent task limit of `/api/v1` reached | `429 TOO_MANY_REQUESTS` + `Retry-After` |
| `/api/v1` request longer than `HTTP_REQUEST_TIMEOUT` | `408 REQUEST_TIMEOUT` |
| Anything else | `500 INTERNAL_ERROR`, logged at `error` |

The routes are called inside `student-id-net`, not through the Gateway (README "Authentication", rule 4).

## 9. Failure behaviour

- **Never two runs at once.** A run takes `pg_try_advisory_lock` in `warehouse_db`: a scheduled tick that finds a run
  in progress is skipped (`etl.tick_skipped`), and `POST /api/v1/runs` answers `409`.
- **A source down** (refused, timed out, no standby and no primary, `etl_reader` missing or without a grant): its
  transaction is rolled back, it is named in the run's `failed_sources` and in `etl_source_failures_total`, its
  watermarks stay where they were, and the next run reads it again. The other sources still load; the run is
  `partial`. A source with no DSN or URI is not read at all.
- **The warehouse down:** no run starts, `/status` answers `503 degraded`, the run routes answer
  `500 DEPENDENCY_UNAVAILABLE`. At startup the ETL waits `WAREHOUSE_STARTUP_TIMEOUT_SECONDS` for it, then exits and the
  compose restarts it.
- **The process dies during a run:** the advisory lock goes with its connection; the run stays `running` in `etl_run`
  until the next run marks it `aborted` ([§14](#14-divergences-from-the-contract)).
- **Service Discovery down:** the heartbeat fails (`sd.heartbeat_failed`) and the runs go on.
- **Never a write to a source:** PostgreSQL sessions are `default_transaction_read_only`, and `etl_reader` has no
  write right anyway.

## 10. Metrics

The shared series of README "Monitoring" (`http_requests_total`, `http_request_duration_seconds`, `tasks_in_flight`,
`breaker_state`), and the ETL's own:

| Series | What |
| --- | --- |
| `etl_rows_loaded_total{table}` | Rows inserted or changed per warehouse table |
| `etl_run_duration_seconds` (histogram) | Duration of a finished run |
| `etl_source_failures_total{source}` | Runs in which a source could not be loaded |
| `etl_runs_total{status}` | Finished runs by status |
| `etl_last_run_timestamp_seconds` | Unix time the last run of this instance ended |

Every `table` and `source` series exists from the start at `0`, so a `rate()` sees it before its first row or failure.
Prometheus finds the ETL through Service Discovery, like every registered instance.

## 11. Logs

One JSON object per line on stdout and in `LOG_FILE`, the shared format of README "Logging", `service` `etl`. The
ETL's events:

| `event` | Level | Fields |
| --- | --- | --- |
| `etl.run_started` / `etl.run_finished` | `info` | `run_id`, `trigger`; at the end `status`, `rows`, `failed_sources`, `duration_ms` |
| `etl.source_loaded` / `etl.source_failed` | `info` / `warn` | `run_id`, `source`, the rows per table or the `error` |
| `etl.tick_skipped` / `etl.tick_failed` | `info` / `warn` or `error` | a scheduled tick that found a run in progress, or could not start one |
| `etl.run_unrecorded` | `warn` | the run ended but its row could not be written |
| `etl.watermark_fallback` / `etl.watermark_reset` | `info` | `source`, `table`, `column` |
| `etl.rows_skipped` | `warn` | `source`, `table`, `column`, `count`: MongoDB documents without a UUID key, never their content |
| `warehouse.waiting` / `warehouse.migrated` / `warehouse.disabled` | `warn` / `info` / `warn` | startup |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` / `sd.disabled` | `info` / `warn` / `info` / `warn` | registration |
| `http.request` / `http.error` / `logs.file_unavailable` | as every component | |

No DSN, URI, password or source row is ever logged.

## 12. Service Discovery

Registers as `etl` (README "Service Discovery"), with the empty topics
`{ "publishes": [], "subscribes": [] }` - it uses no queue and no topic of the broker - and heartbeats every 5 s.
Service Discovery polls its `GET /status` and fetches its `GET /logs` for the whole system's logs download; Prometheus
reads it from `GET /api/v1/instances/prometheus`.

## 13. Grafana "Analytics"

`monitoring/grafana/dashboards/analytics.json` (uid `student-id-analytics`, folder "Student ID, please") reads
`warehouse_db` through the provisioned datasource "Warehouse" (uid `warehouse`, type
`grafana-postgresql-datasource`) as `grafana_reader`: a role created by
`deployments/warehouse/init-grafana-reader.sh` on an empty warehouse volume, with `SELECT` on every table `warehouse`
creates and every session read-only; its password is `WAREHOUSE_GRAFANA_PASSWORD`. On an existing volume, run the SQL
of that script by hand once. Panels (time range `now-30d`):

- decisions per day, correct and wrong (`fact_decision.decided_at`, `is_correct`);
- accuracy per moderator (`avg(is_correct)` by moderator, with the decisions and penalties);
- applicants by status and difficulty (`dim_applicant`);
- messages per session, the top 20 (`fact_message`);
- the average shift score, the shifts ended, the overall decision accuracy and the end of the last run that loaded;
- the average shift score per day and difficulty (`fact_shift`);
- the last 20 runs (`etl_run`), with the rows per table and the failed sources.

After a shift and one run (`POST /api/v1/runs`) the dashboard shows the shift.

## 14. Divergences from the contract

Beyond README "Data warehouse and ETL", none of which changes what a caller of the contract sees:

- **`stg_session`**, a staging table not in the contract's star: the session side that `fact_decision` and
  `fact_shift` are joined with, so a fact loaded before its session is completed when the session arrives.
- **Extra bookkeeping:** `schema_migrations` (the applied migrations), `etl_watermark.column_name` (which column the
  watermark is a value of), and `etl_run.skipped_sources` and `instance_id`.
- **`status: aborted`**, beyond the four of the contract: a run left `running` by a process that died is marked
  `aborted` by the next run.
- **`500 DEPENDENCY_UNAVAILABLE`** (`details.dependency: "postgres"`) on the run routes when the warehouse does not answer, the shared
  code of README "Errors".

### Known gap: sources without a login-capable `etl_reader`

In the team `docker-compose.yml`, a source whose database has no `etl_reader` that may log in fails every run and is
named in the run's `failed_sources`; the other sources still load. A database gets a login-capable `etl_reader` from
the replication pattern's init script (`deployments/postgres-ha/initdb.sh`, `deployments/mongo-rs/init.sh`), and its
service's migrations grant it what the ETL reads. In this compose that holds for Server Rules `5.0.1`,
University Record `5.0.1`, Moderation `5.0.0`, Applicant `5.0.0` and Player `5.0.0` (three-node PostgreSQL clusters) and for Credential
`5.0.0` and Discord DMs `5.0.0` (three-member MongoDB replica sets). The sources that fail are:

| Source | Image in the compose | Database | Why |
| --- | --- | --- | --- |
| `session` | Session `5.0.1` | `session-postgres`, one container | no login-capable `etl_reader` on a container without the replication pattern |

The ETL loads each of them in the first run after its database runs the replication pattern and its DSN or URI in the
compose lists the three nodes.

## 15. Postman

`postman/etl-service.postman_collection.json`: `GET /health`, `GET /status`, `GET /metrics`, `POST /api/v1/runs`
(`202`, then `409 RUN_IN_PROGRESS` right after it, `403` without the token, `401` with a wrong one) and
`GET /api/v1/runs` (the shape, paging, `400` out of range, the token errors). `etl_url` (default
`http://localhost:8075`) and `service_token` (the placeholder of `.env.example`) are collection variables.
