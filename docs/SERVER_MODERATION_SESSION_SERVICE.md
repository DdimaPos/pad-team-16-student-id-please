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
  (`GET /rulesets/current?difficulty={n}`), Applicant Service (`POST /applicants/next`) - all
  through the Gateway (`/api/v1/player`, `/api/v1/server-rules`, `/api/v1/applicant`), with
  `X-Service-Token`.
- **Is called by:** Moderation Service (`GET /sessions/{session_id}`, before recording every
  decision) and the game client - both through the Gateway.
- **Produces:** `session.started`, `session.ended`, pushed through the Gateway. **Receives:**
  `decision.recorded`.

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Go 1.26 / Gin |
| **Container port** | `8080` (mapped to host `8088` by convention) |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/session/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres plus each of the three dependencies, and says which are stubbed) |
| **Database** | PostgreSQL 17, `session_db` (own container, host port `5438`). Schema applied at startup by GORM `AutoMigrate`. **No Redis** - see [§8](#8-divergences-from-the-cpr-contract) |
| **Events** | Direct HTTP push (contract): produced events are relayed from the outbox to the consumers' `POST /api/v1/events`, tracked per consumer; `decision.recorded` arrives on its own `POST /api/v1/events` - see [§6](#6-events) |
| **Caller identity** | `X-Player-Id`, set by the Gateway after it validated the player's JWT; the service validates no token. Outbound calls go through the Gateway with `X-Service-Token` |
| **Task limits** | `HTTP_REQUEST_TIMEOUT` (`5s`) → `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (`50`) → `429 TOO_MANY_REQUESTS` + `Retry-After`. `/health` and `/health/ready` are exempt |
| **Docker image** | `dimapos/server-moderation-session-service:2.0.0` (also `:latest`), public on Docker Hub, `linux/amd64` + `linux/arm64`, published by GitHub Actions on merge to `main` |
| **Producer name** | `server-moderation-session-service` - the value in the `producer` member of every event it publishes |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`; `details` is always an object, never `null` |
| **Timestamps** | ISO-8601, UTC |
| **Identifiers** | UUID v4 strings |
| **Architecture** | Layered: `domain` (entities, the session rules, sentinel errors, event wire types), `clients` (the three outbound clients + their stubs), `relay` (pushes the outbox to the consumers), `repository` (interfaces; `postgres` on GORM, `memory` fake for tests), `service` (use cases), `httpapi` (router, middleware, handlers), `seed`, `logging` |

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
  dimapos/server-moderation-session-service:2.0.0
```

Simpler: the root [`docker-compose.yml`](../docker-compose.yml) already carries both blocks.

### Wired to the real Player, Server Rules and Applicant Service

Under the contract every outbound call goes through the Gateway, so each URL is the Gateway plus the
peer's prefix:

```bash
-e PLAYER_SERVICE_URL=http://gateway-service:8080/api/v1/player \
-e RULES_SERVICE_URL=http://gateway-service:8080/api/v1/server-rules \
-e APPLICANT_SERVICE_URL=http://gateway-service:8080/api/v1/applicant \
-e UNIVERSITY_RECORD_SERVICE_URL=http://gateway-service:8080/api/v1/university-record \
-e DISCORD_DMS_SERVICE_URL=http://gateway-service:8080/api/v1/discord-dms \
-e SERVICE_TOKEN=<the stack's SERVICE_TOKEN>
```

The root compose file sets exactly these. The last two are event consumers only; `PLAYER_SERVICE_URL`
also receives `session.ended`. `SERVICE_TOKEN` is required as soon as any URL is set.

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
| `APP_ENV` | `local` | `local` \| `docker` \| `production`. Anything but `local` puts Gin in release mode and the logs in JSON |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `SERVICE_VERSION` | the image's `VERSION` | Reported by `GET /health`; overrides the version stamped into the image at build time |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` / `SHUTDOWN_TIMEOUT` | `10s` / `10s` / `15s` | |
| `POSTGRES_HOST` / `PORT` / `USER` / `DB` / `SSLMODE` | `localhost` / `5432` / `session_user` / `session_db` / `disable` | |
| **`POSTGRES_PASSWORD`** | **none** | **Required.** The service refuses to start without it |
| `DB_MAX_OPEN_CONNS` / `DB_MAX_IDLE_CONNS` / `DB_CONN_MAX_LIFETIME` | `25` / `5` / `30m` | Connection pool |
| `DB_AUTO_MIGRATE` | `true` | Applies the schema at startup |
| `PLAYER_SERVICE_URL` | `""` | Gateway URL of Player Service (`.../api/v1/player`), for the player lookup and the `session.ended` push. Empty selects the built-in stub and leaves Player's deliveries pending |
| `RULES_SERVICE_URL` | `""` | Gateway URL of Server Rules (`.../api/v1/server-rules`). Empty selects the built-in stub |
| `APPLICANT_SERVICE_URL` | `""` | Gateway URL of Applicant Service (`.../api/v1/applicant`). Empty selects the built-in stub |
| `UNIVERSITY_RECORD_SERVICE_URL` | `""` | Gateway URL of University Record (`.../api/v1/university-record`), for the event pushes. Empty leaves its deliveries pending |
| `DISCORD_DMS_SERVICE_URL` | `""` | Gateway URL of Discord DMs (`.../api/v1/discord-dms`), for the event pushes. Empty leaves its deliveries pending |
| `SERVICE_TOKEN` | - | Sent as `X-Service-Token` on every outbound call and event push. **Required** as soon as any URL above is set |
| `DEPENDENCY_TIMEOUT` | `3s` | Applies to every outbound call and push. Must be below `HTTP_REQUEST_TIMEOUT` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout; reached = `408 REQUEST_TIMEOUT`. Must be below `HTTP_WRITE_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `50` | Concurrent task limit; reached = `429 TOO_MANY_REQUESTS` with `Retry-After: 1` |
| `RELAY_INTERVAL` | `1s` | How often the relay looks for deliveries that are due |
| `RELAY_BATCH` | `50` | The most deliveries one relay pass sends |
| `MAX_PLAYERS_PER_SESSION` | `5` | The contract's cap: 1 Moderator + up to 4 Junior Moderators |
| `SCORE_PER_CORRECT` | `10` | Multiplied by the difficulty on a correct decision |
| `XP_BASE` | `20` | What every player earns for working the shift at all |
| `MODERATOR_MULTIPLIER` | `1.25` | Scales the Moderator's XP |
| `WARNING_PENALTY_THRESHOLD` | `25` | Penalty share above which a player is warned |
| `SEED_ON_START` | `true` | Seeds three sessions, but only when the table is empty |
| `ENABLE_DEV_ENDPOINTS` | `true` | Mounts `GET /api/v1/dev/slow?ms=` |

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
| `GET` | `/sessions/{session_id}/deliveries` | no | `{ items, total }`: per event and consumer, `status` (`pending` \| `delivered` \| `parked`), `attempts`, `next_attempt_at`, `last_error`, `delivered_at` |
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
| `INVALID_EVENT` | 422 | `POST /events` only - see [§6](#6-events) |
| `DEPENDENCY_UNAVAILABLE` | 500 | One of the three services did not answer, or the Gateway answered `502`/`408`/`429` for it. `details.dependency` names it. **Nothing was changed** |
| `REQUEST_TIMEOUT` | 408 | The task timeout was reached; the transaction was rolled back |
| `TOO_MANY_REQUESTS` | 429 | The concurrent task limit was reached, with `Retry-After` |
| `PLAYER_NOT_IN_SESSION` | 404 | Beyond contract: leaving a lobby the player is not in |
| `NOT_FOUND` / `METHOD_NOT_ALLOWED` / `INTERNAL_ERROR` | 404 / 405 / 500 | Routing and unexpected failures |

---

## 6. Events

Events travel by HTTP push through the Gateway, as the CPR's "Event delivery" section defines it:
produced events are relayed from the outbox to each consumer's `{gateway}/api/v1/<consumer>/events`
with `X-Service-Token`, and `decision.recorded` is pushed by Moderation Service to this service's own
`POST /api/v1/events` (reached as `{gateway}/api/v1/session/events`).

The **outbox**: Every published event is written to the `outbox_events` table
**inside the same database transaction as the state change that produced it**, together with one
pending row per consumer in `outbox_deliveries`, so an event can never exist without the state it
announces, nor the reverse. `GET /sessions/{id}/events` returns those rows rendered as full
envelopes, `GET /sessions/{id}/deliveries` their delivery state.

### Published

Both carry the shared envelope, with `producer: "server-moderation-session-service"` and
`version: 1`.

**`session.started`** - consumed by University Record Service (which learns each junior's scopes) and
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

**`session.ended`** - consumed by Player Service, Discord DMs Service and University Record Service.
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

A replay is a **success**, not an error. `POST /api/v1/events` reports `"duplicate": true` so a
caller can see the deduplication fire.

### The relay (producer side)

Every `RELAY_INTERVAL` the relay reads the pending deliveries that are due and `POST`s each envelope,
unchanged, to `{consumer URL}/events` with `X-Service-Token` - one goroutine per consumer, so a
consumer that hangs until `DEPENDENCY_TIMEOUT` delays only its own deliveries:

| Consumer answers | Delivery becomes |
| --- | --- |
| `2xx` | `delivered` |
| `422 INVALID_EVENT` | `parked`, logged as an error; never retried |
| Anything else (the Gateway's `408`/`429`/`502`, any `5xx`, another `4xx`), a timeout or a refused connection | stays `pending`, retried after 1 s, 2 s, 4 s … capped at 30 s |

A consumer whose URL is empty is not sent to; its deliveries stay `pending` and go out once it is
configured. Seeded sessions get no delivery rows, so a fresh boot never pushes fixture history.

### `POST /api/v1/events` (consumer side)

| Situation | Answer |
| --- | --- |
| Applied | `200 { "event_id", "duplicate": false }` |
| An `event_id` already applied | `200 { "event_id", "duplicate": true }`, nothing changes |
| A decision for a session that has already ended | `200`, nothing changes, logged - see [§9](#9-edge-cases) |
| Unparseable envelope, an `event_type` other than `decision.recorded`, a `version` other than `1`, an invalid payload, or an unknown session | `422 INVALID_EVENT`, `details.reason` says which |
| The database fails | `500`; the producer retries |

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

5. **A `decision.recorded` for a session that has already ended is acknowledged** (`200`, nothing
   changes) rather than refused. The contract does not say; a `422` would only park it in
   Moderation Service's outbox, and the contract already drops an applicant still undecided when
   the shift ends.

6. **`username` and `level` in the session object are a snapshot**, taken when the player joined and
   never refreshed. See [§5.1](#51-contract-endpoints).

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
- **A decision arrives after the shift ended.** Acknowledged with `200` on `POST /api/v1/events`
  and nothing changes. Not hypothetical - Moderation Service does not wait for the Moderator.
- **A peer call is never retried.** One attempt, bounded by `DEPENDENCY_TIMEOUT`: `POST
  /applicants/next` is not idempotent, and a second attempt would also eat the task's time budget.
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
- `GET /sessions/{id}` accepts a player or the service token (Moderation calls it);
  `POST /events` and `/dev/*` only the service token.
- `X-Request-Id` is honoured inbound and echoed outbound, so one player action can be followed
  through the logs of every service that handled it.
- Every response, including 404s, 405s and panics, uses the shared error envelope.
- The service shuts down gracefully on `SIGTERM`, which is what `docker stop` sends.

---

## 11. Mocking strategy (grade 9) and testing recipes

> **Direct port.** The recipes below call the service's own port (`8088`), which is published
> only during Lab 2 development, and send `X-Player-Id` themselves, as the Gateway would. Through
> the Gateway, replace `localhost:8088/api/v1/` with `localhost:8080/api/v1/session/`, send
> `Authorization: Bearer` with a JWT from `POST /api/v1/player/auth/login` instead of
> `X-Player-Id` (the Gateway discards a client-sent one), and send `X-Service-Token` on
> service-only and `/dev/*` routes.

Every cross-service dependency has a real HTTP client written against the contract **and** an
in-process stub with the same interface. Which one runs is decided by whether that dependency's base
url is set - a runtime switch, not a build flag - so each can be replaced by the real service
independently, as they land.

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

```bash
E=$(uuidgen | tr 'A-Z' 'a-z'); D=$(uuidgen | tr 'A-Z' 'a-z')
BODY="{\"event_id\":\"$E\",\"event_type\":\"decision.recorded\",\"occurred_at\":\"2026-09-10T18:12:00Z\",
       \"producer\":\"moderation-service\",\"version\":1,
       \"payload\":{\"decision_id\":\"$D\",\"session_id\":\"$S\",\"applicant_id\":\"$(uuidgen)\",
                    \"moderator_id\":\"$M\",\"action\":\"accept\",\"is_correct\":true,\"penalty\":0}}"

curl -sS -X POST localhost:8088/api/v1/events -d "$BODY"
# {"duplicate":false,"event_id":"..."}
curl -sS -X POST localhost:8088/api/v1/events -d "$BODY"
# {"duplicate":true,"event_id":"..."}

curl -sS localhost:8088/api/v1/sessions/$S | jq '.score, .applications_processed'
# 30   1   <- moved once
```

### Recipe: the end-to-end path across both of Dev's services

With `PLAYER_SERVICE_URL` and `SERVICE_TOKEN` set, end the shift and the relay pushes
`session.ended` to Player Service within `RELAY_INTERVAL`:

```bash
curl -sS -X POST localhost:8088/api/v1/sessions/$S/end -H "X-Player-Id: $M" | jq .

curl -sS localhost:8088/api/v1/sessions/$S/deliveries | jq '.items[] | {consumer, status, last_error}'
# player-service: delivered (the others too, or pending while their URL is empty)

curl -sS localhost:8080/api/v1/player/players/$M -H "X-Service-Token: $SERVICE_TOKEN" | jq .
# the XP, the shift count and the level have moved
```

### Postman

[`postman/server-moderation-session-service.postman_collection.json`](../postman/server-moderation-session-service.postman_collection.json).
Every request name carries the status code it expects, so the collection can be checked mechanically.
It goes through the Gateway: `base_url` is `http://localhost:8080/api/v1` (Session routes under
`/session`, login under `/player`) and `service_token` must equal `SERVICE_TOKEN` in `.env`. The
player ids are pre-filled with the ones Player Service seeds; the `auth` folder logs them in and
stores their tokens. Run the folders in order - the flow folder captures the `session_id` into a
collection variable, and the cleanup folder is destructive.

### Test suite

`make test` runs the unit tests: they drive the real service and router against an in-memory
repository and the stub clients, so they need neither a database nor any other service.
`make test-db` adds a throwaway PostgreSQL container for the repository tests. `make check` runs
gofmt, go vet and the unit tests together.
