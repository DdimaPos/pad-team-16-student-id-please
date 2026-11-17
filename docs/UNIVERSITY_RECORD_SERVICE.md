# University Record Service - Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway. Describes `5.0.0` (Lab 5, #176): the step `grant-scopes` of the saga
> `shift.start` and its compensation, the replicated database with failover, the grants and watermarks for the ETL,
> and `session.started` retired - see [§13](#13-lab-5-saga-step-replicated-database-etl-grants). Everything of Lab 4
> stays: events and requests go through the Message Broker, as the CPR contract describes since #105; `4.0.1` (#151)
> added the `X-Service-Token` check of `/admin/*` and `/dev/*`. Where the implementation diverges from the CPR
> contract, the divergence is called out explicitly in [§8](#8-divergences-from-the-cpr-contract) and, for Lab 5
> (#184), in [§13](#13-lab-5-saga-step-replicated-database-etl-grants).

---

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Running it](#3-running-it)
4. [Configuration](#4-configuration)
5. [HTTP API](#5-http-api)
6. [Events](#6-events)
7. [The identity model - shared with Applicant/Credential](#7-the-identity-model---shared-with-applicantcredential)
8. [Divergences from the CPR contract](#8-divergences-from-the-cpr-contract)
9. [Edge cases](#9-edge-cases)
10. [Gateway requirements](#10-gateway-requirements)
11. [Mocking strategy (grade 9) and testing recipes](#11-mocking-strategy-grade-9-and-testing-recipes)
12. [Message Broker, logs and metrics (Lab 4)](#12-message-broker-logs-and-metrics-lab-4)
13. [Lab 5: saga step, replicated database, ETL grants](#13-lab-5-saga-step-replicated-database-etl-grants)

---

## 1. What this service is

University Record Service owns the hidden institutional records - enrollment, email/Outlook
groups, courses, FCIM logs - that a Junior Moderator searches to catch a liar. It learns
the applicants from `applicant.initialized` and the end of a shift from `session.ended`, delivered by the
Message Broker from `4.0.0`, and, from `5.0.0`, the juniors' record scopes from the saga step `grant-scopes`
(a request from the broker's saga coordinator; `session.started` is retired); the only call it makes is
publishing its own `applicant.initialized` to the broker.

### Boundary

- **Owns:** enrollment records, email-group records, the course catalog + registrations,
  FCIM logs, session scopes, and from `5.0.0` its saga step records (`saga_steps`).
- **Does not own:** the applicant's claimed identity (Applicant Service), documents
  (Credential Service), the admission decision (Moderation Service).
- **Calls:** no other service. From `4.0.0` it publishes its own `applicant.initialized` once to the
  broker topic `events.applicant.initialized`, which reaches Applicant and Credential Service; besides
  that, only the registration with Service Discovery. Learns about applicants and the end of sessions from
  events, and about the start of a shift from the saga step `grant-scopes` (`5.0.0`).
- **Is called by:** Moderation Service (`GET /applicants/{id}/records` - full cross-category
  access as a service call), the game client (`GET /records/{category}` - scoped per player), and from
  `5.0.0` the broker's saga coordinator (`POST /saga-steps/grant-scopes[/compensate]`, [§13](#13-lab-5-saga-step-replicated-database-etl-grants)). From
  `4.0.0` these requests arrive from the broker's queue `requests.university-record` - see
  [§12](#12-message-broker-logs-and-metrics-lab-4).

**Key design decision - records are per-applicant only.** There is no synthetic "background
population" of the university. Enrollment/email-group/FCIM rows exist only for applicants
this service has actually heard about via an event (or its own generator). The **course
catalog** is the one exception: it is seeded reference data (the CPR's
[`shared/courses.json`](../shared/courses.json), byte-identical in every service that ships it),
because `exists: true/false` for a claimed course cannot work
otherwise - an honest course must exist before anyone claims it.

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | C# / .NET 10, ASP.NET Core minimal APIs |
| **Container port** | `8080` (mapped to host `8084` by convention) |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/university-record/...`. From `4.0.0` a request may also arrive from the broker's queue `requests.university-record`, served through the same REST listener (§12) |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres, and `pending_events` / `parked_events` of the outbox), `GET /status` for Service Discovery |
| **Database** | PostgreSQL, `university_record_db`. From `5.0.0` it may be the replicated cluster of the CPR README "Database replication" (`university-record-postgres-1` primary, `-2` and `-3` standbys), reached with a multi-host Npgsql connection string; one host still works for a local run (§13). Until the compose converts it (final Lab 5 delivery), the team stack runs one container, `university-record-postgres`, host port `5435` |
| **Message Broker** | One gRPC `Subscribe` stream per instance to `MESSAGE_BROKER_URL` as service `university-record`: topics `events.applicant.initialized`, `events.session.ended` (`events.session.started` until `4.0.1`, retired in `5.0.0`) and the queue `requests.university-record` (`4.0.0`; the saga steps of `5.0.0` arrive on it too) - see [§12](#12-message-broker-logs-and-metrics-lab-4) |
| **Saga** | `5.0.0`: participant of `shift.start`, step 2 `grant-scopes` and its compensation, idempotent by `(saga_id, step)` - see [§13](#13-lab-5-saga-step-replicated-database-etl-grants) |
| **Events** | Received from the broker topics, settled with `Ack` `OK` / `PERMANENT` / `RETRY`; produced through an outbox relay, one gRPC `Publish` per event to `events.applicant.initialized` (see §6). `POST /api/v1/events` is removed in `4.0.0` |
| **Circuit breaker** | One, on the broker (`target: message-broker`), in the outbox relay (§12) |
| **Logs** | JSON lines on stdout, and the same lines in the rotating `LOG_FILE`, read back by `GET /logs` (`4.0.0`) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (`4.0.0`) |
| **Authentication** | On the contract routes, checked by the Gateway (a player's JWT) and the broker (the service token, as gRPC metadata), not here: a player's request arrives with `X-Player-Id`, a service's without it, and the route tells which is expected (§10). The routes called directly, never through the broker or the Gateway, check `X-Service-Token` themselves (CPR README "Authentication" > "Through the Message Broker", rule 4): `GET /logs` (`4.0.0`) and, from `4.0.1` (#151), `/admin/*` and `/dev/*`: `403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN` when wrong, compared in constant time; an instance without a `SERVICE_TOKEN` accepts none. `/admin/*` and `/dev/*` refuse a request with `X-Player-Id` first (`403`), even with the right token |
| **Docker image** | `d1vinexd/university-record-service:4.0.1` (also `:latest`), public on Docker Hub, `linux/amd64` and `linux/arm64`. `4.0.1` (#151) changes only the token check of `/admin/*` and `/dev/*`; events, the broker, the contract routes, `/logs` and `/metrics` are those of `4.0.0`. `5.0.0` (#176) is merged in the service's `dev` and not yet published: its image and tag come with the release to `main`, and the team compose keeps `4.0.1` until then |
| **Architecture** | Clean Architecture, five projects: `Domain` (pure - identity helpers, record generation, search semantics, the access-decision table), `Repositories` (interfaces + event DTOs), `Services` (use cases + event handlers), `Infrastructure` (EF Core, the gRPC broker client and outbox relay; `Protos/broker.proto`), `Api` (endpoints, the broker subscription and request dispatch, logs and metrics) |

---

## 3. Running it

### From the published image (recommended for teammates)

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name university-record-service --network student-id-net \
  -p 8084:8080 \
  -e ConnectionStrings__UniversityRecordDb="Host=<postgres-host>;Port=5432;Database=university_record_db;Username=university_record_user;Password=<password>" \
  -e REFERENCE_YEAR=2026 \
  -e SERVICE_TOKEN="<shared-secret>" \
  -e MESSAGE_BROKER_URL=message-broker-service:8071 \
  -e Dev__EnableTestEndpoints=true \
  d1vinexd/university-record-service:4.0.1
```

Or use the team compose in the CPR root. Events arrive from the Message Broker (§6, §12). Without a
broker (`MESSAGE_BROKER_URL` empty) the service starts, answers its REST port, receives no request and
no event through the broker, and keeps its own events in the outbox.

### From source (development)

```bash
cd university-record-service
cp .env.example .env
docker compose up -d
```

On startup: EF Core migrations apply, then the course catalog (`courses.json`) is
upserted by course code (idempotent - safe to re-run, never wipes registrations). The
catalog's SHA-256 is logged at startup so a divergence from the CPR's `shared/courses.json`
is a one-glance diff.

---

## 4. Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `ConnectionStrings__UniversityRecordDb` | - | **yes** | Npgsql connection string. One host for a local run (`Host=postgres;Port=5432;...`); from `5.0.0`, on the replicated database, the three hosts with `Target Session Attributes=read-write;Timeout=3;Host Recheck Seconds=2` (§13). The pool cap of 20 applies unless the string sets `Maximum Pool Size` |
| `REFERENCE_YEAR` | `2026` | no | Must be identical across Applicant, Credential, University Record and Moderation, or perfectly honest applicants read as liars |
| `SERVICE_TOKEN` | - | **yes** in the stack | The stack's one secret: the gRPC metadata `x-service-token` of every broker call, `X-Service-Token` to Service Discovery, and the token `GET /logs` (`4.0.0`), `/admin/*` and `/dev/*` (`4.0.1`) check; without it they accept no token. Never sent as a header of a request through the broker. `Auth__ServiceToken` is read as a fallback |
| `MESSAGE_BROKER_URL` | empty | **yes** in the stack | The broker's gRPC target without a scheme (team stack: `message-broker-service:8071`). Empty = `broker.disabled` at startup: nothing arrives through the broker and the own events wait in the outbox (`4.0.0`) |
| `HTTP_REQUEST_TIMEOUT` | `5` | no | Task timeout in seconds (`5` or `5s`): a longer request is cancelled, its transaction rolled back, and answered `408 REQUEST_TIMEOUT`. `/health*`, `/status`, `/logs` and `/metrics` are exempt |
| `MAX_CONCURRENT_TASKS` | `100` | no | Concurrent task limit: one more request, the broker's included, is refused at once with `429 TOO_MANY_REQUESTS` and `Retry-After: 1`. Also the `max_concurrent_tasks` of the broker subscription. `/health*`, `/status`, `/logs` and `/metrics` are exempt. The team compose sets `64` |
| `Dev__EnableTestEndpoints` | `false` | no | Mounts `GET /api/v1/dev/slow?ms=` (service-only, direct calls with `X-Service-Token` from `4.0.1`, sleeps `ms` milliseconds, at most a minute) to demonstrate the two limits above. **Enable for the team demo**, leave `false` in any shared/production deployment |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn` or `error`. One JSON object per line on stdout |
| `LOG_FILE` | `/var/log/university-record/university-record.jsonl` | no | The same log lines in a file, read back by `GET /logs`; the image creates the directory for its non-root user. Empty = stdout only, `GET /logs` answers `503 LOGS_UNAVAILABLE` (`4.0.0`) |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | no | The file rotates at this size; this many rotated files are kept next to the current one (`4.0.0`) |
| `SERVICE_DISCOVERY_URL` | empty | no | Base URL of Service Discovery. Empty turns registration off |
| `INSTANCE_ID` | `university-record-<hostname>` | no | Name of this instance in logs, `/status`, Service Discovery, the broker subscription and the outbox claims |
| `INSTANCE_HOST` | unset | no | Address Service Discovery polls and Prometheus scrapes (the Gateway routed to it in Lab 3), sent as `host` only when set (a run outside Docker) |
| `EVENT_PUSH_TIMEOUT` | `5` | no | Seconds one `Publish` to the broker may take (its gRPC deadline); the lease on a claimed outbox row is twice this plus 5 s |

`APPLICANT_URL` and `CREDENTIAL_URL` are removed in `4.0.0`: the broker fans the events out.

---

## 5. HTTP API

### 5.1 Contract endpoints

| Method | Path | Consumed by | Auth |
| --- | --- | --- | --- |
| `GET` | `/api/v1/records/{category}?session_id=&q=&limit=&offset=` | Game client | Player JWT at the Gateway; scope-checked here against `X-Player-Id` |
| `GET` | `/api/v1/applicants/{applicant_id}/records` | Moderation Service | A service call through the broker, which checks the token; arrives without `X-Player-Id`, no scope check. Not a route of the Gateway's `4.0.0` (§10) |
| `POST` | `/api/v1/applicants/next` | (no service calls it yet) | A service call through the broker, which checks the token. Not a route of the Gateway's `4.0.0` (§10) |
| `POST` | `/api/v1/saga-steps/grant-scopes` | Message Broker (saga coordinator of `shift.start`) | `5.0.0`. A service call through the broker: refused with `X-Player-Id` (`403 SERVICE_TOKEN_REQUIRED`), no token check here, not a Gateway route - see [§13](#13-lab-5-saga-step-replicated-database-etl-grants) |
| `POST` | `/api/v1/saga-steps/grant-scopes/compensate` | Message Broker (saga coordinator of `shift.start`) | `5.0.0`. As the step above |

From `4.0.0` a service's call arrives through the broker (the broker checks the token) instead of the
Gateway, and still without `X-Player-Id`. The Gateway's `4.0.0` (#110), which the compose runs since #113, answers
`404` on the two service-only routes above. `POST /api/v1/events` is removed in `4.0.0`: events arrive from the broker only (§6).

Also outside the versioned base path, called directly on the REST port, never through the Gateway or the broker:

| Method | Path | Called by | Notes |
| --- | --- | --- | --- |
| `GET` | `/health`, `/health/ready`, `/status` | probes, Service Discovery | No credential |
| `GET` | `/logs?since=&until=&level=` | Service Discovery (the logs aggregate), a developer | `4.0.0`. This instance's log lines, `X-Service-Token` checked by the service - see [§12](#12-message-broker-logs-and-metrics-lab-4) |
| `GET` | `/metrics` | Prometheus | `4.0.0`. No credential - see [§12](#12-message-broker-logs-and-metrics-lab-4) |

None counts against the concurrent task limit or the task timeout.

`{category}` is one of `enrollment`, `email-groups`, `courses`, `fcim-logs` (kebab-case in
the path). The cross-category response at `/applicants/{id}/records` uses the different
snake_case keys `email_groups`/`fcim_logs` for the same categories - **this is intentional
per the contract**, not a bug; see §8 for the resolved `courses` shape contradiction.

Courses are identified by `code` (`^[A-Z]{2,4}$`) in both responses, and `q` on the `courses`
category matches it.

**Error precedence for `GET /records/{category}`** (in order - see the service's own README
for the full table): `400` (missing/malformed `session_id`, `q`, `limit`, `offset`) =>
`422 UNKNOWN_CATEGORY` (checked before auth - the four values are public) =>
`401 UNAUTHENTICATED` (no valid `X-Player-Id`: this route is for a calling player, a service reads records through `/applicants/{id}/records`) => `403 SESSION_ENDED` (beats
"not a member") => `403 CATEGORY_NOT_ASSIGNED` (covers unknown session, the Moderator, a
non-member, and the wrong category - the contract folds all of these into one code).

### 5.2 Extension endpoints (beyond contract)

All under `/api/v1/admin/*` and `/api/v1/dev/*`, for services only, called directly on the REST port inside `student-id-net` with `X-Service-Token` (from `4.0.1`, #151): `403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN` when wrong. Through the broker they cannot be reached, since no request there carries the token, and the Gateway's `4.0.0` answers `404` on them. A request that carries `X-Player-Id` is refused (`403 SERVICE_TOKEN_REQUIRED`), even with the right token. `/admin/courses` is
full CRUD over the seeded catalog; `/admin/applicants` **reveals `actual`** (the answer key -
service calls only, never route to a player); `/admin/sessions/{id}/scopes` doubles as a
manual mock of Server Moderation Session Service. `/dev/slow` is covered in §11.

### 5.3 Error codes

`VALIDATION_ERROR` (400; on the saga step routes with `details.field`), `UNKNOWN_CATEGORY` / `INVALID_RULESET`-equivalents (422),
`APPLICANT_NOT_FOUND` / `NOT_FOUND` (404), `SAGA_STEP_COMPENSATED` / `SESSION_ENDED` (409, the saga step `grant-scopes`
after its compensation / for a session that has already ended here, `5.0.0`), `SESSION_ENDED` / `CATEGORY_NOT_ASSIGNED` /
`SERVICE_TOKEN_REQUIRED` (403, a service-only route called with `X-Player-Id`, or from `4.0.1` `/admin/*` and
`/dev/*` without `X-Service-Token`), `INVALID_SERVICE_TOKEN` (401, `/admin/*` and `/dev/*` with a wrong
`X-Service-Token`, `4.0.1`), `COURSE_HAS_REGISTRATIONS`
(409), `UNAUTHENTICATED` (401, no valid `X-Player-Id` on a player route), `REQUEST_TIMEOUT` (408),
`TOO_MANY_REQUESTS` (429, with `Retry-After`), `DEPENDENCY_UNAVAILABLE` (500, `details.dependency: "postgres"`, while
no database primary answers, `5.0.0`; nothing was changed), `INTERNAL_ERROR` (500). Before the service is called, the
Gateway's `4.0.0` (#110) answers `401 UNAUTHENTICATED` for a missing or invalid player JWT on the player route
`GET /records/{category}`, and `404 NOT_FOUND` on every other path of this prefix but the public `GET /health`,
before any credential is checked; its only `403` (`SERVICE_TOKEN_REQUIRED`) is on its own `GET /logs`.

`GET /logs` (`4.0.0`): `SERVICE_TOKEN_REQUIRED` (403, no `X-Service-Token`), `INVALID_SERVICE_TOKEN`
(401, a wrong one), `VALIDATION_ERROR` (400, a malformed window), `LOGS_UNAVAILABLE` (503, no log file).
`INVALID_EVENT` (422) is gone with `POST /api/v1/events` in `4.0.0`; its cases are now the `PERMANENT`
ack of §6.

---

## 6. Events

From `4.0.0` every event goes through the Message Broker (Lab 4); `POST /api/v1/events` is removed.
Every instance subscribes to the topics `events.applicant.initialized` and `events.session.ended`
(`events.session.started` too until `4.0.1`; retired in `5.0.0`, the scopes arrive with the saga step
`grant-scopes`, §13) (the broker's queue `<topic>.university-record`, shared by the instances, so one
of them gets each event - see [`MESSAGE_BROKER.md`](MESSAGE_BROKER.md) §5) and settles each delivery
with `Ack`. This service's own `applicant.initialized` is relayed from its outbox to the broker, one
`Publish` per event to `events.applicant.initialized`, which fans it out to Applicant and Credential
Service (and back to this service, which ignores its own) - see [§12](#12-message-broker-logs-and-metrics-lab-4).
The envelope is unchanged.

| `event_type` | Direction | Notes |
| --- | --- | --- |
| `applicant.initialized` | received (from Applicant/Credential) and produced (only when this service is first contacted) | Builds records from **`actual`**, the truth. Own events (`initialized_by == "university-record-service"`) are ignored |
| `session.started` | **retired in `5.0.0`**, no longer subscribed | Until `4.0.1` it stored each junior's `record_scopes`; from `5.0.0` the saga step `grant-scopes` does (§13). One delivered anyway is an `event_type` not consumed here: `PERMANENT` |
| `session.ended` | received (from Session) | Upsert (not update) - a `session.ended` arriving before the grant still closes access, and from `5.0.0` a later `grant-scopes` for that session answers `409 SESSION_ENDED` instead of reopening it |

| Situation | `Ack` | The broker |
| --- | --- | --- |
| Applied | `OK`, sent only after the transaction with `processed_events` committed | done |
| An `event_id` already applied | `OK` (reason `duplicate`), nothing changes | done |
| Its own `applicant.initialized` coming back | `OK` | done |
| `envelope_json` that is not JSON, a broken envelope (`event_id` not a UUID, no `event_type` or `producer`, `occurred_at` not ISO 8601, `version` not an integer, no `payload`), an `event_type` not consumed here, a `version` other than `1`, a payload that fails validation (the old `422 INVALID_EVENT`) | `PERMANENT`, the reason (at most 200 characters, never a payload value) | dead-letters it - a retry cannot succeed |
| Anything else, such as the database being down or failing over (`5.0.0`: no primary answers) | `RETRY` | delivers it again later |
| The ack does not reach the broker, or the instance dies before acking | none (`broker.ack_failed` when the call fails) | delivers it again after its ack timeout; the dedup makes it harmless |

Delivery is at-least-once; every domain write this service performs is independently
idempotent (`ON CONFLICT DO NOTHING` on a natural key: `student_id`, `email`,
`(code, student_id)`, `message_id`), so redelivery is always safe to repeat. A payload fails
validation when, for example, an `applicant.initialized` has a `claimed` (or `actual`) that is not an
applicant profile with at least a `name`. In `applicant.initialized`, `claimed` and `actual` are the
profile itself (see "Shared values" in the CPR README), not an object with a `profile` key.
`processed_events` is a fast-path dedup check, not the sole correctness guarantee.

**Identity theft needs no special-case code.** Records are built from `actual`; a thief
claiming a victim's `student_id` writes nothing (they are typically an outsider), so the
victim's enrollment row - already present under that `student_id` - is simply what
Moderation Service sees when it looks the claimed identity up. First-writer-wins on the
unique `student_id`/`email` columns is the entire mechanism.

---

## 7. The identity model - shared with Applicant/Credential

This service implements the CPR's identity model (`{MAJOR}{yy}{g}{nn}` student IDs, the
admission-year/study-year window, email address rules) itself, since it must independently
derive `group`/`email-groups` from a peer's `actual.student_id` on ingest. **This is the
single highest integration risk in the system**: if the ASCII-folding rule for names disagrees
with Applicant/Credential's own implementation, an honest applicant with a diacritic in their
name reads as a liar the moment a junior searches for them.

Agreed vectors (see `NameNormalizerTests` in this service's test suite for the full table):

| Name | Local part |
| --- | --- |
| `Ion Popescu` | `ion.popescu` |
| `Ștefan Băț` | `stefan.bat` |
| `Ana-Maria Rusu` | `ana-maria.rusu` |
| `Olga D'Amico` | `olga.damico` |

Both codepoint forms of `ș`/`ț` are handled (the comma-below Unicode form and the legacy
cedilla form) - please confirm Applicant Service does the same.

---

## 8. Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | **The `courses` shape contradiction is resolved in favor of the JSON example, not the prose.** The contract says "the lists hold the same records a junior would find by searching", but the `courses` entries in `/applicants/{id}/records` (`{code, title, exists, registered}`) are shaped completely differently from the `courses` search-category record. This is necessary, not a bug: a course that does not exist has **no catalog row to return** - `exists: false, title: null` is the only way to represent that | Moderation Service, if it was coded against the prose |
| 2 | **`courses.json` is byte-identical to the CPR's [`shared/courses.json`](../shared/courses.json)**, and the catalog's SHA-256 is logged at startup so a difference is a one-glance diff. Listed because every service that ships the catalog must stay in step with it | Applicant, Credential, Moderation |
| 3 | **The `expelled` enrollment status is unreachable through events.** The shared applicant profile's `university_status` enum has no "expelled" value, so `actual.university_status` can never produce it - only this service's own `/applicants/next` generator can. Raised with the team as a gap in the shared identity model, not fixed unilaterally here | Anyone designing an "expelled student" scenario |
| 4 | **`q` is required on `GET /records/{category}`**, per the contract - there is no way to browse the course catalog without a search term. Flagged to the team as worth making optional for `courses` specifically; not changed unilaterally | Junior Moderators wanting to browse |

The divergences of Lab 5 (`5.0.0`) from the contract of #184 are listed in [§13](#divergences-from-the-lab-5-contract-184-and-from-176).

---

## Lab 3: status, logs, discovery, several instances

- **`GET /status`** answers without a credential and outside the concurrent task limit (like `/health`): `{ service, instance_id, version, status, in_flight, max_concurrent_tasks }`, `service` is `university-record`. `status` is `up`, or `degraded` with `503` when the database does not answer. `/health` and `/health/ready` are unchanged.
- **Logs** are JSON lines with `time`, `level`, `service`, `instance_id`, `version`, `event`, `msg` and the fields of the event (`http.request` carries `request_id`, `method`, `path`, `status`, `duration_ms`). An error is logged once, with its stack for an unexpected one. `startup` / `shutdown` carry the version, instance id, address and settings (a token only as `service_token_set`).
- **Service Discovery**: with `SERVICE_DISCOVERY_URL` set the instance registers as `university-record` (`PUT /api/v1/instances/<instance_id>` with its port, `host` only when `INSTANCE_HOST` is set), repeats it every 5 s as the heartbeat, and removes itself with `DELETE` on a clean stop; calls time out after 2 s and a failure is logged and retried at the next beat, it never stops the service.
- **Database**: the Npgsql pool is capped at 20 connections per instance unless the connection string sets `Maximum Pool Size`. Migrations and seeding run under a Postgres advisory lock, so instances starting together on an empty database run them once.
- **Several instances**: the relay claims outbox rows with `FOR UPDATE SKIP LOCKED` and a lease, so a delivery is pushed by one instance at a time, and a row whose instance died is claimed again when the lease ends. `event_id` is recorded with `INSERT ... ON CONFLICT DO NOTHING` in the same transaction as the effect, so the same event at two instances applies once. `session.started` stayed delete-then-insert, in that transaction, until it was retired in `5.0.0`; the saga step that replaces it is serialised per `(saga_id, step)` by a transaction-scoped advisory lock (§13).
- **Circuit breaker** (up to `3.0.1`; from `4.0.0` one breaker on the broker instead - see [§12](#12-message-broker-logs-and-metrics-lab-4)): one per consumer, `applicant` and `credential`. 3 failures inside `HTTP_REQUEST_TIMEOUT` x 3.5 (17.5 s) open it. A failure is no answer within `EVENT_PUSH_TIMEOUT`, a refused or reset connection, or a `5xx` (the Gateway's `502` and `503` included); `429` and other `4xx` do not count. While it is open the relay does not claim that consumer's rows (they stay pending, no attempt is counted) and the other consumer keeps going; after the same time one trial push closes it on success or reopens it. Every transition is logged (`breaker.opened|closed|rejected`). The breaker only logs and fails fast; it never tells Service Discovery anything.
- **Divergence from #85**: the item "the request answers `500 DEPENDENCY_UNAVAILABLE`" does not apply: this service makes no outbound call while answering a request, only the relay calls out (the broker from `4.0.0`), and it leaves the delivery pending.

## 9. Edge cases

- **The eventual-consistency window.** Right after a peer creates an applicant,
  `GET /applicants/{id}/records` may answer `404` for a few milliseconds until the event
  arrives - the same documented behavior as Applicant/Credential Service.
- **No instance of this service is subscribed.** From `4.0.0` the events published meanwhile wait in
  this service's queue at the broker and arrive once an instance subscribes again. Postgres down is
  the only thing that makes readiness `503`.
- **The broker is down.** The instance logs `broker.subscribe_failed` and subscribes again with backoff
  (1 s doubling to 30 s); its own events wait in the outbox, and the REST port, `/health` and `/status`
  keep answering.
- **Ruleset/session ordering.** A junior can legitimately query before the scopes have arrived
  (`session.started` until `4.0.1`, the saga step `grant-scopes` from `5.0.0`); this reads as
  `403 CATEGORY_NOT_ASSIGNED` (a session this service has not heard of grants no scope to anyone) and is expected
  to resolve on retry.
- **A compensated shift start** (`5.0.0`). The compensation of `grant-scopes` deletes the session and its scopes,
  so the juniors answer `403 CATEGORY_NOT_ASSIGNED` again, exactly as before the shift; it does not end the session
  (an ended one would answer `SESSION_ENDED`).
- **The database failing over** (`5.0.0`). See §13: `500 DEPENDENCY_UNAVAILABLE` or `408` while no primary answers,
  nothing changed, and the instance carries on with the promoted standby without a restart.

---

## 10. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `university-record`:

- `/applicants/{id}/records` and every `/admin/*` route are **player-lethal or
  service-only** - `actual`, cross-category access, and admin CRUD must never reach a client.
  Service calls only, and the request must arrive **without** `X-Player-Id`: that absence is how
  this service tells Moderation's full-access call from a junior's scoped one. From `4.0.1` (#151)
  `/admin/*` and `/dev/*` also need `X-Service-Token`, checked by the service: they are called directly,
  never through the Gateway or the broker.
- `GET /records/{category}` is the only genuinely player-facing endpoint: player JWT at the
  Gateway, scope checked here against `X-Player-Id`.
- `/dev/*` and `POST /applicants/next`: service calls only. `POST /applicants/next` is **not
  idempotent** - never retried. `POST /events` is removed in `4.0.0` (events come from the broker).
- No CORS headers, no rate limiting. `X-Request-ID` is echoed/generated on every response.
- `GET /logs` and `GET /metrics` (`4.0.0`) are not Gateway routes.
- `POST /saga-steps/grant-scopes` and `.../compensate` (`5.0.0`) are not Gateway routes either (`404` through it,
  with no Gateway change): only the broker's saga coordinator calls them, as service calls without `X-Player-Id`.
- **Lab 4 (#110, the Gateway's `4.0.0`):** the Gateway serves only user routes. Of this prefix two stay:
  `GET /records/{category}` (the player's JWT checked, then handed to the broker's queue
  `requests.university-record` with `X-Player-Id` set from it) and the public `GET /health`. Every other
  path answers `404 NOT_FOUND` before any credential is checked and nothing reaches the broker:
  `GET /applicants/{id}/records` and `POST /applicants/next` (Moderation, or any other service, sends them
  through the broker as service calls), `/admin/*`, `/dev/*`, `/health/ready`, `/status`, `POST /events`,
  `/logs` and `/metrics`; `/admin/*`, `/dev/*` and the probes are called on the instance itself (`/admin/*`, `/dev/*`
  and `/logs` with `X-Service-Token`). On the routes reached through the broker the service still tells a player's request from a
  service's only by the route and by the absence of `X-Player-Id`; it drops an `X-Service-Token` or
  `Authorization` header if one arrives from the broker.

---

## 11. Testing recipes and mocks

> **Direct port.** The recipes call the service's own port (`8084`), which the team compose does not
> publish: run the image alone with `-p 8084:8080`, or forward one instance of the team stack (below). On the
> team stack, through the Gateway, replace `localhost:8084/api/v1/` with `localhost:8080/api/v1/university-record/`
> and send a JWT from `POST /api/v1/player/auth/login` as `Authorization: Bearer` - for `GET /records/{category}`
> only: the Gateway's `4.0.0` answers `404` on every other route of this service. The contract routes read no token: on the direct port, send
> `X-Player-Id: <uuid>` to play a player and no `X-Player-Id` for a service call. `/admin/*` and `/dev/*` (from `4.0.1`)
> and `GET /logs` also need `X-Service-Token: <SERVICE_TOKEN>` (`403 SERVICE_TOKEN_REQUIRED` without it,
> `401 INVALID_SERVICE_TOKEN` when wrong).
>
> To call an instance of the team stack directly, so that direct calls and the Gateway's share one database, forward
> it to this machine only, for the demo:
> `docker run --rm -d --name university-record-direct --network student-id-net -p 127.0.0.1:8084:8080 alpine/socat TCP-LISTEN:8080,fork,reuseaddr TCP:university-record-service:8080`
> (the service name reaches one of the copies; `docker stop university-record-direct` when done). Bind it to
> `127.0.0.1` and never leave it running: the instance trusts `X-Player-Id` as it comes, which is why the team stack
> publishes no port of it.

Peers that may be missing are replaced by real code paths, not by throwaway ones:

1. **`POST /api/v1/applicants/next`** is a contract-mandated endpoint, not scaffolding - it lets this service generate a whole applicant (with lies driven by `difficulty`) and exercises the exact same `ApplicantRecordFactory` the event consumer uses.
2. **`/api/v1/admin/sessions/{id}/scopes`** doubles as a manual mock of Server Moderation Session Service (with `X-Service-Token` from `4.0.1`). Until `4.0.1` it stood in for `session.started`; from `5.0.0` the real path is the saga step, which can be called directly on the instance (no `X-Player-Id`) in place of the broker's coordinator, see §13.
3. **`GET /api/v1/dev/slow?ms=`** (only when `Dev__EnableTestEndpoints=true`, with `X-Service-Token` from `4.0.1`) sleeps, to show `408` (with a lower `HTTP_REQUEST_TIMEOUT`) and `429` (with a lower `MAX_CONCURRENT_TASKS`).

`POST /api/v1/events`, which took the three events directly, is removed in `4.0.0`: an event now has to
be published to the broker with the full envelope (`event_id`, `event_type`, `occurred_at`, `producer`,
`version`, `payload`), as Applicant and Credential `4.0.0` do (`POST /applicants/next` there), and as
Session does from its Lab 4 image (#115).

```bash
BASE=http://localhost:8084
PLAYER=$(uuidgen)

# Generate an applicant here: its applicant.initialized is published once to the broker (broker.published)
curl -s -X POST "$BASE/api/v1/applicants/next" -H 'Content-Type: application/json' \
  -d "{\"session_id\": \"$(uuidgen)\", \"difficulty\": 3}"

# A junior searches (the Gateway would set X-Player-Id from the JWT); no scope assigned yet => 403
curl -s "$BASE/api/v1/records/courses?session_id=$(uuidgen)&q=pad" -H "X-Player-Id: $PLAYER"
```

Through the broker, with its command-line client (`scripts/smoke.py` in `message-broker-service`, run
where it reaches the broker's gRPC port, with `SERVICE_TOKEN` set):

```bash
# A request on requests.university-record, as Moderation sends it (no X-Player-Id): one instance serves it
python -m scripts.smoke request --service university-record --path /api/v1/applicants/<applicant_id>/records
# A player's search, as the Gateway sends it after the JWT check
python -m scripts.smoke request --service university-record --player "$PLAYER" \
  --path "/api/v1/records/enrollment?session_id=<session_id>&q=FAF23117"

# The session ends (step 10 of the Postman scenario): applied, Ack OK; the juniors' searches then get 403 SESSION_ENDED
python -m scripts.smoke publish --producer server-moderation-session-service --topic events.session.ended \
  --payload '{"session_id": "<session_id>", "ended_at": "2026-11-09T12:00:00Z"}'
# A payload it cannot read (session_id not a UUID): event.rejected, Ack PERMANENT, and the broker dead-letters it
# (the old 422 INVALID_EVENT)
python -m scripts.smoke publish --topic events.session.ended --payload '{"session_id": "x", "ended_at": "2026-11-09T12:00:00Z"}'
```

`smoke.py` sends the whole envelope (`occurred_at` included) from the broker's `4.0.0`; an earlier copy of the
broker's `dev` left `occurred_at` out, and this service refuses such an event as `PERMANENT`.

The Postman collection (`postman/university-record-service.postman_collection.json` in the CPR)
runs the reads of the honest-student, identity-theft and session-end scenario with assertions on
every step; the three events it used to push to `POST /events` (both `applicant.initialized` and
`session.ended`) now have to reach the service through the broker first. The scopes of the scenario are set by the
saga step `grant-scopes`, called directly as the coordinator would, when the instance is `5.x`, and with the
session-service mock on a `4.x` instance (the request for the other version is skipped). The folder
"Saga step grant-scopes (direct, inside the network)" covers the step and its compensation (§13); it reads the
instance's version from `GET /status` first and skips its requests on a `4.x` instance. Only `GET /health` and `GET /records/{category}` go through the Gateway
(`{{base_url}}`, the player's JWT signed by the collection); every other request goes to one instance
directly (`{{university_record_direct_url}}`, the path without the Gateway's `/university-record` prefix,
`X-Service-Token: {{service_token}}` on `/admin/*`, `/dev/*` and `GET /logs`, none on the contract routes), since
the Gateway's `4.0.0` serves no other route of this service. The service-only refusals also send no token and a
wrong one to an admin route (`403`, `401`). Forward an instance of the team stack as above, so that both reach the same database.

---

## 12. Message Broker, logs and metrics (Lab 4)

From `4.0.0`, as CPR README "Event delivery", "Message Broker", "Authentication" ("Through the Message
Broker"), "Logs download" and "Monitoring" describe it (#105). `Protos/broker.proto` is a
byte-identical copy of the CPR's [`shared/broker.proto`](../shared/broker.proto).

### The subscription

- One gRPC `Subscribe` stream per instance to `MESSAGE_BROKER_URL` (plaintext HTTP/2 inside `student-id-net`):
  `service: "university-record"`, `instance_id: INSTANCE_ID`, `topics: ["events.applicant.initialized", "events.session.ended"]` (`5.0.0`; until `4.0.1` also
  `"events.session.started"`), `max_concurrent_tasks: MAX_CONCURRENT_TASKS`. The broker
  attaches the queue `requests.university-record` to the same stream. Every call (`Subscribe`, `Ack`, `Reply`,
  `Publish`) carries the metadata `x-service-token: SERVICE_TOKEN`.
- It starts once the REST listener is up (requests are served through it). Every delivery is handled on its own
  task, so a slow one never holds back the stream: an event is applied and acked (§6), a request is answered with
  `Reply`.
- A stream that cannot be opened or ends logs `broker.subscribe_failed` and is opened again after 1 s, 2 s, 4 s ...
  at most 30 s (`broker.subscribed` with `reconnect: true` once it is back). HTTP/2 keepalive pings (every 2 s,
  answered within 2 s) notice a dead broker. `/health`, `/health/ready` and `/status` do not report the broker, so
  Service Discovery does not mark an instance down while only its broker is away.
- Shutdown: the stream ends as soon as the host starts stopping, before the REST listener closes, so the broker
  stops routing requests here; what was already received is still served (up to 3 s). An event that is not acked
  is delivered again by the broker.
- `MESSAGE_BROKER_URL` empty: one `broker.disabled` warning, nothing is received, the own events wait in the outbox.

### Requests from `requests.university-record`

A delivered request (`method`, `path` with its query, `headers`, `body`) is sent in-process to this instance's own
REST listener (`http://127.0.0.1:<port>`), so it meets the same request id, concurrent task limit (`429`), task
timeout (`408`), access log and authentication as a direct call. The answer goes back with `Reply`: the status, the
headers, the body, the request's `correlation_id` and this instance's id - a `4xx` or `5xx` too, unchanged.

- Headers pass verbatim, `X-Player-Id` included: a request without it is a service call. `X-Service-Token` and
  `Authorization` (and the hop-by-hop headers) are dropped if they arrive, and no credential is ever added.
  `X-Request-ID` is taken from the delivery when the request has none. A header value must be one line of printable
  ASCII, and an invalid request id is not passed on.
- The path must be one absolute path of this service (it starts with one `/` and stays on `127.0.0.1:<port>`), and
  the method a standard one; otherwise the instance itself replies `400 VALIDATION_ERROR`. The in-process call may
  take the caller's `timeout_ms` (at most 60 s), else the task timeout plus 1 s; past that the instance replies
  `408 REQUEST_TIMEOUT`, and a loopback failure `500 INTERNAL_ERROR`, in the shared error envelope.
- The saga step routes (`5.0.0`) arrive this way, from the coordinator (`caller: "message-broker"`, no
  `X-Player-Id`), and are served like any service call (§13).
- `GET /logs`, and from `4.0.1` `/admin/*` and `/dev/*`, cannot be reached this way: no request through the broker
  carries the token they check (`403 SERVICE_TOKEN_REQUIRED`).

### Publishing: the outbox through the broker

- An event is written to the outbox in the same transaction as its records: **one row per event**, with the consumer
  `message-broker` (the unique key `(event_id, consumer)` stays).
- The relay claims due rows (`FOR UPDATE SKIP LOCKED`, a lease of twice `EVENT_PUSH_TIMEOUT` plus 5 s) and publishes
  each **once**: gRPC `Publish` to `events.<event_type>` with the common envelope unchanged as `envelope_json`, the
  request id of the request that created the event, and the deadline `EVENT_PUSH_TIMEOUT`.
- `Publish` returned: delivered (`broker.published`, with the broker's `message_id`). `INVALID_ARGUMENT` (the broker
  says the event is invalid): parked (`event.parked`). Any other error: retried after 1 s, 2 s, 4 s ... at most 30 s
  (`event.pushed`, `warn`). `GET /health/ready` (`pending_events`, `parked_events`) and `GET /metrics`
  (`outbox_pending`, `outbox_parked`) count them.
- **Circuit breaker:** one, on the broker (`target: message-broker`). 3 failed publishes (no answer within
  `EVENT_PUSH_TIMEOUT`, `UNAVAILABLE`, `DEADLINE_EXCEEDED`, `INTERNAL`, `UNKNOWN`, `DATA_LOSS`, `ABORTED`, `CANCELLED`;
  a refusal such as `RESOURCE_EXHAUSTED` or a wrong token is not a failure) inside `HTTP_REQUEST_TIMEOUT` x 3.5
  (17.5 s) open it. While it is open the relay claims nothing and the outbox waits; after the same time one trial
  publish closes it or reopens it. Per instance, only logged (`breaker.opened|closed|rejected`), and shown as
  `breaker_state{target="message-broker"}`.
- **Migration `20261107120000_OutboxThroughBroker`** (applied at startup, like every migration) folds the Lab 3 rows
  of an event (one per consumer, `applicant` and `credential`) into one `message-broker` row, the lowest `id`:
  pending, with its attempts reset, when any of them was pending (a consumer that had it already drops the repeat by
  `event_id`); else parked, with that row's error, when one was parked; else delivered, at the last delivery time.
  Its down migration splits each row back into an `applicant` and a `credential` row in the same state.

### Registration with Service Discovery

The registration (`PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}`, every 5 s) carries the topics (#111),
a mirror of the subscription, which is the source of truth:
`"topics": {"publishes": ["events.applicant.initialized"], "subscribes": ["events.applicant.initialized", "events.session.ended"]}`
(`5.0.0`; until `4.0.1` `subscribes` also listed `"events.session.started"`). Both come from one list in the code
(`EventDispatcher.ConsumedEventTypes`), so the subscription and the registration cannot drift apart.

### `GET /logs?since=&until=&level=`

As CPR README "Logs download" defines it (#112): this instance's own lines from `LOG_FILE` and its rotated files
(`university-record_001.jsonl`, `_002`, ...), oldest first, unchanged, `since <= time < until` (RFC 3339 with a zone),
`level` and above.

| Answer | When |
| --- | --- |
| `200 application/x-ndjson`, `Content-Disposition: attachment; filename="<instance_id>-<since as 20261105T112700Z, or start>.jsonl"` | the lines, possibly none; the headers are sent before the files are read |
| `403 SERVICE_TOKEN_REQUIRED` / `401 INVALID_SERVICE_TOKEN` | no `X-Service-Token` / a wrong one (compared in constant time) |
| `400 VALIDATION_ERROR`, `details.errors: [{field, message}]` | a malformed time, a time without a zone, `until <= since`, an unknown `level` |
| `503 LOGS_UNAVAILABLE` | `LOG_FILE` empty, or the file could not be opened or read |

Every file is opened before any is read, each read up to its size at that moment; a line that is not one whole JSON
object (or has no newline yet) is left out. Outside the concurrent task limit and the task timeout; its access line
is `debug`. A log file that cannot be opened at startup logs one `logs.file_unavailable` warning, and the service
runs on stdout only.

```bash
curl -s "http://<instance>:8080/logs?since=2026-11-07T17:00:00Z&level=warn" -H "X-Service-Token: $SERVICE_TOKEN"
```

### `GET /metrics`

Prometheus text format, no credential, outside the concurrent task limit.

| Series | Labels |
| --- | --- |
| `http_requests_total` | `method`, `route` (the route template, `unmatched` for a path no route serves), `status`; every request the REST listener answers, the broker's included |
| `http_request_duration_seconds` (histogram) | `method`, `route` |
| `tasks_in_flight` | - (requests holding a concurrent-limit slot, `in_flight` of `/status`) |
| `breaker_state` | `target="message-broker"`: `0` closed, `1` open, `2` half-open |
| `outbox_pending`, `outbox_parked` | - (read from the database at each scrape; the previous value stays when it does not answer) |
| process metrics | those of prometheus-net |

A method outside the standard ones is `OTHER`, so no caller can grow the number of series.

### New log events

| `event` | Level | Fields |
| --- | --- | --- |
| `broker.subscribed` / `broker.subscribe_failed` / `broker.disabled` | `info` / `warn` | `instance_id`, `topics`, `queue`, `max_concurrent_tasks`, `reconnect`; `error`, `attempt`, `retry_in_s` when failed |
| `broker.received` | `info` | `message_id`, `queue`, `attempt`, `event_id`, `event_type`, `producer` |
| `event.received` | `info` | `event_id`, `event_type`, `producer`, `duplicate` (applied after the commit) |
| `event.rejected` / `event.failed` | `warn` / `error` | `event_id`, `event_type`, `producer`, `error` (the `PERMANENT` / `RETRY` cases of §6) |
| `broker.acked` / `broker.ack_failed` | `info` / `warn` | `message_id`, `queue`, `outcome`; `reason` / `error` |
| `broker.delivery_failed` | `error` | `message_id`, `queue`, `error` (a delivery that could not be handled at all) |
| `request.received` / `request.replied` / `request.reply_failed` | `info` / `info` / `warn` | `message_id`, `correlation_id`, `method` and `path` (no query string); `caller` on received, `status` and `duration_ms` on replied, `status` and `error` on reply_failed |
| `broker.published` / `event.pushed` / `event.parked` | `info` / `warn` / `error` | `event_id`, `event_type`, `topic`, `attempt`; `message_id` when published, `status` and `error` otherwise, `next_attempt_at` on `event.pushed` |
| `outbound.call` | `info`; `warn` when not `OK` | `target: message-broker`, `method: Publish`, `path` (the topic), `status`, `duration_ms` |
| `breaker.opened` / `breaker.closed` / `breaker.rejected` | `error` / `info` / `warn` | `target: message-broker`, `failures`, `window_s` |
| `logs.file_unavailable` | `warn` | `path`, `error`, once at startup |

`startup` also carries `message_broker_url`, `topics_subscribed`, `topics_published`, `event_push_timeout` and the
log file settings; `client_ip` is `127.0.0.1` for a request the broker delivered. Logs carry ids only: never a token,
a query string or an applicant's personal data (name, email, student ID, status). `4.0.0` stopped logging an
applicant's name and status value on ingest and the email's local part in the message of
`EmailNamespaceExhaustedException`.

---

## 13. Lab 5: saga step, replicated database, ETL grants

From `5.0.0` (#176), as CPR README "Sagas", "Database replication" and "Data warehouse and ETL" describe it (#163,
contract PR #184). Divergences from that contract are listed at the end of this section.

### The saga step `grant-scopes`

University Record is step 2 of 4 of the saga `shift.start` (`shift-begin` in Session, `grant-scopes` here,
`create-channels` in Discord DMs, `shift-confirm` in Session). The Message Broker is the coordinator: it calls the
step, and when a later step fails its compensation, as requests on the queue `requests.university-record`
(`caller: "message-broker"`, no `X-Player-Id`, `timeout_ms` `2000`). They are replayed over loopback like every
request from the broker (§12), so the task timeout (`408`) and the concurrent limit (`429`) apply.

| Method | Path | Does |
| --- | --- | --- |
| `POST` | `/api/v1/saga-steps/grant-scopes` | Stores each junior's `record_scopes` for the session, as `session.started` did until `4.0.1`: the session becomes `active` and its scopes are replaced |
| `POST` | `/api/v1/saga-steps/grant-scopes/compensate` | Deletes the session and its scopes, so the juniors' `GET /records/{category}` answer `403 CATEGORY_NOT_ASSIGNED`, as before the shift |

**Body** of both routes (the payload is what `session.started` carried):

```json
{
  "saga_id": "0b9e3c55-8f0e-4c63-9d6b-2f1d3e5a7b90",
  "saga_type": "shift.start",
  "step": "grant-scopes",
  "payload": {
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
    "junior_moderators": [
      { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] },
      { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "record_scopes": ["email-groups", "fcim-logs"] }
    ],
    "ruleset_version": 7,
    "started_at": "2026-09-10T18:05:00Z"
  }
}
```

- `saga_id`: a UUID, not the empty one. `saga_type`: exactly `"shift.start"`. `step`: `"grant-scopes"`, or left out
  (or `null`).
- The step needs the whole payload: `session_id` and `moderator_id` (UUIDs), `ruleset_version` (an integer `>= 1`),
  `started_at` (ISO 8601), `junior_moderators` (an array, may be empty), each with a `player_id` (UUID) and
  `record_scopes` (an array of `enrollment`, `email-groups`, `courses`, `fcim-logs`).
- The compensation reads only `saga_id`, `saga_type`, `step` and `payload.session_id`, so it succeeds whenever it can
  be carried out.

**Answer** `200 OK`:

```json
{ "saga_id": "0b9e3c55-8f0e-4c63-9d6b-2f1d3e5a7b90", "step": "grant-scopes", "state": "done" }
```

`"state": "compensated"` for the compensation.

**Idempotency by `(saga_id, step)`.** The table `saga_steps(saga_id, step, state, updated_at)` (primary key
`(saga_id, step)`, `state` `done` or `compensated`) is written in the same transaction as the effect, under a
transaction-scoped advisory lock on `(saga_id, step)`, so a step and its compensation arriving together at two
instances see each other's outcome.

| Call | State before | Effect | Answer |
| --- | --- | --- | --- |
| step | none | grants the scopes, records `done` | `200 done` |
| step | `done` | nothing (not redone) | `200 done` |
| step | `compensated` | nothing | `409 SAGA_STEP_COMPENSATED`, `details: { saga_id, step }` |
| step | none, but the session has already ended here (`session.ended`) | nothing recorded, the session is not reopened | `409 SESSION_ENDED`, `details: { session_id }` |
| compensation | `done` | deletes the session and its scopes, records `compensated` | `200 compensated` |
| compensation | none | records a **tombstone** `compensated`, touches no session (one this saga did not grant is not its to delete) | `200 compensated` |
| compensation | `compensated` | nothing | `200 compensated` |

The tombstone is what makes a step that arrives late, after its compensation, answer `409 SAGA_STEP_COMPENSATED`
instead of granting scopes the saga has already given up. The compensation deletes the session instead of ending
it: only an unknown session answers `CATEGORY_NOT_ASSIGNED`, as before the shift; an ended one would answer
`SESSION_ENDED`.

**Errors**, in the shared envelope:

| Answer | When | The coordinator |
| --- | --- | --- |
| `400 VALIDATION_ERROR`, `details: { "field": "payload.junior_moderators[0].record_scopes" }` | the body is not JSON or not an object, or a field above is missing or wrong (an unknown record category included); `field` names it (`body`, `saga_id`, `saga_type`, `step`, `payload`, `payload.session_id`, ...) | step `failed`, no retry: the saga compensates |
| `403 SERVICE_TOKEN_REQUIRED` | the request carries `X-Player-Id`: a player can never call these routes | step `failed` (never happens through the broker) |
| `409 SAGA_STEP_COMPENSATED` / `409 SESSION_ENDED` | see the table above | step `failed` |
| `408 REQUEST_TIMEOUT`, `429 TOO_MANY_REQUESTS` | the task timeout, the concurrent limit; nothing changed | retried |
| `500 DEPENDENCY_UNAVAILABLE`, `details: { "dependency": "postgres" }` | no database primary answers (below); nothing changed | retried |

**Access.** Service-only: a request with `X-Player-Id` is refused (`403 SERVICE_TOKEN_REQUIRED`, the code every
service-only route of this service uses). There is **no `X-Service-Token` check**: the broker drops that header, and
these paths are not under `/api/v1/admin` or `/api/v1/dev`, which the token guards. The Gateway does not route them
(`404` through it, with no Gateway change). Inside `student-id-net` they can also be called directly on an instance,
without `X-Player-Id`, which is how the Postman collection exercises them; an `X-Service-Token` sent along is ignored.

**Log events**:

| `event` | Level | Fields |
| --- | --- | --- |
| `saga_step.result` | `info` for `Done`, `warn` for a refusal | `saga_id`, `saga_type`, `step`, `outcome` (`Done`, `AlreadyCompensated`, `SessionEnded`), `duplicate` (a repeat of a done step), `session_id`, `junior_moderators` (the count), `ruleset_version` |
| `saga_step.compensated` | `info` | `saga_id`, `saga_type`, `step`, `session_id`, `previous_state` (`done`, `compensated` or `none` for a tombstone) |
| `db.unavailable` | `warn` | `status`, `code`, `method`, `path`, the exception: a request answered `500 DEPENDENCY_UNAVAILABLE` (below) |

The broker's own saga events are `saga.*`; this service's are `saga_step.*`, so the two never mix.

```bash
# Inside student-id-net, directly on an instance, as the coordinator would call it (no X-Player-Id)
curl -s -X POST http://university-record-service:8080/api/v1/saga-steps/grant-scopes \
  -H 'Content-Type: application/json' -d @grant-scopes.json          # 200 {"state":"done"}
curl -s -X POST http://university-record-service:8080/api/v1/saga-steps/grant-scopes/compensate \
  -H 'Content-Type: application/json' -d @grant-scopes.json          # 200 {"state":"compensated"}
```

### `session.started` retired

The scopes arrive with the saga step, so the subscription and the Service Discovery registration list only
`events.applicant.initialized` and `events.session.ended` (both derived from `EventDispatcher.ConsumedEventTypes`).
A `session.started` that is delivered anyway is an `event_type` this service does not consume: acked `PERMANENT`, and
the broker dead-letters it. `session.ended` still closes the juniors' access (`403 SESSION_ENDED`), and from `5.0.0`
a grant that arrives after it no longer reopens the session (`4.0.1` set it `active` unconditionally).

### The replicated database

In the Lab 5 stack `university_record_db` runs as `university-record-postgres-1` (primary) and `-2`, `-3` (hot
standbys, synchronous to one of them), with the pattern of `deployments/postgres-ha/` (#164); `pg-failover`
promotes the most advanced standby when the primary stops and turns a returning old primary into a standby.

- **Connection.** `ConnectionStrings__UniversityRecordDb` lists the three hosts:

  ```
  Host=university-record-postgres-1,university-record-postgres-2,university-record-postgres-3;Port=5432;Database=university_record_db;Username=university_record_user;Password=<password>;Target Session Attributes=read-write;Timeout=3;Host Recheck Seconds=2
  ```

  Npgsql connects only to the host that accepts writes (never to a standby, so never to a returning old primary),
  gives a host 3 s to answer, and rechecks the hosts' roles every 2 s, so a promoted standby is used without a
  restart. The pool cap of 20 per instance keeps the string unchanged. One host (`Host=postgres;...`) stays right for
  a local run and for the service's own one-node compose; the migration below runs on both.
- **While no primary answers** (a failover, the database stopped), a request answers `500 DEPENDENCY_UNAVAILABLE`
  with `details.dependency: "postgres"`, never `500 INTERNAL_ERROR`, and logs `db.unavailable`. Unavailable means,
  anywhere in the exception chain: EF giving up its retries of a transient failure, a connect or command timeout, an
  Npgsql error that is not a server error (no connection, a lost connection, no host with the wanted
  `Target Session Attributes`), or a server error of class `08` (connection), `53` (insufficient resources), `57P0x`
  (shutdown, cannot connect now) or `25006` (read-only transaction: the host was demoted to a standby). Any other
  server error (a violated constraint, bad SQL) stays `500 INTERNAL_ERROR`. The broker's breakers do not count
  `DEPENDENCY_UNAVAILABLE`, and the saga coordinator retries it. EF retries a transient failure up to 5 times, so a
  request may instead reach the 5 s task timeout: `408 REQUEST_TIMEOUT`. Nothing is changed either way, since every
  write runs in one transaction, and a retried transaction starts from a clean change tracker.
- Meanwhile `GET /status` answers `503 degraded` and `/health/ready` is not ready (both check the database); an event
  that cannot be applied is acked `RETRY` (§6) and delivered again.
- **Startup.** The migrations and the seed wait for a primary: tried again after 1, 2, 4, 8, then every 10 s, each
  failure logged, instead of stopping the instance; any other startup error still stops it.

### ETL grants and watermarks

The migration `20261117162153_SagaStepsAndEtlGrants` creates the role `etl_reader` (`NOLOGIN`) when it is missing, so
it also runs on a database without the replication pattern (CI, a local run; the pattern's init script creates the
role with `LOGIN` and its password), and grants it `SELECT` on the institutional records only:

| Table | Grant |
| --- | --- |
| `applicants` | by column: every column but `claimed_email`, `actual_email` and `raw_event_json` (the whole profile) |
| `email_group_records` | by column: every column but `email` |
| `enrollment_records`, `courses`, `course_offerings`, `course_registrations`, `course_schedule_slots` | the whole table |
| `fcim_log_records` (author emails, message text), `sessions`, `session_scopes`, `outbox_messages`, `processed_events`, `saga_steps` | nothing |

**No `ALTER DEFAULT PRIVILEGES`.** The CPR adds default privileges only where every column of a future table may be
read; this database holds emails and message text, so a table a later migration creates is granted there, by name.
The down migration revokes the grants and keeps the role (the replication pattern may have created it).

**Watermarks** for the ETL's incremental reads (it reads `>=` the stored watermark and upserts):

| Table | Watermark |
| --- | --- |
| `applicants`, `enrollment_records`, `email_group_records`, `course_registrations` | `created_at` (rows are not updated in place) |
| `courses` | `updated_at`, new in `5.0.0`, `DEFAULT now()`; moved when the title, an offering or the schedule changes |
| `course_offerings` | `created_at`, new in `5.0.0`, `DEFAULT now()` |
| `course_schedule_slots` | the increasing `id` (a course's slots are re-inserted when it is upserted) |

### Divergences from the Lab 5 contract (#184) and from #176

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | **`409 SESSION_ENDED` on the step.** #184 lists only `409 SAGA_STEP_COMPENSATED` for `grant-scopes`. The step also answers `409 SESSION_ENDED` (`details.session_id`) when the session has already ended here, instead of reopening it; for the coordinator it is "anything else", so the step fails and the saga compensates, which is right for a shift that cannot start | The broker's coordinator (#168), which treats it as any `4xx` |
| 2 | **`step` is optional in the body.** #184 shows `"step": "grant-scopes"` in every body; the route already names the step, so a body without `step` (or with `null`) is accepted. A `step` with another value is `400 VALIDATION_ERROR` (`details.field: "step"`) | none: the coordinator always sends it |
| 3 | **`400 VALIDATION_ERROR` carries `details.field`** (one field), not the `details.errors[]` list of `GET /logs` | none: the coordinator only reads the status |
| 4 | **No `ALTER DEFAULT PRIVILEGES`.** #176's acceptance criteria ask for default privileges on tables later migrations create; #184 allows them only where every column of a future table may be read. This database holds secrets, so there are none and each later table is granted by name (above). This follows #184 and differs from the wording of #176 | the ETL (#165): a new table is readable only once its migration grants it |
| 5 | **The startup waits for a primary** instead of exiting. #184 allows either ("may exit; the compose `restart` brings it back") | none |

### Not yet in the team stack

`5.0.0` is merged in the service's `dev` and its image is not yet published. Until the final Lab 5 delivery the CPR
compose runs `4.0.1` on one database container (`university-record-postgres`): no saga routes, `session.started`
still subscribed, no ETL grants. The final delivery converts the compose to the three database containers (#170),
moves the tag to `5.0.0` and updates README "Deployments", together with the saga cutover of the broker (#168),
Session (#172) and Discord DMs (#178).

---

*University Record Service is owned by Titerez Vladislav. See the service's own repository
README for build/test instructions and the EF Core migration history.*
