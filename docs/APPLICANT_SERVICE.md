# Applicant Service — Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway, load balancer, authentication layer and other
> cross-cutting system pieces. It documents what this service does, how to run it, how to
> talk to it, what it guarantees, and — importantly — what it does **not** do.
>
> Everything here is stated from the implementation shipped as image `3.0.0`, not from the design
> documents. Where that image diverges from the team's Common Public Repository (CPR) contract,
> the divergence is called out explicitly in [§12](#12-divergences-from-the-cpr-contract).

---

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Prerequisites and running it](#3-prerequisites-and-running-it)
4. [Ports and networking](#4-ports-and-networking)
5. [Configuration](#5-configuration)
6. [HTTP API](#6-http-api)
7. [Data formats and validation](#7-data-formats-and-validation)
8. [Representation invariants](#8-representation-invariants)
9. [Events](#9-events)
10. [What and how it stores](#10-what-and-how-it-stores)
11. [Use cases and interaction flows](#11-use-cases-and-interaction-flows)
12. [Divergences from the CPR contract](#12-divergences-from-the-cpr-contract)
13. [Edge cases and failure modes](#13-edge-cases-and-failure-modes)
14. [Gateway requirements](#14-gateway-requirements)
15. [Scaling, concurrency and statefulness](#15-scaling-concurrency-and-statefulness)
16. [Observability](#16-observability)
17. [Known gaps — deliberately not implemented](#17-known-gaps--deliberately-not-implemented)
18. [Recipes for testing against it](#18-recipes-for-testing-against-it)

---

## 1. What this service is

Applicant Service owns **the identity of the people trying to get into the university Discord
server**. It is the source of truth for who an applicant claims to be.

Every applicant exists **twice**:

| | Who sees it | Purpose |
| --- | --- | --- |
| **`claimed`** | Served over HTTP to players and to Moderation Service | What the applicant says about themselves at the door |
| **`actual`** | **Never served over HTTP.** Leaves the service only inside the `applicant.initialized` event | Who they really are |

Credential Service builds the applicant's documents from `claimed`; University Record Service
builds the university's hidden records from `actual`. **Every field where the two differ is a
lie** a moderation team can discover. That asymmetry is the entire game, which makes two rules
non-negotiable for anyone integrating:

- **Never expose `actual` to a player.** This service will not hand it to you over REST; if
  you receive it from the event, keep it internal.
- **Never expose the lie metadata** (`lie_archetype`, `is_honest`). It is not in any HTTP
  response and must not be reintroduced downstream.

### Boundary

- **Owns:** `applicant_id`, name, student ID, email, major, year, university status, enrolled
  courses, requested role — for both the claimed and the actual profile.
- **Does not own:** credential documents (Credential Service), hidden institutional records
  (University Record Service), the admission decision or ban list (Moderation Service),
  sessions (Server Moderation Session Service), players (Player Service).
- **Calls no other service.** It has zero outbound HTTP dependencies. It shares new applicants
  only by publishing an event.

---

## 2. Integration card

| | |
| --- | --- |
| **Service name / `producer` / `initialized_by`** | `applicant-service` |
| **Lab 3 service name** | `applicant` - the Gateway prefix, the `service` of every log line and of `GET /status`, and the `service_name` it registers under. Each copy is `applicant-<hostname>` (`instance_id`) |
| **Language / framework** | Go 1.25, Gin |
| **Container port** | `8081` |
| **Default host port** | `8081` (the shipped compose file publishes `8081`-`8083`, one per copy; the team compose publishes none) |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/applicant/...` |
| **Health (liveness)** | `GET /health` |
| **Health (readiness)** | `GET /health/ready` |
| **Status (Service Discovery)** | `GET /status` - load and health of this copy, polled by Service Discovery ([§6.8](#68-health)) |
| **Database** | PostgreSQL 16, `applicant_db` (private — no other service may connect) |
| **Events** | HTTP push through the Gateway, no broker (CPR README "Event delivery"): produced from a transactional outbox to `{gateway}/api/v1/<consumer>/events`, received on `POST /api/v1/events` |
| **Produces** | `applicant.initialized`, pushed to Credential and University Record Service |
| **Consumes** | `applicant.initialized` (from Credential / University Record only) |
| **Authentication** | Checked by the Gateway, not here: callers send `Authorization: Bearer <jwt>` or `X-Service-Token` to the Gateway, which forwards only `X-Player-Id`. The service validates no token - see [§14](#14-gateway-requirements) |
| **Outbound HTTP calls** | The event pushes, `POST {gateway}/api/v1/credential/events` and `POST {gateway}/api/v1/university-record/events`, with `X-Service-Token` and a circuit breaker per consumer; and its own registration, `PUT`/`DELETE {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}`, directly to Service Discovery |
| **Docker image** | `stewdh/applicant-service:3.0.0` (also `:latest`), public on Docker Hub, `linux/amd64` and `linux/arm64`, published by CI on every merge to `main` |
| **Instances** | 2-3 copies share the one database; the Gateway finds them in Service Discovery and spreads requests round-robin ([§15](#15-scaling-concurrency-and-statefulness)) |
| **Hard dependency** | PostgreSQL only. The Gateway, the consumers and Service Discovery are soft — the service runs fully without them, events wait in the outbox and the registration is retried every 5 s |

---

## 3. Prerequisites and running it

### To run it

- **Docker** with Compose v2. Nothing else.

### To develop or test it

- **Go 1.25+**. All dependencies are pure Go (`CGO_ENABLED=0`), so there is no C toolchain
  requirement.

### Start it

```bash
./scripts/run.sh                # build image, start postgres + service, wait for ready
./scripts/run.sh --local        # run from source against the containerised dependencies
./scripts/run.sh --down         # stop (add --volumes to drop data)
./scripts/run.sh --logs         # follow logs
```

On first run the script creates `.env` from `.env.example` **with a randomly generated
database password**. `SERVICE_TOKEN` stays the placeholder: it has to equal the Gateway's, so
set it by hand before integrating. `.env` is gitignored.

### Start it from the published image only

Use [`deployments/docker-compose.team.yml`](../applicant-service/deployments/docker-compose.team.yml) — the same
stack with `build:` removed and the Docker Hub image pinned. This is the fragment to merge
into the team-wide compose file; it lets anyone run Applicant Service without cloning its
(private) repository.

### Minimum viable configuration

The only required variable is `DATABASE_URL`. Everything else has a working default - but
without `SERVICE_TOKEN` and the consumer URLs the relay is off and no event leaves the outbox.

```bash
DATABASE_URL=postgres://user:pass@host:5432/applicant_db?sslmode=disable \
SERVICE_TOKEN=<the stack's token> \
CREDENTIAL_URL=http://gateway-service:8080/api/v1/credential \
UNIVERSITY_RECORD_URL=http://gateway-service:8080/api/v1/university-record \
  ./applicantd
```

### Startup sequence (what a supervisor should expect)

1. Parse and validate configuration. **Invalid configuration exits non-zero immediately** with
   a message naming the variable.
2. Connect to PostgreSQL, retrying with backoff for up to `DB_CONNECT_TIMEOUT` (30s default).
   **If the database is not reachable within that window, the process exits non-zero.**
3. Apply embedded migrations under a PostgreSQL advisory lock. Copies that start together
   take turns: the first applies them, the others find nothing left to do, and all of them start.
4. Start the outbox relay, when `SERVICE_TOKEN` and at least one consumer URL are set. It
   needs nothing to be up: an unreachable Gateway or consumer is retried with backoff.
5. Open the HTTP listener and log `startup` with the version, instance id, port and the
   configuration (no secrets) — **the service is now serving**.
6. Register with Service Discovery (`PUT /api/v1/instances/{instance_id}`), when
   `SERVICE_DISCOVERY_URL` is set, and repeat it every 5 s as the heartbeat. The listener is up
   first, so the first status poll that follows finds `GET /status` answering. A Service
   Discovery that is not up yet costs one `sd.heartbeat_failed` warning per heartbeat, never a
   request.

Typical cold start against a warm database is well under a second.

---

## 4. Ports and networking

| Port | Component | Notes |
| --- | --- | --- |
| `8081` | Applicant Service HTTP | Set by `APP_PORT` (default `8081`); the shipped compose file pins the container to `8081` and publishes the host range `APP_HOST_PORT`-`APP_HOST_PORT_LAST` (`8081`-`8083`), one port per copy, so `--scale applicant-service=3` works. The team compose publishes no port: everything goes through the Gateway |
| `5433` → `5432` | PostgreSQL | **Host port is 5433 on purpose.** During integration several teammates' databases run on one laptop and 5432 is taken first |

The compose network is named **`student-id-net`** so other teams' stacks and the Gateway can
join it. Inside that network the service is reachable as `http://applicant-service:8081`, and
it reaches its consumers at `http://gateway-service:8080/api/v1/<prefix>` - the Gateway, never
a peer's own address. The one exception is Service Discovery, which it calls directly at
`SERVICE_DISCOVERY_URL` (`http://service-discovery-service:8090` in the team compose): that is
how the Gateway learns where each copy is. Service Discovery records the address the
registration came from, the container's IP on the network.

**Host ports are deliberately non-default (8081, 5433).** If you are writing a gateway or a
compose file, do not assume 8080/5432.

---

## 5. Configuration

Everything comes from the environment, is read once at startup and is validated there.
A misconfiguration fails fast with the offending variable named.

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | — | **yes** | PostgreSQL connection string (pgx format) |
| `APP_PORT` | `8081` | no | HTTP listen port. Must be 1–65535 |
| `APP_ENV` | `local` | no | `local` / `test` / `development` → Gin debug mode. Anything else → Gin release mode. Logs are JSON either way ([§16](#16-observability)) |
| `SERVICE_VERSION` | `dev` | no | Reported by `/health`, `/status`, every log line and the registration. The image sets it via ldflags |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` — anything else fails validation |
| `HTTP_READ_TIMEOUT` | `10s` | no | Server read timeout |
| `HTTP_WRITE_TIMEOUT` | `10s` | no | Server write timeout |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Task timeout: a request running longer is stopped and answered `408 REQUEST_TIMEOUT` (see below). `0` disables it. Times 3.5 it is also the circuit breakers' window and cooldown (17.5 s) |
| `MAX_CONCURRENT_TASKS` | `64` | no | Concurrent task limit for `/api/v1`: a request above it is refused with `429 TOO_MANY_REQUESTS`. Must be ≥ 1. `GET /status` reports it as `max_concurrent_tasks` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `GET /api/v1/dev/slow?ms=` (see below). Keep `false` in shared deployments |
| `SHUTDOWN_TIMEOUT` | `10s` | no | Grace period for in-flight requests on SIGTERM |
| `DB_MAX_CONNS` | `10` | no | pgx pool size. Must be ≥ 1 |
| `DB_CONNECT_TIMEOUT` | `30s` | no | How long to retry the database at boot before giving up |
| `MIGRATE_ON_START` | `true` | no | Apply embedded migrations at startup |
| `SERVICE_TOKEN` | *(empty)* | for delivery | The stack's one `X-Service-Token`, sent on every event push and checked by the Gateway. **Empty switches the relay off**: applicants are still created and their events wait in the outbox |
| `CREDENTIAL_URL` | *(empty)* | for delivery | Gateway base URL of Credential Service, `http://gateway-service:8080/api/v1/credential`. The relay appends `/events`. Empty: that consumer's deliveries stay pending and `/health/ready` says `not_configured` |
| `UNIVERSITY_RECORD_URL` | *(empty)* | for delivery | Same for University Record Service, `http://gateway-service:8080/api/v1/university-record` |
| `EVENT_PUSH_TIMEOUT` | `15s` | no | One push as a whole. Above the Gateway's `10s`, so its `408` comes back as an answer rather than a cut connection. No answer within it counts as a failure for the consumer's circuit breaker |
| `OUTBOX_POLL_INTERVAL` | `500ms` | no | How often the relay looks for deliveries that are due |
| `OUTBOX_BATCH_SIZE` | `50` | no | Deliveries taken per consumer per pass. Must be ≥ 1 |
| `OUTBOX_LEASE` | `15m` | no | How long a claimed batch stays reserved for the copy that claimed it. **Must be at least `OUTBOX_BATCH_SIZE` × `EVENT_PUSH_TIMEOUT`** (12.5 min with the defaults), or startup fails: a shorter lease could run out while the batch is still being pushed. Rows a relay does not get to are handed back at once ([§9.6](#96-several-instances-and-the-circuit-breaker)) |
| `EVENT_RETRY_MAX_BACKOFF` | `30s` | no | Cap on the wait between two attempts at one delivery (1 s, 2 s, 4 s, ... up to this) |
| `REFERENCE_YEAR` | `2026` | no | The calendar year the generator treats as "now". Must be 1900–2999. **Must match across all three applicant-data services** — see [§7.3](#73-admission-year-and-study-year) |
| `GENERATOR_SEED` | `0` | no | `0` = a fresh random sequence per boot. Non-zero = reproducible applicants, **for one instance only**: every copy given the same seed generates the same applicants in lockstep ([§15](#15-scaling-concurrency-and-statefulness)) |
| `SERVICE_DISCOVERY_URL` | *(empty)* | for Lab 3 | Service Discovery's base URL, `http://service-discovery-service:8090` in the team compose. The instance registers there directly, with `SERVICE_TOKEN`, which is then required. **Empty: no registration**, one `sd.disabled` warning at startup (fine for a local run, but the Gateway cannot find the instance) |
| `INSTANCE_ID` | `applicant-<hostname>` | no | The id the instance registers under and logs with. In Docker the hostname is the container id, so every copy has its own. Set it only for an instance outside Docker; **never give scaled copies one value** |
| `INSTANCE_HOST` | *(empty)* | no | Sent as `host` at registration, for an instance outside Docker that Service Discovery cannot reach at the address the registration came from. Empty: no `host` is sent |

**An empty string counts as unset** for every variable, so `OUTBOX_BATCH_SIZE=""` silently
falls back to the default rather than failing. The places this is load-bearing are
`SERVICE_TOKEN` and the consumer URLs, where empty deliberately means "do not push". A consumer
URL that is set must be an `http(s)` URL with a host, or startup fails naming the variable.

**Task timeout (`HTTP_REQUEST_TIMEOUT`).** Every request gets a deadline. When it fires,
in-flight database work is cancelled, the open transaction is rolled back and the service answers
`408 REQUEST_TIMEOUT` - nothing was changed. A transaction is never committed after the deadline,
and a commit that did succeed is never reported as a timeout, so `408` always means "not stored".
The Gateway's own timeout (`10s`) is above it, so this answer reaches the caller.

**Concurrent task limit (`MAX_CONCURRENT_TASKS`).** At most that many requests under `/api/v1` are
in progress at once. One more is refused at once - not queued - with `429 TOO_MANY_REQUESTS` and
`Retry-After: 1`, before any work is done. `/health`, `/health/ready` and `/status` are not
counted, and `GET /status` reports how many slots are taken as `in_flight`.

**Dev endpoint (`DEV_ENDPOINTS=true`).** `GET /api/v1/dev/slow?ms=<0..60000>` does nothing for `ms`
milliseconds and answers `200 { "slept_ms": <ms> }`; it counts as a task. `?ms=6000` answers `408`
after the timeout, and with `MAX_CONCURRENT_TASKS` of them open one more request to `/api/v1`
answers `429` while `/health` still answers `200`. Without the flag the path is `404 NOT_FOUND`.
A bad `ms` (not an integer, or outside `0..60000`) answers `400 VALIDATION_ERROR`.

---

## 6. HTTP API

Conventions, all inherited from the team contract:

- Base path `/api/v1`; resource names are plural nouns.
- JSON fields are `snake_case`; identifiers are UUID strings; timestamps are **ISO 8601 in
  UTC, whole seconds** (`2026-09-10T18:10:00Z` — never a fractional part, never an offset).
- Lists are `?limit=&offset=` and return `{ "items": [], "total": 0 }`.
- Errors are always `{ "error": { "code", "message", "details" } }`, `details` always an
  object (never `null`).

### 6.1 Endpoint summary

| Method | Path | Source | Intended caller | Exposure |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/applicants/next` | **contract** | Server Moderation Session Service | service-to-service |
| `GET` | `/api/v1/applicants/{applicant_id}` | **contract** | Moderation Service, game client | player-safe |
| `POST` | `/api/v1/events` | **contract** | Credential, University Record Service | service-to-service |
| `GET` | `/api/v1/dev/slow?ms=` | dev (`DEV_ENDPOINTS`) | demo / tests | service token at the Gateway |
| `GET` | `/api/v1/applicants` | extension | admin / tests | **not player-safe** |
| `POST` | `/api/v1/applicants` | extension | admin / tests | **not player-safe** |
| `PATCH` | `/api/v1/applicants/{applicant_id}` | extension | admin / tests | **not player-safe** |
| `DELETE` | `/api/v1/applicants/{applicant_id}` | extension | admin / tests | **not player-safe** |
| `GET` | `/health` | infra | orchestrator | internal |
| `GET` | `/health/ready` | infra | orchestrator / LB | internal |
| `GET` | `/status` | infra | Service Discovery (directly, every 10 s) | internal |

"Extension" means **beyond the CPR contract** — added because Lab 1 requires a CRUD service.
See the exposure warning in [§14](#14-gateway-requirements).

### 6.2 `POST /api/v1/applicants/next`

Creates the next applicant for a session: invents both profiles, stores them, queues
`applicant.initialized` for delivery to Credential and University Record, returns the
identifiers.

**Request**

```json
{ "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e", "difficulty": 3 }
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `session_id` | UUID string | yes | Any UUID version is accepted (v1, v4, v7 …) |
| `difficulty` | integer | yes | `1`–`5` inclusive. Higher means more likely to lie, and a better lie |

**`201 Created`**

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "created_at": "2026-09-10T18:10:00Z"
}
```

Only the identifiers come back. Fetch the profile with `GET /api/v1/applicants/{id}`.

**Errors:** `400 VALIDATION_ERROR` (missing/invalid field), `500 DEPENDENCY_UNAVAILABLE`.

> **This endpoint is NOT idempotent.** Two identical requests create two different applicants.
> A gateway, client or service **must not automatically retry it** on timeout — retry produces
> a duplicate applicant and a duplicate `applicant.initialized`. If you need retry safety,
> treat a timeout as "unknown" and reconcile via
> `GET /api/v1/applicants?session_id=…&limit=1` (newest first).

### 6.3 `GET /api/v1/applicants/{applicant_id}`

What the applicant claims about themselves. **Player-safe.**

**`200 OK`** — exactly these eleven keys, always:

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "name": "Ion Popescu",
  "student_id": "FAF24214",
  "email": "ion.popescu@isa.utm.md",
  "major": "FAF",
  "year": 2,
  "university_status": "faf_student",
  "courses": ["POO", "SDA"],
  "role": "student",
  "created_at": "2026-09-10T18:10:00Z"
}
```

`student_id`, `major` and `year` are `null` for people who never studied at the university.
`courses` is always an array, never `null`.

**Errors:** `400 VALIDATION_ERROR` (not a UUID), `404 APPLICANT_NOT_FOUND`.

> `404` here is also the **normal, transient** answer when another service created the
> applicant and the event has not arrived yet. See [§13.1](#131-eventual-consistency-window).

### 6.4 `GET /api/v1/applicants` *(extension)*

| Query param | Type | Default | Rules |
| --- | --- | --- | --- |
| `limit` | integer | `20` | 1–100. **Out of range is rejected, not clamped** |
| `offset` | integer | `0` | ≥ 0 |
| `session_id` | UUID | — | Optional filter |

Returns `{ "items": [ <applicant object> ], "total": <int> }`. Ordered `created_at DESC,
applicant_id DESC`, so paging is stable when several applicants share a timestamp. `total` is
the count of all matching rows, not the page size.

### 6.5 `POST /api/v1/applicants` *(extension)*

Stores an applicant from a claimed profile you supply.

| Field | Required |
| --- | --- |
| `session_id`, `name`, `email`, `university_status`, `role` | **yes** |
| `student_id`, `major`, `year`, `courses` | no (omit or `null`; `courses` defaults to `[]`) |

- `201 Created` with the applicant object and a `Location` header.
- Stored with `difficulty = 1` and `initialized_by = "applicant-service"`; neither is
  configurable through this endpoint, and neither is visible in any response.
- Not idempotent — each call creates a new applicant.
- **Does not publish `applicant.initialized`** — that event carries both profiles, and an
  applicant created this way has no separate truth for University Record Service to build
  records from.
- `422 VALIDATION_ERROR` when the profile describes a person who cannot exist
  ([§8](#8-representation-invariants)); `details.invariant` names the rule.

### 6.6 `PATCH /api/v1/applicants/{applicant_id}` *(extension)*

Partial update of the **claimed** profile only. The actual profile is not reachable through
the API at all.

**Absent vs explicit `null` are different instructions** — `student_id`, `major` and `year`
are legitimately nullable:

```jsonc
{ "name": "Ioan Popescu" }   // year untouched
{ "year": null }             // year cleared
```

The result is re-validated against the same coherence rules, so an applicant cannot be edited
into a state that leaves Credential Service unable to build their documents.

**Errors:** `400` (empty body `{}`, malformed), `404`, `422` (incoherent result).

### 6.7 `DELETE /api/v1/applicants/{applicant_id}` *(extension)*

`204 No Content`, no body. Cascades to the applicant's email reservations — **the address
becomes available again**. Publishes nothing; peers are not told.

Deleting an already-deleted applicant returns `404 APPLICANT_NOT_FOUND`, so the call is
repeatable but not strictly idempotent in its status code.

### 6.7b `POST /api/v1/events`

The consumer side of the contract's event delivery. Credential Service or University Record
Service, having met an applicant first, relays its `applicant.initialized` here through the
Gateway as `POST {gateway}/api/v1/applicant/events` with `X-Service-Token`; the Gateway checks
the token, strips it and forwards the envelope unchanged. This service reads no credential.

**Request body:** the envelope of [§9.2](#92-envelope), with the payload of
[§9.3](#93-published-applicantinitialized).

**Answers** - exactly those of the CPR README "Event delivery", because the producer's relay
keys its behaviour on them:

| HTTP | Body | When | The producer then |
| --- | --- | --- | --- |
| `200` | `{ "event_id": "...", "duplicate": false }` | The applicant was created from `claimed` and the `event_id` recorded, in one transaction, which has committed | Marks the delivery done |
| `200` | `{ "event_id": "...", "duplicate": true }` | That `event_id` had already been applied. Nothing changed - a repeat is the dedup working, not an error | Marks the delivery done |
| `200` | `{ "event_id": "...", "duplicate": false }` | `initialized_by` is `applicant-service`: our own event, which the contract never pushes back. Ignored, nothing stored | Marks the delivery done |
| `422` | `INVALID_EVENT` | The envelope cannot be parsed, has no `event_id`, `event_type`, `producer` or `payload`, names an `event_type` other than `applicant.initialized` or a `version` other than `1`, or its payload fails validation (no `applicant_id`, no `initialized_by`, no claimed `name`, or a row the database refuses). `details.reason` says which | Parks the delivery and logs it - a retry cannot succeed |
| `408` | `REQUEST_TIMEOUT` | The task ran past `HTTP_REQUEST_TIMEOUT`; the transaction was rolled back | Retries later |
| `429` | `TOO_MANY_REQUESTS` | The concurrent task limit is reached | Retries later |
| `500` | `DEPENDENCY_UNAVAILABLE` | PostgreSQL did not answer. Nothing was changed | Retries later |

A pushed event is a task like any other: it sits under `/api/v1`, so the task timeout and the
concurrent task limit apply to it. Through the Gateway, `403 SERVICE_TOKEN_REQUIRED` and
`401 INVALID_SERVICE_TOKEN` are answered by the Gateway before the push reaches this service.

What the event does to the store is in [§9.4](#94-consumed-applicantinitialized).

### 6.8 Health

**`GET /health`** — liveness. **Always `200` while the process is serving.** It deliberately
does not check dependencies: a liveness probe that fails on a dependency restarts a healthy
container because somebody else is having a bad day.

```json
{ "status": "ok", "service": "applicant-service", "version": "3.0.0" }
```

**`GET /health/ready`** — readiness.

```json
{
  "status": "ok",
  "service": "applicant-service",
  "version": "3.0.0",
  "components": {
    "postgres": { "status": "up" },
    "event_relay": { "status": "up" }
  },
  "consumers": {
    "credential": { "status": "configured", "pending": 0, "parked": 0 },
    "university-record": { "status": "configured", "pending": 2, "parked": 0 }
  },
  "pending_events": 2
}
```

| Condition | HTTP | `status` | Where it shows |
| --- | --- | --- | --- |
| Everything configured | `200` | `ok` | |
| **`SERVICE_TOKEN` or every consumer URL unset** | **`200`** | `degraded` | `components.event_relay.status: "disabled"` |
| **A consumer URL unset** | **`200`** | `degraded` | `consumers.<name>.status: "not_configured"` |
| **The Gateway or a consumer not answering** | **`200`** | **`ok`** | `consumers.<name>.pending` keeps climbing |
| **PostgreSQL down** | **`503`** | `unavailable` | `components.postgres` |

`consumers.<name>.pending` is that consumer's backlog: deliveries due or waiting out a retry
backoff. `parked` counts deliveries the consumer refused with `422 INVALID_EVENT`; they are
never retried and somebody has to look at them (`outbox_deliveries.last_error` says why).
`pending_events` is the backlog across consumers. **Both are omitted from the body when the
count cannot be taken**, which is precisely when PostgreSQL is down.

A consumer that does not answer is not a configuration fault, so the status stays `ok` - the
contract expects it, and the outbox is what makes it safe. The number to watch is `pending`:
a count that keeps climbing means the Gateway, or that consumer behind it, has been away for a
while, or does not serve `POST /events` (a `404`, which is retried).

> **Do not remove an instance from the load-balancer pool on `degraded`.** The REST surface is
> fully functional; only the delivery of events is affected, and they wait in the outbox.

**`GET /status`** — this copy's health and load, in the shape every Lab 3 component shares.
Service Discovery polls it directly (not through the Gateway) every 10 s with a 2 s timeout.
No credential; like the health checks it sits outside `/api/v1`, so it is **not counted by the
concurrent task limit and never answers `429`**: a copy at full load reports itself busy instead
of looking broken.

```json
{
  "service": "applicant",
  "instance_id": "applicant-3f4e2a9b1c7d",
  "version": "3.0.0",
  "status": "up",
  "in_flight": 3,
  "max_concurrent_tasks": 64
}
```

| Condition | HTTP | `status` |
| --- | --- | --- |
| PostgreSQL answers a ping within 1 s | `200` | `up` |
| PostgreSQL does not | `503` | `degraded`, same body |

`in_flight` is the number of requests under `/api/v1` holding a slot of the concurrent task
limit right now; Service Discovery divides it by `max_concurrent_tasks` and alerts at 80 %.
The relay and the consumers play no part here: as for readiness, a consumer that is away is
not this copy's fault. Its access-log line is at `debug`, like the health checks'.

### 6.8b What the API deliberately does not expose

None of the following is reachable through any endpoint, and none should be reconstructed
downstream:

| Not exposed | Why it matters to you |
| --- | --- |
| The `actual` profile | The answer key. Only the event carries it |
| `lie_archetype`, `is_honest` | Would make the game trivial |
| `difficulty` | Stored, but never returned |
| `origin` and `initialized_by` | **You cannot tell a generated applicant from an ingested or hand-created one.** See the validation warning in [§8](#8-representation-invariants) |
| `updated_at` | Stored, never returned |

### 6.9 Error codes

| HTTP | `code` | When |
| --- | --- | --- |
| `400` | `VALIDATION_ERROR` | Malformed JSON, missing/invalid field, bad UUID, out-of-range pagination |
| `408` | `REQUEST_TIMEOUT` | The request ran longer than `HTTP_REQUEST_TIMEOUT` and was stopped. `details` empty. **Nothing was changed** |
| `429` | `TOO_MANY_REQUESTS` | `MAX_CONCURRENT_TASKS` requests are already in progress. Header `Retry-After: 1`. `details` empty. **Nothing was changed** |
| `404` | `APPLICANT_NOT_FOUND` | No applicant with that id |
| `404` | `NOT_FOUND` | Unknown route |
| `405` | `METHOD_NOT_ALLOWED` | Known path, wrong method |
| `422` | `VALIDATION_ERROR` | Well-formed, but the profile is not internally coherent. `details.invariant`, `details.side`, `details.reason`. `invariant` is usually an `I1`–`I12` id, but is the literal `"DB"` (with `side: "row"`) when a database constraint rejected the row. The contract reserves `422` for endpoint-specific codes; this one is a divergence, see [§12](#12-divergences-from-the-cpr-contract) |
| `422` | `INVALID_EVENT` | `POST /api/v1/events` only: the event can never be applied by this service. `details.reason`, and `details.event_id` / `details.event_type` when the envelope parsed. See [§6.7b](#67b-post-apiv1events) |
| `500` | `DEPENDENCY_UNAVAILABLE` | PostgreSQL unreachable. A request stopped by the task timeout answers `408`, not this. `details.dependency`. **Nothing was changed** |
| `500` | `INTERNAL_ERROR` | A bug, or a panic (recovered). `details` empty |

Both `400` and `422` use the code `VALIDATION_ERROR`; the status distinguishes "could not parse
this" from "parsed it, and it describes an impossible person". The contract keeps
`VALIDATION_ERROR` for `400` only, so the `422` case needs its own code (for example
`INCOHERENT_PROFILE`) - an open divergence.

---

## 7. Data formats and validation

### 7.1 Shared enumerations

| Field | Allowed values |
| --- | --- |
| `university_status` | `faf_student`, `other_major_student`, `teaching_assistant`, `staff`, `alumni`, `outsider` |
| `role` | `student`, `teacher`, `alumni`, `guest` |
| `difficulty` | integer `1`–`5` |

`role` is **derived from** `university_status` and is not free:

| `university_status` | entitled `role` |
| --- | --- |
| `faf_student`, `other_major_student` | `student` |
| `teaching_assistant`, `staff` | `teacher` |
| `alumni` | `alumni` |
| `outsider` | `guest` |

### 7.2 Student ID — `{MAJOR}{yy}{g}{nn}`

```
FAF 23 3 14   ->  "FAF23314"
 |   |  |  `- nn : 2 digits, index within the group (01-30)
 |   |  `---- g  : 1 digit,  group number (1-4)
 |   `------- yy : 2 digits, admission year mod 100 (23 = admitted 2023)
 `----------- MAJOR : 2-4 uppercase letters, equal to the profile's `major`
```

Regex: `^[A-Z]{2,4}[0-9]{5}$`

- Issued for `faf_student`, `other_major_student`, `teaching_assistant`, `alumni`.
- `null` for `staff` and `outsider`.
- The alphabetic prefix **always equals** `major`.
- **The academic group is derivable from the ID alone:** `FAF23314` → group `FAF-233`, email
  group `faf-233`. The group never travels as a separate field.
- Known majors: `FAF` (Ingineria Software, the flagship), `IA`, `TI`, `SC`.

> **If you parse these IDs, be tolerant.** This service's own parser rejects only malformed
> input, never an implausible cohort. A peer that encodes identifiers slightly differently
> should produce a *flag*, not a hard failure.

### 7.3 Admission year and study year

**These are independent.** Neither is computed from the other. A student admitted in 2025 is a
first-year in the spring of 2026 and a second-year in the autumn of the same calendar year —
both must be representable. The pair is constrained rather than derived:

```
year ∈ { REFERENCE_YEAR − admissionYear , REFERENCE_YEAR − admissionYear + 1 } ∩ [1, 4]
```

With `REFERENCE_YEAR = 2026`:

| Admitted | Possible study years |
| --- | --- |
| 2026 | 1 |
| 2025 | 1, 2 |
| 2024 | 2, 3 |
| 2023 | 3, 4 |
| 2022 | 4 |
| 2021 or earlier | none — no longer a current student |

**A cohort therefore does not pin a single study year.** "The ID contradicts the claimed year"
is a *range* check, not an equality check. A claim outside the window is provably false from
the card alone; a claim inside it can still be false, and only the enrollment list can say so.

**All three applicant-data services must share the same `REFERENCE_YEAR`,** or perfectly
honest applicants will read as liars.

Alumni: `gradYear = REFERENCE_YEAR − k` for `k ∈ 1..5`, `admissionYear = gradYear − 4`,
`year = null`.

### 7.4 Email addresses

| Status | Address | Suffix |
| --- | --- | --- |
| `faf_student`, `other_major_student`, `teaching_assistant` | `first.last@isa.utm.md` | none, unless taken → `first.last2@`, `first.last3@`, … |
| `staff` | `first.last@utm.md` | the same rule |
| `alumni`, `outsider` | `first.last{nn}@gmail.com` (or yahoo/outlook/mail.ru) | always a two-digit suffix |

`first.last` is lower-cased and folded to ASCII: `Ștefan Băț` → `stefan.bat`,
`Ana-Maria Rusu` → `ana-maria.rusu`, `Olga D'Amico` → `olga.damico`.

**The numeric suffix is applied only on collision**, never by default. The contract phrases
the question as "does *any* of the three applicant-data services already hold this address" —
that is answerable locally, because this service's store is the **union** of the applicants it
generated and every applicant ingested from a peer's `applicant.initialized`. Ingested events
register their addresses too, which is what keeps that equivalence true.

Reservation happens inside the same database transaction as the applicant insert, and a unique
index arbitrates concurrent requests, so two people with the same name can never be handed the
same address.

**Only `actual` university addresses are reserved** on the generated path. A liar's fabricated
claimed address is deliberately *not* registered — its absence from the Outlook group lists is
precisely the tell a junior moderator with the `email-groups` scope discovers.

> **The CRUD extensions behave differently.** `POST /api/v1/applicants` and `PATCH` register
> the **claimed** address, because an applicant created by hand has no separate truth. Seeding
> data through them therefore consumes addresses from the shared namespace. Ingested peer
> events register the peer's **actual** address only, and never overwrite an existing entry.

The collision probe is case-insensitive while the reservation key is case-sensitive. Local
parts are always lower-cased, so this is unreachable in practice — but do not rely on the two
being identical if you generate addresses yourself.

### 7.5 Courses

Course codes come from an embedded curriculum keyed by `(major, year)`: 2-4 uppercase letters
(`POO`, `SDA`, `PAD`), with one exception, `LEN1`. A profile's courses
normally belong to that person's own year of their own programme. Properties you can rely on:

- `courses` is **always an array**, never `null`. Empty for `staff`, `alumni` and `outsider`.
- Sorted ascending, no duplicates, at most **5** entries.
- The curriculum is shipped as `internal/generator/catalog/data/courses.json`: 53 entries, the 49
  of the CPR's [`shared/courses.json`](../shared/courses.json) plus `LEN1` ("Limba Engleză I",
  year 1, spring) for each of the four majors. The contract requires a byte-identical copy of the
  CPR file and codes matching `^[A-Z]{2,4}$`; image `3.0.0` still meets neither
  ([§12](#12-divergences-from-the-cpr-contract)). Credential Service ships the same file.
- A separate `fake_courses.json` holds eight codes that exist nowhere (`ELSE-NET`, `QBIT-101`,
  `WEB5`, …). They do not follow the catalog format, so a fabrication can be told apart at a
  glance. University Record should answer `exists: false` for them.

---

## 8. Representation invariants

These are enforced by the generator on every applicant it produces (**in production, not just
in tests**), by the API on every supplied or patched profile, and by `CHECK` constraints in
the database. If you consume applicant data, you may rely on them for the `actual` profile and
for any honest `claimed` profile.

| ID | Invariant |
| --- | --- |
| **I1** | `university_status` and `role` are contract values; `name` is non-empty |
| **I2** | `role` is the one entitled by `university_status` ([§7.1](#71-shared-enumerations)) |
| **I3** | `outsider` and `staff` ⇒ `student_id`, `major`, `year` all `null`, `courses` empty |
| **I4** | `faf_student`, `other_major_student`, `teaching_assistant` ⇒ all three present, `year ∈ 1..4` |
| **I5** | `alumni` ⇒ `student_id` and `major` present, `year` `null`, `courses` empty |
| **I6** | `student_id` matches the format, its prefix equals `major`, its programme is known, group ∈ 1..4, index ∈ 1..30, **and** the cohort/year pair is plausible ([§7.3](#73-admission-year-and-study-year)) |
| **I7** | Email is well formed and its domain matches the status |
| **I8** | Every course belongs to this person's own year of their own programme |
| **I9** | `courses` ≤ 5, sorted, no duplicates |
| **I10** | Honest ⇒ `claimed` and `actual` are identical; lying ⇒ they differ in exactly the fields the lie declares |
| **I11** | The name differs between the two sides only for the name-variation lie |
| **I12** | `courses` is never `null` |

### Which are relaxed, and when — this matters

The `actual` profile is **always** held to every invariant. The `claimed` profile is relaxed
**precisely where the lie lives**:

- **I6's cohort/year check is skipped** whenever the archetype is allowed to change `year`
  or `student_id`. An alumnus claiming current enrolment carries an ID whose cohort
  contradicts their claimed year — that contradiction *is* the tell, not a defect.
- **I8 is skipped** whenever the archetype is allowed to change `courses`.

(The trigger is the archetype's declared permission, not whether it actually changed the
field, so a few archetypes are relaxed slightly more than they strictly need.)

So: **a `claimed` profile produced by this service's generator may legitimately violate I6
and I8**, and nothing else.

> **⚠ Applicants ingested from a peer's event are NOT validated.** `applicant.initialized`
> payloads are stored as received — this service does not police another service's data, and
> the database constraints that would catch it are deliberately relaxed for such rows
> ([§10](#10-what-and-how-it-stores)). An applicant whose `origin` is `event` may therefore
> violate **any** invariant, including I2–I5.
>
> Only three properties hold for *every* row served by the API, whatever its origin:
> `university_status` and `role` are contract enum values (I1), `courses` is a non-`null`
> sorted array (I9's ordering, I12), and `name` is non-empty.
>
> **There is no way to tell the two apart through the API** — `origin` is not exposed. If
> your service needs the stronger guarantee, either validate defensively or only trust
> applicants you know came from `POST /api/v1/applicants/next`.

`POST` and `PATCH` apply the same relaxation: a supplied profile may describe a liar (an
implausible cohort, an invented course) but not structural nonsense (an enrolled student with
no identifier). That is why `422` means "impossible person", not "dishonest person".

### The lie archetypes

Useful if you are building Moderation Service's expected-verdict logic or University Record's
record generation. `P(lie)` by difficulty: `1 → 0.15`, `2 → 0.35`, `3 → 0.55`, `4 → 0.75`,
`5 → 0.90` (never 0, never 1).

| Archetype | Actual is | Diverging fields | Difficulties | The tell |
| --- | --- | --- | --- | --- |
| `honest` | anyone | none | 1–5 | records confirm everything |
| `name_variation` | a student | `name`, `email` | 1–3 | card name ≠ enrollment name |
| `email_mismatch` | a student | `email` | 1–4 | claimed address absent from the group lists |
| `fabricated_course_registration` | a student | `courses` | 1–5 | course does not exist (d1–2) or exists with no registration (d3–5) |
| `year_inflation_naive` | `faf_student` | `year`, `courses` | 1–4 | claimed year impossible for their own cohort |
| `year_inflation_consistent` | `faf_student` | `year`, `student_id`, `courses` | 3–5 | card is self-consistent but the ID is not on the enrollment list |
| `other_major_claims_faf` | `other_major_student` | `major`, `student_id`, `university_status`, `courses` | 2–5 | enrollment shows the real programme |
| `alumni_claims_current_enrollment` | `alumni` | `university_status`, `year`, `role`, `email`, `courses` (+ `student_id` at d4–5) | 2–5 | enrollment status `graduated` |
| `outsider_impersonates_student` | `outsider` | everything except `name` | 2–5 | every record lookup empty |
| `claims_teaching_role` | student / alumni | `university_status`, `role` always; **plus** `email`, `student_id`, `major`, `year`, `courses` in the "claims staff" variant. At difficulty 5 a senior student may claim `teaching_assistant`, where *only* status and role change | 3–5 | absent from the staff / teaching-assistant group |
| `identity_theft` | `outsider` / `other_major_student` | `student_id`, `email`, `major`, `year`, `university_status`, `role`, `courses` — **not `name`** | 4–5 | the stolen ID is on the enrollment list **under a different name** |

> **`identity_theft` victims come from this service's own history** — an earlier applicant in
> the *same session* who is genuinely `faf_student`. It cannot steal from a catalogue, because
> University Record Service only knows people it has received events about. When the pool is
> empty (the first applicants of a shift), the generator degrades to
> `outsider_impersonates_student` rather than inventing an unverifiable identity.

---

## 9. Events

### 9.1 Transport

Direct HTTP push through the Gateway, as the CPR README "Event delivery" defines it. There is
no broker.

- **Producer side.** `POST /applicants/next` writes the applicant and the envelope of its
  `applicant.initialized` to the outbox **in the same transaction**, with one pending delivery
  per consumer. A background relay then pushes the stored bytes, unchanged, to
  `POST {gateway}/api/v1/credential/events` and `POST {gateway}/api/v1/university-record/events`
  with `X-Service-Token` and `Content-Type: application/json`, and records the answer per
  consumer:

  | Answer | The relay |
  | --- | --- |
  | `2xx` | Marks that consumer delivered |
  | `422` | Parks the delivery for that consumer, with the reason, and never retries it |
  | Any other `4xx` (`404` from a consumer that does not serve the endpoint yet, the Gateway's `408`, `429`, `502`), any `5xx`, a timeout, a refused connection | Retries after a backoff that doubles from 1 s and is capped at `EVENT_RETRY_MAX_BACKOFF` (30 s) |

  The two consumers are pushed independently and at the same time: one being down, slow or
  absent never delays the other. Each push carries the `X-Request-ID` of the request that
  created the applicant, stored with the event, so that request can be followed into the
  consumers' logs; an event stored before `3.0.0` gets a fresh id. Each consumer has its own
  circuit breaker ([§9.6](#96-several-instances-and-the-circuit-breaker)).
- **Consumer side.** `POST /api/v1/events` ([§6.7b](#67b-post-apiv1events)), reached as
  `{gateway}/api/v1/applicant/events`, service token only.
- **No ordering guarantee**, and at-least-once delivery ([§9.5](#95-delivery-guarantees)).

### 9.2 Envelope

Common to every event in the system:

```json
{
  "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "applicant.initialized",
  "occurred_at": "2026-09-10T18:10:00Z",
  "producer": "applicant-service",
  "version": 1,
  "payload": { }
}
```

`occurred_at` is UTC truncated to whole seconds.

### 9.3 Published: `applicant.initialized`

Consumed by Credential Service and University Record Service. Sent only when this service was
contacted first.

```json
{
  "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "applicant.initialized",
  "occurred_at": "2026-09-10T18:10:00Z",
  "producer": "applicant-service",
  "version": 1,
  "payload": {
    "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "initialized_by": "applicant-service",
    "difficulty": 3,
    "claimed": {
      "name": "Ion Popescu", "student_id": "FAF24214", "email": "ion.popescu@isa.utm.md",
      "major": "FAF", "year": 2, "university_status": "faf_student",
      "courses": ["POO", "SDA"], "role": "student"
    },
    "actual": {
      "name": "Ion Popescu", "student_id": null, "email": "ion.popescu99@gmail.com",
      "major": null, "year": null, "university_status": "outsider",
      "courses": [], "role": "guest"
    }
  }
}
```

**How to consume it**

- **Build from the right half.** Credential Service builds documents from `claimed` and marks
  as `forged` whatever supports a claim that `actual` contradicts. University Record Service
  builds the university's records from `actual` — an outsider gets no enrollment row at all.
- **Ignore your own.** The contract never pushes an event back to its producer, but drop any
  event whose `initialized_by` equals your own service name all the same.
- **Deduplicate on `event_id`.** Delivery is at-least-once (see [§9.5](#95-delivery-guarantees)).
- **Do not require `actual`.** It is always sent by this service, but a lenient reader is what
  keeps an integration day from being lost to a backlog of parked, perfectly usable events.

### 9.4 Consumed: `applicant.initialized`

Accepted from Credential Service and University Record Service (i.e. any event whose
`initialized_by` is not `applicant-service`). This service creates its own record under the
same `applicant_id` from the `claimed` profile, and registers the `actual` university address
so its own generator will not later hand the same address to someone else.

Handling policy, as `POST /api/v1/events` answers it:

| Situation | Answer |
| --- | --- |
| Unparseable envelope, `event_type` ≠ `applicant.initialized`, `version` ≠ `1` | `422 INVALID_EVENT` - it will never succeed, the producer parks it |
| `initialized_by == "applicant-service"` | `200`, `duplicate: false` - our own, ignored |
| Unknown/empty `initialized_by`, unusable payload | `422 INVALID_EVENT` |
| Already-seen `event_id` | `200`, `duplicate: true` - nothing changes |
| Payload the database refuses (wrong shape for our schema) | `422 INVALID_EVENT` |
| PostgreSQL unavailable, or the task timeout | `500` / `408` - the producer retries later |

**A peer's `difficulty` is silently clamped into 1–5** before storage; an out-of-range value
is not a reason to reject an otherwise usable applicant.

The `event_id` is recorded in `processed_events` **in the same transaction** as the applicant
row, and `200` is answered only after that transaction commits - so a redelivery is a true
no-op rather than a partial repeat, and a `200` that was sent is never for work that was lost.

### 9.5 Delivery guarantees

Publishing uses a **transactional outbox**: the applicant row, the event and one pending
delivery per consumer are written in one database transaction, and the relay pushes from the
outbox afterwards.

| Property | Guarantee |
| --- | --- |
| An applicant exists but no event was ever queued | **Impossible** — same transaction |
| An event is pushed for an applicant that does not exist | **Impossible** — same transaction |
| One consumer being down holds back the other | **Impossible** — delivery state is per consumer, and the two are pushed concurrently |
| The same event pushed more than once to one consumer | **Possible** — a crash between a `2xx` and the bookkeeping update, or a claim whose lease ran out mid-push, sends it again |
| Two copies push the same delivery at the same time | **Impossible** while the claim's lease holds (`OUTBOX_LEASE`, which covers a whole batch); a copy that outlives its lease cannot overwrite the attempts the new holder records |
| An event pushed after a `422` | **Never** — the delivery is parked |
| Ordering | Best-effort (oldest due first); **do not rely on it** |

So: **at-least-once, never at-most-once.** Every consumer must deduplicate on `event_id`.

**Consequences you can build on:** `POST /api/v1/applicants/next` returns `201` whether or not
the Gateway and the consumers are reachable, and each consumer's backlog drains on its own
once it answers `2xx`. `/health/ready` reports `pending` and `parked` per consumer so you can
watch it. Everything image `2.0.0` left waiting for a broker is delivered by the first `2.1.0`
that starts against the same database: migration `0004` opens the deliveries for it.

### 9.6 Several instances and the circuit breaker

Every copy runs a relay over the one shared outbox. What keeps them apart:

- **The claim.** A relay takes a batch with `UPDATE … FOR UPDATE SKIP LOCKED`, which moves the
  rows' `next_attempt_at` out by `OUTBOX_LEASE` and stamps them with a claim token of its own.
  Another copy skips locked rows and finds the claimed ones not due, so it takes different
  rows. A copy that dies mid-batch hands its rows back when the lease runs out.
- **The lease covers the batch.** Pushes of one batch go one after another, so the lease must
  outlast `OUTBOX_BATCH_SIZE` × `EVENT_PUSH_TIMEOUT` (50 × 15 s = 12.5 min); the default is
  15 min and startup refuses less.
- **Only the current claim records a failure.** `attempts`, `next_attempt_at` and parking are
  updated only where the claim token still matches, so a copy whose lease ran out cannot
  overwrite what the copy that took the row over has recorded. A `2xx` is recorded whoever saw
  it: a delivery is a fact.
- **A relay stops at a consumer's first failure.** The rest of that consumer's batch is not
  pushed; its rows are handed back at once, due with the failed one's retry, without counting
  an attempt - not held until the lease runs out.

**Circuit breaker, one per consumer** (CPR README "Circuit breaker"). A failure is no answer
within `EVENT_PUSH_TIMEOUT` (a timeout, a refused or reset connection, a DNS failure) or any
`5xx`, the Gateway's `502` and `503` included. Any `4xx` is an answer and does not count -
`429`, `422` and the Gateway's `408` included - even though the delivery itself is retried.

| State | The relay |
| --- | --- |
| Closed | Claims and pushes as above. **3 failures within 17.5 s** (`HTTP_REQUEST_TIMEOUT` × 3.5) open it: `breaker.opened` at `warn` |
| Open | **Claims nothing for that consumer**: its deliveries stay pending and untouched, for this copy after the cooldown or for another copy whose breaker is closed. `breaker.rejected` at `debug` on every pass |
| Half-open, 17.5 s after opening | `breaker.half_open`, then **one trial push**: a claim of one delivery. Success (any answer that is not a failure) closes it, `breaker.closed`, and the backlog drains; failure opens it again for another 17.5 s |

The breaker only logs and stops calling. This service never tells Service Discovery about it:
it reaches its consumers through the Gateway and cannot name one of their instances, and the
Gateway's own breaker marks failing instances down. The service has no synchronous outbound
call, so the contract's `500 DEPENDENCY_UNAVAILABLE` for an open breaker never arises here: the
relay simply leaves the deliveries pending. Each copy keeps its breakers in memory; that is the
one piece of state per process besides the task limiter and the connection pools, and it
decides only when this copy pushes, never what any request answers.

---

## 10. What and how it stores

Database `applicant_db`, PostgreSQL 16. **No other service may connect to it** — this is the
team's one-database-per-service rule, and it is enforced by the network and credentials, not
by convention.

| Table | Holds |
| --- | --- |
| `applicants` | One row per applicant: both profiles, `session_id`, `difficulty`, `origin`, `initialized_by`, the lie metadata, timestamps |
| `university_emails` | The university email namespace. Primary key is the address itself, which is what arbitrates concurrent allocation. Cascades on applicant delete |
| `processed_events` | Consumed `event_id`s, for idempotency |
| `outbox_events` | The envelope of every event, written with its applicant. `published_at` is set once every consumer has it |
| `outbox_deliveries` | One row per event and consumer: `attempts`, `next_attempt_at`, `delivered_at`, `parked_at`, `last_status`, `last_error`. The relay's unit of work |
| `schema_migrations` | Applied migration versions |
| **`applicants_claimed`** *(view)* | **The only relation the read path touches** |

### The `applicants_claimed` view

It projects `applicant_id`, `session_id` and the eight claimed profile fields plus
`created_at`. It has **no `actual_*` columns and no lie metadata at all**, so even a careless
`SELECT *` cannot return the answer key. A unit test asserts that every player-facing query
goes through it. If you add a read path, go through the view.

### `origin`

Each row records how it came to exist: `generated` (our generator), `event` (ingested from a
peer), `manual` (`POST /api/v1/applicants`). It gates the database constraints, along this
line:

| Applies to every row | Relaxed for `origin = 'event'` |
| --- | --- |
| `university_status` and `role` enums (both profiles), `origin`, `difficulty` 1–5, a non-empty `claimed_name` | Student ID format, study-year range 1–4, major shape, email shape, name length 1–120, and both cross-field coherence rules |

The split is deliberate: the left column is the **shared vocabulary** from the contract's
"Shared values", where an out-of-set value is a genuine contract violation. The right column
encodes **this service's own formatting choices**, and a peer must never have its events
answered `422` merely for spelling a student ID differently.

> This was wrong until migration `0003`: the column-level checks applied to every row, so a
> peer sending the CPR's six-digit `FAF231017` had *every* event rejected and parked — which
> from their side looks like this service silently ignoring them. Fixed and verified end to
> end.

### Deliberate non-constraints

- **No unique index on `claimed_student_id`.** The `identity_theft` archetype produces two
  applicants claiming the same identifier on purpose. Do not add a uniqueness assumption
  downstream.
- **All `actual_*` columns are nullable**, because a peer's event may omit that profile.

### Retention

Nothing is deleted automatically. Applicants, processed event ids and delivered outbox rows
accumulate. For a course project that is fine; for a long-lived deployment, `processed_events`
and the delivered rows of `outbox_events` (cascading to `outbox_deliveries`) are what would
want pruning.

### Migrations

Embedded in the binary and applied at startup under a PostgreSQL **advisory lock**, so
concurrent replicas cannot race: copies that start together on an empty database take turns,
each migration is applied once, and every copy starts. Explicitly **not**
`docker-entrypoint-initdb.d`: those scripts run only against an empty data directory, so with a
persisted volume the second schema change would silently never apply.

`0005` (image `3.0.0`) adds `outbox_events.request_id`, the originating `X-Request-ID` sent
with each push, and `outbox_deliveries.claim_token`, the claim currently holding a delivery.

---

## 11. Use cases and interaction flows

Every call below, event pushes included, passes through the Gateway: the caller sends
`{gateway}/api/v1/<prefix>/...`, and the paths shown are the service's own (see the CPR README
"Gateway").

### 11.1 Server Moderation Session Service — "give me the next applicant"

```
Moderator (client)  →  Session Service:  POST /api/v1/sessions/{id}/applicants/next
Session Service     →  Applicant Service: POST /api/v1/applicants/next
                                          { session_id, difficulty }
Applicant Service   →  Session Service:   201 { applicant_id, session_id, created_at }
Session Service     :  stores applicant_id as the session's current_applicant_id
Applicant Service   →  (async) pushes applicant.initialized to
                       POST {gateway}/api/v1/credential/events and
                       POST {gateway}/api/v1/university-record/events
```

- `difficulty` is the session's own difficulty (derived from player levels).
- **Do not retry on timeout** — see [§6.2](#62-post-apiv1applicantsnext).
- This is the only synchronous call any service makes into Applicant Service that changes
  state.

### 11.2 Game client — "show me the applicant"

```
Client → Applicant Service:  GET /api/v1/applicants/{applicant_id}
Client → Credential Service: GET /api/v1/applicants/{applicant_id}/documents
```

Both may answer `404` for a moment right after creation. The client should retry briefly.

### 11.3 Moderation Service — "check this decision"

All five calls go through the Gateway with `X-Service-Token`, never with the Moderator's token.

```
Moderation → Session Service:          GET /api/v1/sessions/{id}        (current applicant, ruleset_version)
Moderation → Applicant Service:        GET /api/v1/applicants/{id}      ← the claimed profile
Moderation → Credential Service:       GET .../documents/validation     (in parallel)
Moderation → University Record Service:GET .../records                  (in parallel)
Moderation → Server Rules Service:     POST /api/v1/rulesets/{v}/evaluations
```

Applicant Service supplies **the claims only**. Moderation must build its verified facts from
the *records*, not from the claims — checking the claims is how every liar passes. The gap
between what this service returns and what University Record returns is the evidence.

### 11.4 Credential Service — consuming the event

Builds the document bundle from `claimed`. Where `claimed` and `actual` differ, the documents
that support the false claim are the ones to mark `forged`. Honest applicants never get forged
documents, though difficulty may still make some `expired`, `inconsistent` or `incomplete`.

### 11.5 University Record Service — consuming the event

Builds the university's records from `actual` — the truth. An outsider gets no enrollment
record; someone who lies about their year has their real year on record. That asymmetry is
what lets a junior moderator find the lie.

The student ID encodes the group ([§7.2](#72-student-id--majoryygnn)), so
`enrollment.group` and the `email-groups` entry can both be derived without an extra field.

### 11.6 Applicant Service as a *consumer*

If Credential or University Record is contacted first, it pushes the event to
`POST {gateway}/api/v1/applicant/events` and **this** service creates its record from
`claimed` ([§6.7b](#67b-post-apiv1events)). That path is implemented and tested. Today no
service calls their `POST /applicants/next`, but the contract is identical on all three, so
Session Service could switch without any change on its side.

---

## 12. Divergences from the CPR contract

Raise these in the CPR before integration; they are the parts other services must match.

| # | Divergence | Who is affected |
| --- | --- | --- |
| 2 | **`422 VALIDATION_ERROR`** for an incoherent profile. The contract keeps `VALIDATION_ERROR` for `400` and reserves `422` for endpoint-specific codes | Generic clients |
| 3 | **`courses.json` must be the CPR's [`shared/courses.json`](../shared/courses.json)**, byte-identical, and the fake codes must follow `^[A-Z]{2,4}$`. Image `3.0.0` still does not match: its catalog has 53 entries against the CPR's 49 - the same 49 plus `LEN1` ("Limba Engleză I", year 1, spring) for each of the four majors, a code that also breaks the format - and none of its eight fake codes (`ELSE-NET`, `QBIT-101`, `WEB5`, …) follow the format. Credential Service ships the same two files | University Record and Credential Service, Moderation |
| 5 | **Four CRUD endpoints exist beyond the contract** (`GET` list, `POST`, `PATCH`, `DELETE`) | Gateway and auth — see [§14](#14-gateway-requirements) |
| 6 | **`POST /api/v1/applicants` does not produce `applicant.initialized`** | Anyone expecting every applicant to be announced |

Lab 3 (`3.0.0`) follows the team decisions of 2026-10-27 for the status endpoint, logging,
registration and the circuit breaker; issue #71, which writes them into the README contract, was
not merged when this image was built. Two additions on top of them, neither of which changes an
answer: the breaker logs its move to half-open as `breaker.half_open`, and routine heartbeats
are logged at `debug` as `sd.heartbeat`.

---

## 13. Edge cases and failure modes

### 13.1 Eventual consistency window

Right after an applicant is created by **another** service, `GET /api/v1/applicants/{id}`
returns `404 APPLICANT_NOT_FOUND` until the event arrives. This is normal and expected by the
contract. Clients should retry briefly rather than treating it as an error. Typical window is
the relay's poll interval plus one round trip; it is unbounded while the Gateway, or the
service that met the applicant first, is down.

### 13.2 `POST /applicants/next` is not idempotent

Covered in [§6.2](#62-post-apiv1applicantsnext). The single most important thing for a gateway
or retry policy to know about this service.

### 13.3 Duplicate `student_id` is legal

`identity_theft` deliberately produces two applicants claiming the same identifier. Never key
on `claimed.student_id`.

### 13.4 Gateway or consumer outage

- `POST /applicants/next` still returns `201`; the event's deliveries wait in the outbox.
- `/health/ready` stays `200 ok`; `consumers.<name>.pending` rises for the consumer that
  cannot be reached, and only for that one. The other consumer is served all along.
- Peers that are unreachable receive nothing until they are back; their view of applicants
  goes stale. The relay retries with a backoff that doubles up to 30 s, so a consumer that is
  down for a minute sees a handful of attempts rather than hundreds.
- A consumer that answers `404` because it does not serve `POST /events` is treated the
  same: retried until it does.
- After 3 failures within 17.5 s (no answer, or a `5xx` such as the Gateway's `502`/`503`)
  that consumer's circuit breaker opens: the relay stops claiming its deliveries, tries one
  trial push every 17.5 s, and drains the backlog once a trial is answered
  ([§9.6](#96-several-instances-and-the-circuit-breaker)). The other consumer is not affected.
- When the consumer returns, its backlog drains in the order it built up, oldest first, with
  no intervention. Covered by the relay's unit tests against a fake Gateway, and the claim,
  release and migration statements by integration tests against PostgreSQL (run in CI);
  **no automated test** runs the whole stack.

### 13.5 Database outage

- `GET /health` → `200` (liveness is not dependency-aware).
- `GET /health/ready` → `503`.
- Every API call → `500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "postgres"`.
- **Nothing is partially written.** The service recovers on its own when the database returns;
  no restart needed. Confirmed by hand against the running stack, not by an automated test.
- At *startup*, an unreachable database for longer than `DB_CONNECT_TIMEOUT` (30s) exits the
  process non-zero — rely on the orchestrator's restart policy.

### 13.6 Poison events

An event this service cannot read, of a type or version it does not consume, or whose payload
it cannot store is answered `422 INVALID_EVENT` and never retried by the producer. The same
happens in the other direction: a consumer that answers `422` to one of this service's events
gets that delivery parked, with `last_status` and `last_error` kept on its
`outbox_deliveries` row and `parked` counted in `/health/ready`.

**Look at `parked` first if a peer reports that its applicants never appear here, or that
ours never appear there.** The most likely cause is a payload shape one side cannot store —
see the constraint split in [§10](#10-what-and-how-it-stores).

### 13.7 Email namespace exhaustion

After 99 collisions on one `first.last` the request fails with
`500 INTERNAL_ERROR`. Practically unreachable with the shipped name pool; surfacing it beats
looping forever.

### 13.8 A peer mints an address we have not heard about yet

Brief collision window. Local allocation never double-assigns, and on ingest the peer's
address is recorded without being rewritten — their data is theirs to own.

### 13.9 Trailing slash

`GET /api/v1/applicants/` (empty id) is **`301`-redirected to the list endpoint**. A gateway
that normalises or appends trailing slashes can silently turn "fetch one applicant" into
"list all applicants". Preserve paths exactly, or disable redirect-following.

### 13.10 Deleting an applicant frees their email

`DELETE` cascades to `university_emails`, so the address can be reissued to someone else. It
also publishes nothing — peers keep their copy of a deleted applicant.

### 13.11 Lenient request parsing

Unknown JSON fields are ignored, and a missing/incorrect `Content-Type` is still parsed as
JSON. Do not rely on this service to reject a malformed client.

---

## 14. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `applicant`.

### Authentication

Callers authenticate at the Gateway, never here: a player sends `Authorization: Bearer <jwt>`, a
service sends `X-Service-Token`, and the Gateway forwards only `X-Player-Id` (for player calls). The
Gateway enforces, for this service:

| Endpoint | Credential |
| --- | --- |
| `POST /api/v1/applicants/next`, `POST /api/v1/events` | service token only |
| `GET /api/v1/applicants/{id}` | player or service |
| The CRUD extensions, `/health/ready` | service token only (admin) |

Applicant Service does not need `player_id` for any decision, and reads no credential at all - which
is exactly what the contract asks of it. It is therefore safe **only** behind the Gateway, with its
port unpublished.

### Endpoint exposure — read this before routing anything publicly

| Endpoint | Safe for players? | Why |
| --- | --- | --- |
| `GET /api/v1/applicants/{id}` | **Yes** | Claimed profile only. This is what the game shows |
| `POST /api/v1/applicants/next` | **No — service only** | Creates an applicant and an event. A player could spam applicants and desynchronise sessions |
| `POST /api/v1/events` | **No — service only** | A player could inject applicants |
| `GET /api/v1/applicants` | **No — admin only** | Enumerates every applicant across every session. A player could pre-read applicants they have not met |
| `POST`, `PATCH`, `DELETE /api/v1/applicants` | **No — admin only** | A player could edit the applicant they are being judged on |
| `/health`, `/health/ready` | **No — internal** | Leaks dependency state and version |

The Gateway policy above follows from this table: `GET /api/v1/applicants/{id}` for authenticated
players; `POST /api/v1/applicants/next` and `POST /api/v1/events` for the service token only;
everything else behind the service token or not routed at all.

### Retries

**Do not auto-retry `POST /api/v1/applicants/next`.** It is not idempotent — and neither is
`POST /api/v1/applicants`.

Everything else is safe to retry. `GET` and `PATCH` are idempotent; `DELETE` is repeatable but
answers `404` the second time, so a retry after a lost response reports failure for work that
actually succeeded.

There is no `Idempotency-Key` support.

### Timeouts

| Layer | Value |
| --- | --- |
| Server read / write | 10s |
| Server idle (keep-alive) | 60s |
| Task timeout (`HTTP_REQUEST_TIMEOUT`) | 5s → `408 REQUEST_TIMEOUT`, transaction rolled back |
| Concurrent task limit (`MAX_CONCURRENT_TASKS`) | 64 → `429 TOO_MANY_REQUESTS` + `Retry-After: 1` |
| Graceful shutdown | 10s |

The Gateway's timeout (`10s`) is above 5s, so the service's own error body reaches the client.

### Headers

- **`X-Request-ID`** — echoed if you send it, generated (UUID v4) if you do not, and returned
  on every response. It appears in every log line. **Propagate it** from the gateway for
  cross-service tracing.
- `Content-Type: application/json; charset=utf-8` on all JSON responses.
- `Location` on `201` from `POST /api/v1/applicants`.
- **No CORS headers, and `OPTIONS` returns `405`** on every path. A browser preflight is
  therefore actively rejected, not merely unanswered — the gateway must terminate CORS
  itself and answer preflights on the service's behalf.
- **No `Retry-After`, no rate-limit headers, no `ETag`/`Cache-Control`.** Responses are
  dynamic; treat them as uncacheable.

### Body limits

**None configured.** The gateway should cap request bodies; the largest legitimate body here
is a few hundred bytes.

### Health probes

| Probe | Endpoint | Failure means |
| --- | --- | --- |
| Liveness / restart | `GET /health` | The process is wedged. Restart |
| Readiness / pool membership | `GET /health/ready` | `503` = PostgreSQL unreachable. Remove from pool |
| Service Discovery health polling | `GET /status` | `503 degraded` = PostgreSQL unreachable; a timeout or any non-`200` is a failed check. Load = `in_flight` / `max_concurrent_tasks` |

**Treat `200` + `status: "degraded"` as healthy.** It means only the event relay is not fully
configured, and the REST surface is fully functional.

### Graceful shutdown

On `SIGTERM` / `SIGINT` the service first stops its heartbeat and deregisters from Service
Discovery (`DELETE /api/v1/instances/{instance_id}`, 2 s at most, never blocking the rest), so
the Gateway stops routing to it; then it stops accepting HTTP, drains in-flight requests (up to
`SHUTDOWN_TIMEOUT`), stops the relay, and closes the database pool — in that order, so a push
whose answer is being recorded is never cut off from the database. Rows a relay had claimed but
not pushed are handed back; a push interrupted by shutdown is simply made again later. Give the
orchestrator a termination grace period **above** `SHUTDOWN_TIMEOUT` + 2 s.

---

## 15. Scaling, concurrency and statefulness

**The HTTP layer is stateless.** No sessions, no sticky routing, no in-memory per-client state.
Round-robin freely - which is what the Gateway does in Lab 3: every copy registers itself with
Service Discovery as `applicant-<hostname>`, and the Gateway spreads requests over the copies
it lists. The team compose runs 2 copies (`deploy.replicas: 2`) against the one database;
`docker compose up -d --scale applicant-service=3` adds a third. Every answer is the same
whichever copy gives it.

Replicas are safe:

| Concern | Behaviour |
| --- | --- |
| Migrations | Guarded by a PostgreSQL advisory lock — concurrent starts serialise, each migration is applied once, and every copy starts (none exits) |
| Seeding | None: the catalogues are embedded in the binary, there is nothing to seed |
| `POST /api/v1/events` | Stateless like every endpoint; the `event_id` dedup is an `INSERT … ON CONFLICT DO NOTHING` on `processed_events` in the same transaction as the applicant, so two replicas receiving the same event apply it once |
| Outbox relay | A claim is `UPDATE … FOR UPDATE SKIP LOCKED` with a lease covering the whole batch and a claim token — a second relay takes different rows rather than waiting or double-pushing, a relay that dies mid-push hands its rows back when the lease runs out, and one that outlived its lease cannot overwrite the attempts of the copy that took over ([§9.6](#96-several-instances-and-the-circuit-breaker)) |
| Circuit breakers | One per consumer in each copy, in memory. They decide when that copy pushes, never what a request answers |
| Email allocation | University addresses are arbitrated by a unique index, correct across processes |
| Generator RNG | Mutex-protected; race-clean under `-race` |
| Registration | Each copy registers, heartbeats every 5 s and deregisters on shutdown on its own; Service Discovery forgets a copy it has not heard from for 15 s |

> **⚠ Do not run multiple replicas with a fixed non-zero `GENERATOR_SEED`.** Each replica seeds
> its own generator, so they would produce *identical* applicants in lockstep. Use
> `GENERATOR_SEED=0` (the default) in any multi-replica deployment; reserve a fixed seed for
> single-instance demos and reproducible debugging.

**Connection budget:** each replica opens up to `DB_MAX_CONNS` (10) PostgreSQL connections, and
the relay keeps one outgoing HTTP connection per consumer alive. Three copies use at most 30 of
PostgreSQL's default 100 `max_connections`; keep `replicas × DB_MAX_CONNS` under it.

**Personal addresses are drawn, not reserved.** A university address is unique across all
copies (the unique index above). The personal address of an alumnus or an outsider is drawn
from 40 first names × 40 last names × 4 domains × a two-digit suffix, 633,600 combinations, and
is not reserved, so two applicants can share one: about a 1 % chance after 100 such applicants,
about 50 % after 1,000. It is the same with one copy or three, and this service treats a
personal address as plain profile data, never as a key.

**Cost per applicant:** one `POST /applicants/next` performs roughly — one victim-pool query,
one or more email reservation attempts, one applicant insert, one outbox insert and one
delivery insert per consumer, all in a single transaction, plus two HTTP pushes from the
relay afterwards. It is cheap; the generator itself does no I/O.

---

## 16. Observability

**Logs** are one JSON object per line on stdout, in the shape every Lab 3 component shares,
whatever `APP_ENV` says. Level from `LOG_LEVEL`. Every line carries:

| Field | Value |
| --- | --- |
| `time` | ISO 8601 UTC with milliseconds, `2026-10-27T12:00:00.123Z` |
| `level` | `debug`, `info`, `warn`, `error` |
| `service` | `applicant` |
| `instance_id` | `applicant-<hostname>` - which copy wrote it |
| `version` | the image version |
| `event` | a stable name, below |
| `msg` | a human sentence |
| `request_id` | on every line written while handling a request, and on the relay's lines for a push |

```json
{"time":"2026-10-27T12:00:00.123Z","level":"info","msg":"request","service":"applicant","instance_id":"applicant-3f4e2a9b1c7d","version":"3.0.0","event":"http.request","method":"POST","path":"/api/v1/applicants/next","status":201,"duration_ms":42,"client_ip":"172.18.0.9","request_id":"9d2d…"}
```

**`X-Request-ID`** is read from the request or generated (uuid4), echoed on the response,
printed as `request_id`, stored with the event in the outbox and sent with every push of it.

| `event` | Level | Fields | When |
| --- | --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*` and `/status` | `method`, `path`, `status`, `duration_ms` (integer), `client_ip`, `player_id` when `X-Player-Id` is present | Once per request |
| `http.error` | `warn` for a `4xx`, `error` with `stack` for a `5xx` or a panic | `status`, `code`, `error` | Every error answered, `404`, `405`, `408`, `422` and `429` included |
| `event.received` | `info` | `event_id`, `event_type`, `producer`, `duplicate` | A pushed event applied, or recognised as a repeat |
| `outbound.call` | `info` | `target` (the consumer's prefix), `method`, `path`, `status` (`0` = no answer), `duration_ms` | Every push |
| `event.pushed` | `info` delivered, `warn` to retry | `event_id`, `event_type`, `consumer`, `status`, `attempt`, `next_attempt_at` and `error` when it will be retried | Every push |
| `event.parked` | `error` | the same, with the consumer's reason | A consumer answered `422` — somebody has to look |
| `breaker.opened` / `breaker.half_open` / `breaker.closed` | `warn` / `info` / `info` | `target`, `failures`, `window_s` (17.5), `retry_at` when opened | Every move of a consumer's circuit breaker |
| `breaker.rejected` | `debug` | `target`, `state`, `failures`, `window_s` | A relay pass skipped an open breaker's consumer |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` | `info` / `warn` / `info` | `instance_id`, `status`, `error` when failed | The first registration and the first after a failure / a failed heartbeat / shutdown |
| `sd.heartbeat` / `sd.disabled` | `debug` / `warn` | `instance_id` | A routine heartbeat / no `SERVICE_DISCOVERY_URL` |
| `startup` / `shutdown` | `info` | version, instance id, port and the configuration, without secrets | Start and stop |
| `applicant.created` / `.updated` / `.deleted` | `info` | `applicant_id`, `session_id`, `origin`, `event_id` for one created from an event | Every change to an applicant |
| `config`, `db`, `relay`, `generator.retry`, `generator.fallback` | as fits | | Configuration gaps, database connection and migrations, outbox bookkeeping errors, generator edge cases (`generator.fallback` is a bug) |

**Never logged:** `X-Service-Token`, the database URL (it carries a password), request or
response bodies, and anything of an applicant's profile - lines name applicants by
`applicant_id` only.

**No metrics endpoint and no tracing.** There is no `/metrics`, no Prometheus, no OpenTelemetry.
`/health/ready` exposes `pending` and `parked` per consumer, which are the most useful numbers
to scrape if you are building a dashboard.

---

## 17. Known gaps — deliberately not implemented

Do not assume these exist:

- **Authentication and authorisation** — none in the service, by design: the Gateway checks every credential ([§14](#14-gateway-requirements)).
- **CORS** — no headers emitted.
- **Rate limiting** — none.
- **Request body size limits** — none.
- **Metrics / tracing** — none.
- **TLS** — plain HTTP; terminate upstream.
- **Idempotency keys** — none.
- **Pagination cursors** — offset-based only.
- **Soft delete / audit trail** — `DELETE` is permanent and silent.
- **Data retention / pruning** — nothing is cleaned up automatically.
- **A seed script** — generation catalogues are embedded via `go:embed`; there is no database
  seeding step and none is needed.
- **`GET /api/v1/applicants/{id}/actual`** — and there never will be. The truth leaves this
  service only inside the event.

---

## 18. Recipes for testing against it

The recipes use `BASE=http://localhost:8081`, the service's own port, which is published only during
Lab 2 development. Through the Gateway, replace `$BASE/api/v1/` with
`http://localhost:8080/api/v1/applicant/` and send the credential the route needs (`X-Service-Token`
for `POST /applicants/next`).

### Create and read an applicant

```bash
BASE=http://localhost:8081
SESSION=3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e

ID=$(curl -sS -X POST $BASE/api/v1/applicants/next \
      -H 'Content-Type: application/json' \
      -d "{\"session_id\":\"$SESSION\",\"difficulty\":3}" | jq -r .applicant_id)

curl -sS $BASE/api/v1/applicants/$ID | jq
```

### Watch what a peer service would receive

Play a consumer: point the relay at a listener of your own, then create an applicant and watch
the envelope arrive as `POST /api/v1/credential/events` with the service token.

```bash
# A throwaway "Gateway" that prints every push and answers 200.
python3 - <<'EOF' &
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        print(self.path, self.headers.get('X-Service-Token'))
        print(self.rfile.read(int(self.headers['Content-Length'])).decode())
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(b'{"event_id":"x","duplicate":false}')
HTTPServer(('0.0.0.0', 9999), H).serve_forever()
EOF

# In .env: CREDENTIAL_URL=http://host.docker.internal:9999/api/v1/credential (Docker Desktop),
# then restart the service and create an applicant.
```

With the real stack, the same thing is visible in the Gateway's access log and in
`consumers.credential.pending` on `/health/ready` dropping back to `0`.

### Pretend to be Credential Service

Push an event and watch this service create its own record. Push the **same `event_id`**
twice to prove idempotency: the second answer is `200` with `"duplicate": true`.

```bash
curl -sS -X POST $BASE/api/v1/events -H 'Content-Type: application/json' -d '{
  "event_id":"aaaa1111-2222-4333-8444-555566667777","event_type":"applicant.initialized",
  "occurred_at":"2026-09-13T11:00:00Z","producer":"credential-service","version":1,
  "payload":{"applicant_id":"7c1e4a90-1111-4222-8333-444455556666",
    "session_id":"3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e","initialized_by":"credential-service","difficulty":2,
    "claimed":{"name":"Ana Rusu","student_id":"FAF24214","email":"ana.rusu@isa.utm.md","major":"FAF","year":2,
      "university_status":"faf_student","courses":["POO","SDA"],"role":"student"},
    "actual":{"name":"Ana Rusu","student_id":"FAF24214","email":"ana.rusu@isa.utm.md","major":"FAF","year":2,
      "university_status":"faf_student","courses":["POO","SDA"],"role":"student"}}}' | jq

curl -sS $BASE/api/v1/applicants/7c1e4a90-1111-4222-8333-444455556666 | jq
```

Through the Gateway the same call is `POST $GW/api/v1/applicant/events` with
`-H "X-Service-Token: $TOKEN"`. A `"version": 2` envelope answers `422 INVALID_EVENT`.

### Reproducible applicants for a demo

Set `GENERATOR_SEED` to any non-zero value and the same sequence of applicants is produced on
every boot. Single instance only ([§15](#15-scaling-concurrency-and-statefulness)).

### Run the full API suite

```bash
newman run api/postman/applicant-service.postman_collection.json \
       -e api/postman/applicant-service.postman_environment.json
```

18 requests, 39 assertions, covering both contract endpoints, all four CRUD extensions and
every error status.

### Verify the truth never leaks

```bash
curl -sS $BASE/api/v1/applicants/$ID | grep -Eio 'actual|lie_archetype|is_honest' \
  && echo "LEAK" || echo "clean"
```

---

*Applicant Service is owned by Iacovlev Maxim. The full service documentation, including how
it is built internally, is in [README.md](../applicant-service/README.md).*
