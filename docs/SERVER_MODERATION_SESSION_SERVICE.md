# Server Moderation Session Service - Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway. Where the implementation diverges from the CPR
> contract, the divergence is called out explicitly in [§8](#8-divergences-from-the-cpr-contract).

---

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Running it](#3-running-it)
4. [Configuration](#4-configuration)
5. [HTTP API](#5-http-api)
6. [Events](#6-events)
7. [The session lifecycle and the rules this service owns](#7-the-session-lifecycle-and-the-rules-this-service-owns)
8. [Divergences from the CPR contract](#8-divergences-from-the-cpr-contract)
9. [Edge cases](#9-edge-cases)
10. [Gateway requirements](#10-gateway-requirements)
11. [Mocking strategy (grade 9) and testing recipes](#11-mocking-strategy-grade-9-and-testing-recipes)
12. [Several instances (Lab 3)](#12-several-instances-lab-3)
13. [Message Broker, logs and metrics (Lab 4)](#13-message-broker-logs-and-metrics-lab-4)

---

## 1. What this service is

Server Moderation Session Service owns the moderation shift itself: who is in it, who moderates it,
which University Record categories each Junior Moderator may read, which ruleset version the shift
runs under, which applicant is currently being judged, and the score, penalties and counters the
shift accumulates.

It is the busiest service in the system by connection count. It calls three services, is called by
two, publishes two events and consumes one.

### Boundary

- **Owns:** `session_id`, session status, the membership and each player's role, the record-category
  scope of every Junior Moderator, shift difficulty, `ruleset_version`, `current_applicant_id`,
  `applications_processed`, `score`, `penalties`, and the start/end timestamps. Also the decision
  log it accumulates and the per-player XP and disciplinary outcome it computes when a shift ends.
- **Does not own:** applicant data, and **not the admission decision** - it only tracks that a
  decision is in progress and records the outcome Moderation Service reports. It does not own player
  identity, XP totals or levels either; it snapshots a username and level from Player Service when
  someone joins, and Player Service remains the source of truth.
- **Calls:** Player Service (`GET /players/{player_id}`), Server Rules Service
  (`GET /rulesets/current?difficulty={n}`), Applicant Service (`POST /applicants/next`) - from
  `4.0.0` as requests through the Message Broker, to `requests.player`, `requests.server-rules`,
  `requests.applicant`.
- **Is called by:** Moderation Service (`GET /sessions/{session_id}`, before recording every
  decision) and the game client - from `4.0.0` delivered by the broker on `requests.session`.
- **Produces:** `session.started`, `session.ended`, published to the broker topics
  `events.session.started`, `events.session.ended`. **Receives:** `decision.recorded`, from its
  subscription to `events.decision.recorded`. See [§13](#13-message-broker-logs-and-metrics-lab-4).

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Go 1.26 / Gin |
| **Container port** | `8080` (not published in the team stack; a random host port in the service's own compose) |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/session/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres plus each of the three dependencies as `stub` or `not_probed`, with its circuit breaker state). `GET /status` for Service Discovery, called directly - see [§12](#12-several-instances-lab-3) |
| **Database** | PostgreSQL 17, `session_db` (own container, host port `5438`). Schema applied at startup by GORM `AutoMigrate`, under a PostgreSQL advisory lock together with the seed. **No Redis** - see [§8](#8-divergences-from-the-cpr-contract) |
| **Service Discovery** | Registers as `session`, instance id `session-<hostname>`, port `8080`; heartbeat every 5 s, `DELETE` on graceful shutdown - see [§12](#12-several-instances-lab-3) |
| **Circuit breakers** | `4.0.0`: two, both on the broker - `call` (the three synchronous calls) and `relay` (the publishes). Lab 3 had six (three per peer, three per consumer) - see [§12](#12-several-instances-lab-3) |
| **Message Broker** | `4.0.0`: one gRPC connection to `MESSAGE_BROKER_URL` for the calls, the publishes and the `Subscribe` stream (topic `events.decision.recorded`, queue `requests.session`) - see [§13](#13-message-broker-logs-and-metrics-lab-4) |
| **Logs** | One JSON object per line on stdout in the format of CPR README "Logging", and the same lines in the rotating `LOG_FILE`, read back by `GET /logs` (`4.0.0`) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (`4.0.0`) |
| **Events** | `4.0.0`: produced events are published from the outbox to the broker, one delivery row per event; `decision.recorded` arrives on the broker subscription and is settled with `Ack`. `POST /api/v1/events` is removed - see [§6](#6-events) |
| **Caller identity** | `X-Player-Id`, set by the Gateway after it validated the player's JWT, and carried in the headers of a broker request; the service validates no player token. The service token travels as gRPC metadata to the broker |
| **Task limits** | `HTTP_REQUEST_TIMEOUT` (`5s`) → `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (`50`) → `429 TOO_MANY_REQUESTS` + `Retry-After`. `/health`, `/health/ready` and `/status` are exempt |
| **Docker image** | `dimapos/server-moderation-session-service:4.0.0` (also `:latest`), public on Docker Hub, `linux/amd64` + `linux/arm64`, published by GitHub Actions on merge to `main` |
| **Producer name** | `server-moderation-session-service` - the value in the `producer` member of every event it publishes |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`; `details` is always an object, never `null` |
| **Timestamps** | ISO-8601, UTC |
| **Identifiers** | UUID v4 strings |
| **Architecture** | Layered: `domain` (entities, the session rules, sentinel errors, event wire types), `clients` (the three outbound clients, through the broker, + their stubs), `broker` (the broker connection: publish, request, subscription), `brokerpb` (the broker's proto and stubs), `relay` (publishes the outbox to the broker), `metrics`, `repository` (interfaces; `postgres` on GORM, `memory` fake for tests), `service` (use cases), `httpapi` (router, middleware, handlers), `seed`, `logging` |

---

## 3. Running it

### From the published image (recommended for teammates)

`POSTGRES_PASSWORD` is the only variable with no default. Everything else has a working one, the
schema is applied at startup, and an empty database is seeded with three sessions.

```bash
docker network create student-id-net   # once
docker run -d --name session-postgres --network student-id-net \
  -e POSTGRES_USER=session_user -e POSTGRES_PASSWORD=change_me -e POSTGRES_DB=session_db \
  -v session_pgdata:/var/lib/postgresql/data -p 5438:5432 postgres:17-alpine

docker run -d --name session-service --network student-id-net -p 8088:8080 \
  -e POSTGRES_HOST=session-postgres -e POSTGRES_PASSWORD=change_me \
  dimapos/server-moderation-session-service:4.0.0
```

Simpler: the root [`docker-compose.yml`](../docker-compose.yml) already carries both blocks.

### Wired to the real Player, Server Rules and Applicant Service

From `4.0.0` one variable reaches all of them, through the Message Broker:

```bash
-e MESSAGE_BROKER_URL=message-broker-service:8071 \
-e SERVICE_TOKEN=<the stack's SERVICE_TOKEN>
```

The root compose file sets these. Without `MESSAGE_BROKER_URL` the three dependencies are the
built-in stubs and the relay publishes nothing. The five `*_SERVICE_URL` variables of Lab 2-3 are
gone.

### From source (development)

```bash
git clone <this service's repository> && cd server-moderation-session-service
cp .env.example .env          # then set POSTGRES_PASSWORD
docker network create student-id-net
make up                       # build the image and start app + postgres
make up-local                 # or: postgres in docker, the service from source
make check                    # gofmt, go vet, go test
```

---

## 4. Configuration

Every setting is one environment variable. A variable that is set but unusable fails the boot with a
message naming it, rather than silently falling back - and one boot reports every bad variable at
once.

| Variable | Default | Meaning |
| --- | --- | --- |
| `APP_PORT` | `8080` | Port inside the container. The team convention is 8080 for every service |
| `APP_ENV` | `local` (`docker` in the image) | `local` \| `docker` \| `production`. Anything but `local` puts Gin in release mode and the logs in JSON. The image sets `docker`, so it always logs JSON |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `SERVICE_VERSION` | the image's `VERSION` | Reported by `GET /health`; overrides the version stamped into the image at build time |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` / `SHUTDOWN_TIMEOUT` | `10s` / `10s` / `15s` | |
| `POSTGRES_HOST` / `PORT` / `USER` / `DB` / `SSLMODE` | `localhost` / `5432` / `session_user` / `session_db` / `disable` | |
| **`POSTGRES_PASSWORD`** | **none** | **Required.** The service refuses to start without it |
| `DB_MAX_OPEN_CONNS` / `DB_MAX_IDLE_CONNS` / `DB_CONN_MAX_LIFETIME` | `25` / `5` / `30m` | Connection pool |
| `DB_AUTO_MIGRATE` | `true` | Applies the schema at startup |
| `MESSAGE_BROKER_URL` | `""` | `4.0.0`. The broker's gRPC `host:port`, no scheme (team stack: `message-broker-service:8071`). Empty selects the three built-in stubs, the relay publishes nothing (deliveries stay pending) and nothing arrives from the broker. Replaces `PLAYER_SERVICE_URL`, `RULES_SERVICE_URL`, `APPLICANT_SERVICE_URL`, `UNIVERSITY_RECORD_SERVICE_URL`, `DISCORD_DMS_SERVICE_URL` |
| `SERVICE_TOKEN` | - | The stack's token: gRPC metadata `x-service-token` on every broker call, `X-Service-Token` to Service Discovery, and the token `GET /logs` accepts. **Required** as soon as `MESSAGE_BROKER_URL` or `SERVICE_DISCOVERY_URL` is set |
| `DEPENDENCY_TIMEOUT` | `3s` | The `timeout_ms` of every broker request, and the bound of every publish. Must be below `HTTP_REQUEST_TIMEOUT` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout; reached = `408 REQUEST_TIMEOUT`. Must be below `HTTP_WRITE_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `50` | Concurrent task limit; reached = `429 TOO_MANY_REQUESTS` with `Retry-After: 1` |
| `RELAY_INTERVAL` | `1s` | How often the relay looks for deliveries that are due |
| `RELAY_BATCH` | `50` | The most deliveries one relay pass publishes; also sizes the claim lease (`RELAY_BATCH` x `DEPENDENCY_TIMEOUT` + 5 s) |
| `MAX_PLAYERS_PER_SESSION` | `5` | The contract's cap: 1 Moderator + up to 4 Junior Moderators |
| `SCORE_PER_CORRECT` | `10` | Multiplied by the difficulty on a correct decision |
| `XP_BASE` | `20` | What every player earns for working the shift at all |
| `MODERATOR_MULTIPLIER` | `1.25` | Scales the Moderator's XP |
| `WARNING_PENALTY_THRESHOLD` | `25` | Penalty share above which a player is warned |
| `SEED_ON_START` | `true` | Seeds three sessions, but only when the table is empty |
| `ENABLE_DEV_ENDPOINTS` | `true` | Mounts `GET /api/v1/dev/slow?ms=` |
| `SERVICE_DISCOVERY_URL` | `""` | Service Discovery to register with, directly (team stack: `http://service-discovery-service:8090`). Empty = no registration and one warning line at startup |
| `INSTANCE_ID` | `session-<hostname>` | This instance's id in the registry, `/status`, the relay's claims and every log line |
| `INSTANCE_HOST` | `""` | Sent as `host` at registration, for a run outside Docker; otherwise Service Discovery uses the request's source address |
| `LOG_FILE` | `/var/log/session/session.jsonl` | `4.0.0`. The copy of the log lines `GET /logs` reads; the image creates the directory for its non-root user. Empty = stdout only, `GET /logs` answers `503` |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | `4.0.0`. Rotation of the log file |

Two switches matter in a shared stack. `SEED_ON_START` is harmless - it is a no-op once the table
has rows. `ENABLE_DEV_ENDPOINTS` mounts an endpoint that only waits, to demonstrate the `408` and the
`429`; the Gateway forwards `/dev/*` only with the service token.

---

## 5. HTTP API

All paths are under `/api/v1`; callers reach them through the Gateway as
`{gateway}/api/v1/session/...`.

**Contract.** The Gateway validates the player's `Authorization: Bearer <jwt>`, removes it, and
forwards the player id as `X-Player-Id`. Requests that act for "the calling player" read that header
and nothing else; a request without it answers `401 UNAUTHENTICATED`.


### 5.1 Contract endpoints

| Method | Path | Identity | Body | Success |
| --- | --- | --- | --- | --- |
| `POST` | `/sessions` | required | *(empty)* | `201` session object, `status: lobby` |
| `POST` | `/sessions/{session_id}/players` | required | *(empty)* | `200` session object |
| `POST` | `/sessions/{session_id}/start` | required | `{ "moderator_id": "<uuid>" }` | `200` session object, `status: active` |
| `POST` | `/sessions/{session_id}/applicants/next` | required | *(empty)* | `201` `{ session_id, current_applicant_id, applications_processed }` |
| `POST` | `/sessions/{session_id}/end` | required | *(empty)* | `200` the end result (below) |
| `GET` | `/sessions/{session_id}` | **not** required | - | `200` session object |

`GET /sessions/{session_id}` takes no identity on purpose: its main caller is Moderation Service,
not a person. It answers in **every** state - lobby and ended included - because Moderation reads
`status`, `moderator_id`, `current_applicant_id` and `ruleset_version` off it to decide whether a
decision is allowed at all.

**The session object.** Sixteen members, exactly as the contract publishes them:

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "status": "active",
  "created_by": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "players": [
    { "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11", "username": "dima_mod", "level": 4 },
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "username": "maxim_jr", "level": 2 },
    { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "username": "vlad_jr", "level": 3 }
  ],
  "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "junior_moderators": [
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] },
    { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "record_scopes": ["email-groups", "fcim-logs"] }
  ],
  "difficulty": 3,
  "ruleset_version": 7,
  "current_applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "current_applicant_decided": false,
  "applications_processed": 5,
  "score": 40,
  "penalties": 10,
  "created_at": "2026-09-10T18:00:00Z",
  "started_at": "2026-09-10T18:05:00Z",
  "ended_at": null
}
```

In the lobby, `moderator_id`, `ruleset_version` and `current_applicant_id` are **`null`** (not a nil
UUID, not zero), `junior_moderators` is `[]`, and `started_at` / `ended_at` are `null`.

`username` and `level` are a **snapshot** taken from Player Service when that player joined. They are
not refreshed: the contract's own rule reads the level "when they create or join a session", and
re-reading them on every request would make a read of this service depend on another service being
up. For a live value, call Player Service.

**The end result** is the session.ended payload plus `status`, which is exactly how the contract
defines the relationship:

```json
{
  "status": "ended",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "score": 40, "penalties": 10, "applications_processed": 6,
  "players": [
    { "player_id": "8c1f...0f11", "role": "moderator", "xp_delta": 30,
      "disciplinary_actions": [ { "type": "warning", "reason": "..." } ] },
    { "player_id": "b2d4...8d10", "role": "junior_moderator", "xp_delta": 40,
      "disciplinary_actions": [] }
  ],
  "ended_at": "2026-09-10T18:45:00Z"
}
```

`disciplinary_actions` is always an array, never `null`.

### 5.2 Extension endpoints (beyond contract - Lab 1 CRUD requirement)

None of these are in the CPR contract. Nothing else in the system calls them; they exist so a client
and a grader can work with sessions without already knowing an id, and so the events this service
produces and their delivery can be inspected.

| Method | Path | Identity | Notes |
| --- | --- | --- | --- |
| `GET` | `/sessions?status=&limit=&offset=` | no | `{ items, total }`, newest first. `status` filters by `lobby` \| `active` \| `ended` |
| `DELETE` | `/sessions/{session_id}` | required | `204`. Creator only, lobby only |
| `DELETE` | `/sessions/{session_id}/players/{player_id}` | required | `204`. Leave a lobby. The creator leaving deletes the session |
| `GET` | `/sessions/{session_id}/decisions?limit=&offset=` | no | The decision log, newest first |
| `GET` | `/sessions/{session_id}/events?limit=&offset=` | no | The outbox, **oldest first** - the order they happened in |
| `GET` | `/sessions/{session_id}/deliveries` | no | `{ items, total }`: per event (from `4.0.0` one row each, consumer `message-broker`), `status` (`pending` \| `delivered` \| `parked`), `attempts`, `next_attempt_at`, `last_error`, `delivered_at` |
| `GET` | `/dev/slow?ms=` | no | Flag-gated. Waits `ms` (at most `60000`); demonstrates `408` and `429` |

A session that started cannot be deleted: a shift that ran is history, and other services hold
copies of it.

Pagination defaults to `limit=20` and caps at `100`, everywhere.

### 5.3 Error codes

The eleven the contract lists for this service, plus the contract's shared codes.

| Code | Status | When |
| --- | --- | --- |
| `SESSION_NOT_FOUND` | 404 | No session has that id |
| `PLAYER_NOT_FOUND` | 404 | Propagated verbatim from Player Service |
| `PLAYER_ALREADY_IN_SESSION` | 409 | The player is in a lobby or an active session already |
| `SESSION_NOT_IN_LOBBY` | 409 | Joining, leaving or deleting a session that has started |
| `SESSION_FULL` | 409 | `MAX_PLAYERS_PER_SESSION` reached |
| `SESSION_NOT_ACTIVE` | 409 | Asking for an applicant, ending, or applying a decision to a session that is not running |
| `NOT_ENOUGH_PLAYERS` | 409 | Starting with fewer than two |
| `CURRENT_APPLICANT_NOT_DECIDED` | 409 | Asking for the next applicant before the current one is judged |
| `NOT_SESSION_CREATOR` | 403 | Starting, deleting, or removing somebody else |
| `NOT_MODERATOR` | 403 | Asking for an applicant or ending, as anyone but the Moderator |
| `MODERATOR_NOT_IN_SESSION` | 422 | `moderator_id` is not one of the session's players |
| `VALIDATION_ERROR` | 400 | Anything malformed: a body that is not JSON or misses a field, a path id that is not a UUID, a bad query parameter. `details` names it |
| `UNAUTHENTICATED` | 401 | A route that acts for a player got no usable `X-Player-Id` |
| `DEPENDENCY_UNAVAILABLE` | 500 | One of the three services did not answer: the broker did not answer, answered `503` (no instance) or `408` (no reply in time), or the peer answered something the contract does not name. `details.dependency` names it. **Nothing was changed** |
| `REQUEST_TIMEOUT` | 408 | The task timeout was reached; the transaction was rolled back |
| `TOO_MANY_REQUESTS` | 429 | The concurrent task limit was reached, with `Retry-After` |
| `PLAYER_NOT_IN_SESSION` | 404 | Beyond contract: leaving a lobby the player is not in |
| `NOT_FOUND` / `METHOD_NOT_ALLOWED` / `INTERNAL_ERROR` | 404 / 405 / 500 | Routing and unexpected failures |
| `SERVICE_TOKEN_REQUIRED` / `INVALID_SERVICE_TOKEN` | 403 / 401 | `GET /logs` only (`4.0.0`): no `X-Service-Token` / a wrong one |
| `LOGS_UNAVAILABLE` | 503 | `GET /logs` only: no log file |

`INVALID_EVENT` (`422`) is gone with `POST /api/v1/events` in `4.0.0`; its cases are now the
`PERMANENT` outcome of [§6](#6-events).

---

## 6. Events

From `4.0.0` events travel through the Message Broker: produced events are published from the outbox
to their topic, `events.<event_type>`, and the broker fans each out to every subscribed service;
`decision.recorded` arrives on this instance's subscription to `events.decision.recorded`. The
README's "Event delivery" section still describes the Lab 3 push through the Gateway until the Lab 4
contract (#105) merges - see [§8](#8-divergences-from-the-cpr-contract). `POST /api/v1/events` is
removed.

The **outbox**: Every published event is written to the `outbox_events` table
**inside the same database transaction as the state change that produced it**, together with one
pending row in `outbox_deliveries` for the broker (consumer `message-broker`; one per consumer
before `4.0.0`), so an event can never exist without the state it announces, nor the reverse. `GET /sessions/{id}/events` returns those rows rendered as full
envelopes, `GET /sessions/{id}/deliveries` their delivery state.

### Published

Both carry the shared envelope, with `producer: "server-moderation-session-service"` and
`version: 1`.

**`session.started`** - topic `events.session.started`; consumed by University Record Service (which learns each junior's scopes) and
Discord DMs Service (which learns the membership so it can scope its channels).

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "junior_moderators": [
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] },
    { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "record_scopes": ["email-groups", "fcim-logs"] }
  ],
  "ruleset_version": 7,
  "started_at": "2026-09-10T18:05:00Z"
}
```

**`session.ended`** - topic `events.session.ended`; consumed by Player Service, Discord DMs Service and University Record Service.
The payload is the `POST /sessions/{id}/end` response **without `status`**. In this implementation
that is not a promise, it is a fact of the code: the response type embeds the payload type, so the
two cannot drift.

### Consumed

**`decision.recorded`**, published by Moderation Service. Applying it:

- inserts the decision into this session's log, keyed by the `decision_id` Moderation minted;
- adds `SCORE_PER_CORRECT * difficulty` to `score` when `is_correct` is true, and nothing when not;
- adds `penalty` to `penalties`;
- increments `applications_processed` by one;
- sets `current_applicant_decided = true`, releasing the Moderator to ask for the next applicant.

### Delivery guarantees

The contract requires every consumer to dedupe by `event_id`, because an event may be delivered more
than once. This service does, in two layers, both inside one transaction:

1. `processed_events` claims the `event_id` with `ON CONFLICT DO NOTHING`. Affecting no rows means
   the event has been seen, and the transaction stops there.
2. `session_decisions` is keyed by `decision_id`. So even a redelivery under a *fresh* `event_id`
   cannot count the same decision twice.

A replay is a **success**, not an error: it is acked `OK`, and logged `event.received` with
`"duplicate": true` so the deduplication can be seen firing.

### The relay (producer side)

Every `RELAY_INTERVAL` the relay claims the pending deliveries that are due and publishes each
envelope, unchanged, with gRPC `Publish` to `events.<event_type>`, carrying the `X-Request-ID` of the
request that produced the event as `request_id`. Each `Publish` is bounded by `DEPENDENCY_TIMEOUT`.
Every instance runs a relay; how they share the work is in [§12](#12-several-instances-lab-3):

| The broker | Delivery becomes |
| --- | --- |
| Accepts the publish | `delivered` |
| Refuses the event as invalid (`INVALID_ARGUMENT`) | `parked`, logged as an error; never retried |
| Anything else (unreachable, a deadline, `RESOURCE_EXHAUSTED` for a full queue, `UNAVAILABLE`, a refused token) | stays `pending`, retried after 1 s, 2 s, 4 s … capped at 30 s |

Without `MESSAGE_BROKER_URL` nothing is published and the deliveries stay `pending`. Seeded sessions
get no delivery rows, so a fresh boot never publishes fixture history. Deliveries still pending for
the Lab 3 consumers (`player-service`, `university-record-service`, `discord-dms-service`) on a
`3.0.0` database are not converted: every service moves to `4.0.0` together.

### `decision.recorded` (consumer side)

Settled with the broker's `Ack` (`4.0.0`; it replaced `POST /api/v1/events`):

| Situation | `Ack` | The broker |
| --- | --- | --- |
| Applied | `OK` | done |
| An `event_id` already applied | `OK`, nothing changes | done |
| A decision for a session that has already ended | `OK`, nothing changes, logged `event.dropped` - see [§9](#9-edge-cases) | done |
| Unparseable envelope, an `event_type` other than `decision.recorded`, a `version` other than `1`, an invalid payload, or an unknown session (the old `422 INVALID_EVENT`) | `PERMANENT`, the reason (at most 200 characters, never the body) | dead-letters it |
| The database fails, or the task timeout is reached | `RETRY` | delivers it again later |
| The instance dies before acking | none | delivers it again after its ack timeout, to another instance |

---

## 7. The session lifecycle and the rules this service owns

```
            POST /sessions
                  |
                  v
             [ lobby ] <---- POST /sessions/{id}/players
                  |
                  |  POST /sessions/{id}/start
                  |    - creator only, >= 2 players, moderator_id in players
                  |    - difficulty = round(mean level), clamped 1..5
                  |    - Server Rules answers, or nothing happens at all
                  |    - roles assigned, record categories split
                  |    - session.started written
                  v
             [ active ] <---- decision.recorded  (score, penalties, counters)
                  |      <---- POST /sessions/{id}/applicants/next
                  |
                  |  POST /sessions/{id}/end
                  |    - moderator only
                  |    - results and disciplinary actions computed and frozen
                  |    - session.ended written
                  v
             [ ended ]
```

### Difficulty

`round(mean(player levels))`, clamped to 1..5, computed from the **membership under lock** at the
moment the shift starts. Player Service's own level rule is `xp/400 + 1` capped at 10; this service
reads `level` from the API and never recomputes it.

### The record-category split

The four categories - `enrollment`, `email-groups`, `courses`, `fcim-logs` - are dealt round-robin to
the Junior Moderators. The Moderator gets none. Four juniors take one each, three juniors leave one
holding two, two juniors take two each, one junior takes all four.

The contract says "with 3 juniors one of them gets two" without saying *which*. This service settles
it by dealing the fixed category order to juniors **sorted by id**, so the same membership always
produces the same split - which University Record can rely on and a test can assert.

### Scoring and XP

The contract delegates all of this ("Session decides how XP and disciplinary actions are
calculated"), so every number here is this service's own and all four are configurable.

| When | Effect |
| --- | --- |
| A correct decision | `score += SCORE_PER_CORRECT (10) * difficulty` |
| Any decision | `penalties += penalty`, `applications_processed += 1` |

At the end, per player:

```
share        = score / max(applications_processed, 1)
penaltyShare = penalties / player_count
xp_delta     = XP_BASE (20) + share - penaltyShare
                 ... then * MODERATOR_MULTIPLIER (1.25) for the Moderator, rounded
```

So the team shares the credit for the applications it got through and the cost of the penalties it
collected. A bad shift **can** leave a player with a negative `xp_delta`. That is deliberate and
Player Service handles it: it clamps a player's *total* XP at zero rather than rejecting the event.

A player whose penalty share exceeds `WARNING_PENALTY_THRESHOLD` (25) receives a `warning`, whose
reason names the penalty total and the number of incorrect decisions. `warning` is the only type this
service issues; the contract defines no enum and shows no other value.

---

## 8. Divergences from the CPR contract

1. **No Redis.** The contract's Databases table gives this service `session_db` **and**
   `session_cache` (PostgreSQL + Redis), with live shift state in Redis "because it is read on every
   action and must be fast". Everything lives in PostgreSQL here. The Redis rationale is a
   performance argument that does not apply at this scale, and a second store is a second failure
   mode and a cache-invalidation policy to get wrong. Adding it later changes no API.

2. **The scoring formula is this service's own invention.** The contract defines none. See
   [§7](#7-the-session-lifecycle-and-the-rules-this-service-owns).

3. **The three-junior scope tie-break is this service's own.** The contract fixes the shape of the
   split but not who gets the extra category.

4. **Seven endpoints beyond the contract**, all labelled as such in [§5.2](#52-extension-endpoints-beyond-contract---lab-1-crud-requirement). They exist for the Lab 1 CRUD
   requirement and to make the outbox and its delivery inspectable. Nothing else in the system calls them.

5. **A `decision.recorded` for a session that has already ended is acknowledged** (`Ack OK`,
   nothing changes) rather than refused. The contract does not say; a refusal would only
   dead-letter it, and the contract already drops an applicant still undecided when the shift ends.

6. **`username` and `level` in the session object are a snapshot**, taken when the player joined and
   never refreshed. See [§5.1](#51-contract-endpoints).

7. **Ahead of the README contract (Lab 4).** `4.0.0` follows the Lab 4 brief (#115) while the Lab 4
   contract (#105) is not merged: the README still describes calls and event pushes through the
   Gateway and `POST /api/v1/events`. The broker's names (topics `events.<event_type>`, queues
   `requests.<service>`, the `Ack` outcomes, `x-service-token` as metadata), the `topics` of the
   Service Discovery registration and the two broker breakers follow the broker's and Service
   Discovery's code. `internal/brokerpb/broker.proto` is a copy of the broker repository's, itself a
   copy of the CPR's `shared/broker.proto` that #105 adds.
   *Who this affects:* Moderation `3.0.0`, whose push of `decision.recorded` now gets `404` (until
   #120); the services still on `3.0.0` that Session calls (Server Rules #118, Applicant #116), whose
   requests the broker answers `503`, so `start` and `next applicant` answer
   `500 DEPENDENCY_UNAVAILABLE` until they move to the broker.

---

## 9. Edge cases

- **Server Rules does not answer when a shift starts.** The contract says the session "stays in the
  lobby", and it does: Server Rules is called *before* the transaction opens, so no write has
  happened by the time that call can fail. Nothing is assigned, no event is written, and the caller
  gets `500 DEPENDENCY_UNAVAILABLE`.
- **Applicant Service does not answer.** Same shape: the call happens first, and
  `current_applicant_id` is untouched.
- **Asking for an applicant right after a decision.** May answer
  `409 CURRENT_APPLICANT_NOT_DECIDED`. This is documented behaviour, not a bug - this service learns
  about decisions through `decision.recorded`, which can arrive a moment after the Moderator already
  saw Moderation Service's reply. The client waits briefly and retries.
- **The first applicant of a shift.** Has no predecessor, so the "must be decided" rule does not
  apply to it.
- **The shift ends with an applicant still undecided.** That applicant is dropped and does not count.
  This needs no code: `applications_processed` only ever moves when a `decision.recorded` arrives.
- **A decision arrives after the shift ended.** Acked `OK` and nothing changes. Not hypothetical - Moderation Service does not wait for the Moderator.
- **A peer call is never retried.** One attempt, bounded by `DEPENDENCY_TIMEOUT`: `POST
  /applicants/next` is not idempotent, and a second attempt would also eat the task's time budget.
  The broker does not repeat a request either.
- **Ending twice.** The second answers `409 SESSION_NOT_ACTIVE`. The results are frozen in
  `session_results`, so the event stays reproducible.
- **The creator leaves the lobby.** The session is deleted: nobody would be left who is allowed to
  start it.
- **Two clients press start at once.** The session row is locked (`SELECT ... FOR UPDATE`) and the
  rules re-run against the locked membership, so exactly one succeeds and exactly one
  `session.started` is written.
- **A player already in a session.** `409 PLAYER_ALREADY_IN_SESSION`, counting lobbies and active
  sessions only. A player whose last shift is over is free to start another.
- **A negative `penalty` in an event.** Rejected as a validation error: it would credit the session
  for a mistake.

---

## 10. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `session`:

- Forwards to container port `8080`. Health pair at `/health` and `/health/ready`, reached as
  `{gateway}/api/v1/session/health`.
- `/health` never consults a dependency, so a database blip does not cause a restart loop.
  `/health/ready` returns `503` and a `degraded` status when one is down, naming which.
- **Identity:** validate the player's JWT, remove `Authorization`, **strip any client-sent
  `X-Player-Id`** and set it from the token's `sub`. This service trusts `X-Player-Id` blindly, so a
  Gateway that forwarded a client's own value would let anyone act as anyone.
- `GET /sessions/{id}` accepts a player or the service token (Moderation calls it); `/dev/*` only
  the service token. `POST /events` is removed in `4.0.0`; `GET /logs` and `GET /metrics` are not
  Gateway routes.
- **Lab 4 (#110):** the Gateway hands client requests to the broker's `requests.session`; Moderation's
  `GET /sessions/{id}` reaches this service through the broker, not the Gateway.
- `X-Request-Id` is honoured inbound and echoed outbound, so one player action can be followed
  through the logs of every service that handled it.
- Every response, including 404s, 405s and panics, uses the shared error envelope.
- The service shuts down gracefully on `SIGTERM`, which is what `docker stop` sends.

---

## 11. Mocking strategy (grade 9) and testing recipes

> **Direct port.** The first two recipes run the service alone, on its stubs, with its port
> published (`docker run -p 8088:8080 -e SEED_ON_START=false ...`; the team compose does not publish
> it), and send `X-Player-Id` themselves, as the Gateway would. `SEED_ON_START=false` because the
> seeded active session already holds the three players they use. Through the Gateway, replace
> `localhost:8088/api/v1/` with `localhost:8080/api/v1/session/`, send `Authorization: Bearer` with
> a JWT from `POST /api/v1/player/auth/login` instead of `X-Player-Id` (the Gateway discards a
> client-sent one), and send `X-Service-Token` on service-only and `/dev/*` routes - as the last
> recipe does.

Every cross-service dependency has a real client written against the contract **and** an in-process
stub with the same interface. From `4.0.0` the real clients send their requests through the broker,
and which one runs is decided by whether `MESSAGE_BROKER_URL` is set - a runtime switch, not a build
flag.

| Dependency | Stub behaviour |
| --- | --- |
| Player Service | Answers for the six players Player Service seeds, with the levels its own XP curve produces, and `404 PLAYER_NOT_FOUND` for anyone else - so this service's own 404 path is reachable without it |
| Server Rules | Returns version `7` and the four rules the contract prints in its example, so a stubbed session reproduces the contract's published session object |
| Applicant Service | Mints a fresh applicant id per call |

### Recipe: a whole shift, with nothing else running

```bash
M=8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11   # dima_mod,  level 4
A=b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10   # maxim_jr,  level 2
B=c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21   # vlad_jr,   level 3

S=$(curl -sS -X POST localhost:8088/api/v1/sessions \
      -H "X-Player-Id: $M" | jq -r .session_id)
curl -sS -X POST localhost:8088/api/v1/sessions/$S/players -H "X-Player-Id: $A" >/dev/null
curl -sS -X POST localhost:8088/api/v1/sessions/$S/players -H "X-Player-Id: $B" >/dev/null

curl -sS -X POST localhost:8088/api/v1/sessions/$S/start -H "X-Player-Id: $M" \
  -H 'Content-Type: application/json' -d "{\"moderator_id\":\"$M\"}" | jq '.difficulty, .ruleset_version'

# 3   <- round(mean(4, 2, 3)), the contract's own example
# 7   <- from Server Rules
```

Or in one command: `./scripts/seed.sh`.

### Recipe: prove a decision is applied only once

With the broker's command-line client (`scripts/smoke.py` in `message-broker-service`, run where it
reaches the broker's gRPC port, with `SERVICE_TOKEN` set), on a stack where this service is
subscribed:

```bash
E=$(uuidgen | tr 'A-Z' 'a-z'); D=$(uuidgen | tr 'A-Z' 'a-z')
P="{\"decision_id\":\"$D\",\"session_id\":\"$S\",\"applicant_id\":\"$(uuidgen | tr 'A-Z' 'a-z')\",
    \"moderator_id\":\"$M\",\"action\":\"accept\",\"is_correct\":true,\"penalty\":0}"

python -m scripts.smoke publish --topic events.decision.recorded --event-id $E --producer moderation-service --payload "$P"
# one instance logs event.received, duplicate false; the broker logs broker.acked
python -m scripts.smoke publish --topic events.decision.recorded --event-id $E --producer moderation-service --payload "$P"
# event.received, duplicate true, acked

curl -sS localhost:8088/api/v1/sessions/$S | jq '.score, .applications_processed'
# 30   1   <- moved once
```

### Recipe: the end-to-end path across both of Dev's services

On a stack with the broker, Player `4.0.0` and this service, the Moderator of the seeded active
session ends it, and the relay publishes `session.ended` within `RELAY_INTERVAL`; Player applies it
from its own subscription:

```bash
S=3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e   # the seeded active session, dima_mod is its Moderator
M=8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11

curl -sS -X POST localhost:8088/api/v1/sessions/$S/end -H "X-Player-Id: $M" | jq .

curl -sS localhost:8088/api/v1/sessions/$S/deliveries | jq '.items[] | {consumer, status, last_error}'
# message-broker: delivered

curl -sS <player instance>:8080/api/v1/players/$M | jq .
# the XP, the shift count and the level have moved (checked live: xp 1250 -> 1283, shifts 12 -> 13)
```

### Postman

[`postman/server-moderation-session-service.postman_collection.json`](../postman/server-moderation-session-service.postman_collection.json).
`GET /status`, `GET /logs` and `GET /metrics` are sent to the instance directly, through
`session_direct_url`, because the Gateway does not route them. Postman cannot send the broker's gRPC
calls, so `decision.recorded` is published with `smoke.py` (above).
Every request name carries the status code it expects, so the collection can be checked mechanically.
It goes through the Gateway: `base_url` is `http://localhost:8080/api/v1` (Session routes under
`/session`, login under `/player`) and `service_token` must equal `SERVICE_TOKEN` in `.env`. The
`auth` folder registers four fresh players through Player Service and stores their ids and tokens,
so the run does not depend on the seed (the seeded `dima_mod`, `maxim_jr` and `vlad_jr` are in the
seeded active session) or on the other collections; the cleanup folder deletes them. Run the folders in order - the flow folder captures the `session_id` into a
collection variable, and the cleanup folder is destructive.

### Test suite

`make test` runs the unit tests: they drive the real service and router against an in-memory
repository and the stub clients, so they need neither a database nor any other service.
`make test-db` adds a throwaway PostgreSQL container for the repository tests. `make check` runs
gofmt, go vet and the unit tests together.

---

## 12. Several instances (Lab 3)

From `3.0.0` the service runs as 2-3 copies behind the Gateway's round-robin, all on one `session_db`.

### `GET /status`

At the root, next to `/health`; no credential, outside the concurrent task limit and not counted in
`in_flight`. Service Discovery calls it directly every 10 s.

```json
// 200, or 503 with "status": "degraded" when the PostgreSQL ping (1 s) fails
{ "service": "session", "instance_id": "session-3f4e2a9b1c7d", "version": "4.0.0",
  "status": "up", "in_flight": 3, "max_concurrent_tasks": 50 }
```

Only the database makes it `degraded`: a peer that does not answer is a per-request `500`, not an
outage of this instance, and neither is the broker being away (`4.0.0`; `/health/ready` reports it).
`in_flight` counts the requests delivered by the broker too, since they run through the same limit. `/health` keeps `"service": "server-moderation-session-service"`, which is also
the events' `producer`; the Lab 3 name `session` is used in `/status`, the logs and the registration.

### Registration with Service Discovery

- `PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}` with `X-Service-Token` and
  `{"service_name": "session", "port": 8080, "version": "4.0.0", "topics": {"publishes":
  ["events.session.started", "events.session.ended"], "subscribes": ["events.decision.recorded"]}}`
  (`host` added when `INSTANCE_HOST` is set; `topics` from `4.0.0`), sent right after the HTTP
  listener is up and then every 5 s as the heartbeat.
- `sd.registered` on the first success; a failure logs `sd.heartbeat_failed` (`warn`) and is retried on
  the next tick. The instance keeps serving either way.
- On SIGTERM/SIGINT (`4.0.0`): the broker subscription stops first and its deliveries in progress
  are settled, then the relay stops, then `DELETE` the same path (2 s timeout, `sd.deregistered`),
  then the HTTP server drains. Every call to Service Discovery has a 2 s timeout.

### Logging

One JSON object per line on stdout. Every line has `time` (UTC, milliseconds, `Z`), `level`
(lowercase), `service` (`session`), `instance_id`, `version`, `event` and `msg`; lines written while
handling a request, and the relay's lines for an event, add `request_id`.

| `event` | Level | Extra fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status`, `/logs` and `/metrics` | `method`, `path`, `status`, `duration_ms` (integer), `client_ip`, `player_id` when `X-Player-Id` is set |
| `http.error` | `info`; `error` with `stack` for a panic or an unexpected `500` (logged once) | `status`, `code`, `error` |
| `outbound.call` | `info` | `4.0.0`: a request - `target` (`player`, `server-rules`, `applicant`), `method`, `path`, `status` (`0` = the broker did not answer), `duration_ms`, `target_instance`; a publish - `target` `message-broker`, `method` `Publish`, `path` the topic, `ok`, `duration_ms` |
| `event.published` | `info`; `warn` when it will be retried | `4.0.0` (was `event.pushed`): `event_id`, `event_type`, `topic`, `attempt`, `next_attempt_at` and `reason` on a retry |
| `event.parked` | `error` | the same, plus `reason` |
| `event.received` | `info` | `event_id`, `event_type`, `producer`, `duplicate`; from `4.0.0` also `message_id`, `queue`, `attempt` |
| `event.dropped` / `event.retry` / `event.rejected` | `warn` | as `event.received`, plus `session_id` or `reason` (`4.0.0`) |
| `broker.subscribed` / `broker.subscribe_failed` / `broker.stream_ended` / `broker.disabled` | `info` / `warn` | `topics`, `max_concurrent_tasks`; `error`, `retry_in_ms` when failed (`4.0.0`) |
| `broker.request` | `info`; `warn` as `broker.reply_failed` | `message_id`, `correlation_id`, `method`, `path` (no query), `caller`, `status`, `duration_ms` (`4.0.0`) |
| `broker.ack_failed` | `warn` | `message_id`, `error` (`4.0.0`) |
| `relay.started` / `relay.idle` | `info` / `warn` | the topics, interval and lease; `relay.idle` without a broker (`4.0.0`) |
| `logs.file_unavailable` | `warn` | `path`, `error`, once at startup (`4.0.0`) |
| `breaker.opened` / `breaker.closed` / `breaker.rejected` | `warn` / `info` / `warn` | `target`, `via` (`call` or `relay`), `failures`, `window_s` |
| `session.created` / `.joined` / `.started` / `.next_applicant` / `.ended` | `info` | `session_id` and `player_id`, `moderator_id`, `applicant_id`, or the final score |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` / `sd.disabled` | `info` / `warn` | `error` when failed |
| `relay.claim_lost` | `warn` | a delivery whose lease ran out before its outcome was recorded |
| `startup` / `shutdown` | `info` | address, port, timeouts, limits, pool size, breaker window, Service Discovery URL, broker URL, log file - no secrets |

Never logged: `Authorization`, `X-Service-Token`, request or response bodies.

### The outbox relay in several copies

- **Claim.** Each pass, for the one consumer `message-broker` (`4.0.0`; per consumer before), one statement claims up to `RELAY_BATCH` due deliveries:
  `UPDATE outbox_deliveries SET claimed_by = <instance>, next_attempt_at = now + lease WHERE
  (event_id, consumer) IN (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING ...`. Two relays claiming at
  once get disjoint rows, and a claimed row is not due for anyone else until the lease runs out.
- **Lease** = `RELAY_BATCH` x `DEPENDENCY_TIMEOUT` + 5 s (155 s with the defaults). Publishes are sequential, so the lease covers a whole batch and cannot run out mid-batch. A relay
  that dies holding claims delays those deliveries by up to the lease. (The Lab 3 brief proposed
  `2 x DEPENDENCY_TIMEOUT + 5 s`, which a full batch would outlive.)
- **Updates** (`delivered`, `parked`, rescheduled) apply only while the instance still holds the
  claim and the delivery is pending; `attempts` is incremented in SQL. A lost claim changes nothing
  and logs `relay.claim_lost`.
- **Request id.** The `X-Request-ID` of the request that produced the event is stored on the outbox
  row (`outbox_events.request_id`) and sent with the publish; a new one is generated when it is empty.

### Circuit breakers

From `4.0.0` the one target is the broker:

| Breaker | Calls |
| --- | --- |
| `message-broker` / `call` | the requests to Player (`GET /players/{id}`: create, join), Server Rules (`GET /rulesets/current`: start) and Applicant (`POST /applicants/next`) |
| `message-broker` / `relay` | the relay's `Publish` |

- **Failure:** only the broker not answering - a gRPC error, a deadline, a refused connection; for the
  relay also a publish refused for a reason a retry may fix. **A reply is an answer**: a peer's `5xx`,
  the broker's `503` (no instance) and `408` (no reply in time) map to `500 DEPENDENCY_UNAVAILABLE`
  but never trip the breaker, because the broker keeps a breaker per peer instance, and counting them
  here would let one dead peer block the calls to the others (checked live: five `503` replies for
  Server Rules left it closed).
- **Trip:** 3 failures within `HTTP_REQUEST_TIMEOUT` x 3.5 = 17.5 s. **Open:** a synchronous call
  answers `500 DEPENDENCY_UNAVAILABLE` with `details.dependency` (`player-service`, ...) without
  calling, logged `breaker.rejected`; the relay claims nothing, so the deliveries stay pending and
  untouched (deliveries already claimed when it opens mid-batch are released, due at once).
- **Recovery:** after a 17.5 s cooldown one trial call goes through; success closes the breaker,
  failure opens it again. Every transition is logged.
- A breaker only logs and fails fast; it never calls Service Discovery.

### What else makes several copies safe

- **No per-process state decides an answer.** Every read and write goes to `session_db`; the only
  per-process state is the concurrent task limit, the connection pool and the breakers (which only
  decide whether a peer is called).
- **Startup.** Migrations and the seed run under a PostgreSQL advisory lock (taken once for each) on
  a dedicated connection; the seed re-counts under the lock and inserts with `ON CONFLICT DO NOTHING`,
  so a copy that lost the race starts normally. Before `3.0.0` the second copy exited.
- **One player, one open session.** Create and Join take `pg_advisory_xact_lock(hashtext(player_id))`
  and re-check the player's open session inside the transaction, so two concurrent requests for one
  player on two instances cannot both succeed. (No constraint can say this: the open status is on
  `sessions`, the membership on `session_players`.)
- **`decision.recorded` reaching two copies** is applied once: `processed_events` with
  `ON CONFLICT DO NOTHING` in the same transaction, and `session_decisions` keyed by `decision_id`.
- **Connection budget.** `DB_MAX_OPEN_CONNS` is `25` per copy: 3 copies use at most 75 of
  PostgreSQL's default 100 `max_connections`.

---

## 13. Message Broker, logs and metrics (Lab 4)

From `4.0.0`.

### The connection

One gRPC connection to `MESSAGE_BROKER_URL`, with the metadata `x-service-token: SERVICE_TOKEN` on
every call, carries three things:

- **Publish** (the relay): `session.started` and `session.ended` to `events.<event_type>`, the
  envelope unchanged - see [§6](#6-events).
- **Request** (the three clients): `requests.player`, `requests.server-rules`, `requests.applicant`,
  with the peer's own path (`/api/v1/players/{id}`), `timeout_ms` = `DEPENDENCY_TIMEOUT`,
  `X-Request-ID`, `caller: session` and no credential in the headers. The peer's answer comes back as
  a reply; the broker's own outcomes (`503` no instance, `408` no reply in time) too.
- **Subscribe** (one stream per instance): `service: "session"`, `instance_id: INSTANCE_ID`,
  `topics: ["events.decision.recorded"]`, `max_concurrent_tasks: MAX_CONCURRENT_TASKS`; the broker
  attaches `requests.session`. A stream that cannot be opened or ends is opened again with backoff
  (0.5 s doubling to 10 s, ±20%); what was not settled is redelivered by the broker.

`/health/ready` reports `broker` (the stream); `GET /status` does not. The contract is
`internal/brokerpb/broker.proto` with checked-in Go stubs; CI regenerates them and fails on a
difference.

### Requests from `requests.session`

A delivered request runs through the same Gin engine as the REST port, so it meets the same
concurrent task limit (`429`), task timeout (`408`), access log and error envelope, and counts in
`in_flight`, the load the broker routes by. The answer goes back with `Reply`: the status, the
headers, the body, the request's `correlation_id` and this instance's id. `X-Request-ID` comes from
the delivery; `X-Service-Token` and `Authorization` are dropped if they ever arrive.

### `GET /logs?since=&until=&level=`

As CPR README "Logs download" defines it, the same as Player Service (`docs/PLAYER_SERVICE.md` §13
once #114 merges): the instance's own lines from `LOG_FILE` and its rotated files, oldest first,
`since <= time < until`, `level` and above; `403 SERVICE_TOKEN_REQUIRED`, `401 INVALID_SERVICE_TOKEN`,
`400 VALIDATION_ERROR` with `details.errors`, `503 LOGS_UNAVAILABLE`. Headers are sent before the
files are read; a broken or unfinished line is left out. Outside the concurrent task limit and the
task timeout.

### `GET /metrics`

| Series | Labels |
| --- | --- |
| `http_requests_total` | `method`, `route` (the template, `unmatched` for an unknown path), `status`; `/health*`, `/status`, `/logs`, `/metrics` not counted |
| `http_request_duration_seconds` (histogram) | `method`, `route` |
| `tasks_in_flight`, `max_concurrent_tasks` | - |
| `broker_connected` | - (1 while the stream is open) |
| `events_consumed_total` | `event_type` (`decision.recorded` or `other`), `outcome` (`ok`, `duplicate`, `dropped`, `retry`, `permanent`) |
| `relay_deliveries` | `status` (`pending`, `parked`), counted in the outbox at scrape time |
| `go_*`, `process_*` | the Go runtime and process collectors |
