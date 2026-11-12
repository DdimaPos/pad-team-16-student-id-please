# Player Service - Integration Reference

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
7. [The XP curve and the level](#7-the-xp-curve-and-the-level)
8. [Divergences from the CPR contract](#8-divergences-from-the-cpr-contract)
9. [Edge cases](#9-edge-cases)
10. [Gateway requirements](#10-gateway-requirements)
11. [Testing recipes](#11-testing-recipes)
12. [Several instances (Lab 3)](#12-several-instances-lab-3)
13. [Message Broker, logs and metrics (Lab 4)](#13-message-broker-logs-and-metrics-lab-4)

---

## 1. What this service is

Player Service owns the moderator player accounts - the people who work the shifts, as opposed to
the applicants trying to get into the server. It holds identity, hashed credentials, profile,
friends, XP, level, shift history and the disciplinary log, and it is the system's only issuer of
the player token.

It is the quietest service in the system: it calls nobody, produces nothing, and consumes exactly
one event.

### Boundary

- **Owns:** `player_id`, username, hashed credentials, email, profile, friends list, XP, level,
  moderation statistics, shift history, disciplinary action log.
- **Does not own:** anything about the people attempting to join the university server - that is
  Applicant, Credential and University Record. It does not own session state either: which players
  are in a shift, their roles and their record scopes all belong to Server Moderation Session
  Service.
- **Calls:** no other service. Its only outbound connections are the registration with Service
  Discovery and, from `4.0.0`, one subscription stream to the Message Broker.
- **Is called by:** the client (login, its own account) and Server Moderation Session Service
  (`GET /players/{player_id}` when a player creates or joins a session, to check they exist and read
  their level). From `4.0.0` these requests arrive from the broker's queue `requests.player`, and
  `session.ended` arrives on the broker topic `events.session.ended` - see [§13](#13-message-broker-logs-and-metrics-lab-4).

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Go 1.26 / Gin |
| **Container port** | `8080` |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/player/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres and, from `4.0.0`, the broker). Through the Gateway only `/api/v1/player/health` (public); `/health/ready` is not a Lab 4 Gateway route (`404`) and is called on the instance directly, like `GET /status` for Service Discovery - see [§12](#12-several-instances-lab-3) |
| **Database** | PostgreSQL 17, `player_db` (own container). Schema applied at startup by GORM `AutoMigrate`, under a PostgreSQL advisory lock together with the seed |
| **Service Discovery** | Registers as `player`, instance id `player-<hostname>`, port `8080`; heartbeat every 5 s, `DELETE` on graceful shutdown - see [§12](#12-several-instances-lab-3) |
| **Logs** | One JSON object per line on stdout in the format of CPR README "Logging", and the same lines in the rotating `LOG_FILE`, read back by `GET /logs` (`4.0.0`) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (`4.0.0`) |
| **Message Broker** | One gRPC `Subscribe` stream to `MESSAGE_BROKER_URL` as service `player`: topic `events.session.ended` and the queue `requests.player` (`4.0.0`) - see [§13](#13-message-broker-logs-and-metrics-lab-4) |
| **Circuit breaker** | None: the service makes no outbound business call (the only outbound calls are the registration ones) |
| **Events** | Receives `session.ended` from the broker topic `events.session.ended`, settled with `Ack` - see [§6](#6-events). Produces none. `POST /api/v1/events` is removed in `4.0.0` |
| **Authentication** | Checked by the Gateway, not here: the service reads the calling player from `X-Player-Id` and validates no token. It **issues** the player JWT (`POST /api/v1/auth/login`, HS256 with `JWT_SECRET`) |
| **Task limits** | `HTTP_REQUEST_TIMEOUT` (`5s`) → `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (`50`) → `429 TOO_MANY_REQUESTS` + `Retry-After`. `/health`, `/health/ready` and `/status` are exempt |
| **Docker image** | `dimapos/player-service:4.0.0` (also `:latest`), `linux/amd64` and `linux/arm64`, published by GitHub Actions on merge to `main` |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`; `details` is always an object, never `null` |
| **Timestamps** | ISO-8601, UTC |
| **Identifiers** | UUID v4 strings |
| **Architecture** | Layered: `domain` (entities, the XP curve, sentinel errors, event wire types), `repository` (interfaces; `postgres` on GORM, `memory` fake for tests), `service` (use cases), `auth` (token issuer), `httpapi` (router, middleware, handlers), `seed`, `logging` (also the log file and its reader), `broker` (the subscription), `brokerpb` (the broker's proto and stubs), `metrics` |

---

## 3. Running it

### In the team stack (recommended)

The CPR `docker-compose.yml` runs `dimapos/player-service:4.0.0` next to its database and the
Gateway. Set `PLAYER_POSTGRES_PASSWORD` and `JWT_SECRET` in `.env` (the same `JWT_SECRET` the Gateway
reads), then `docker compose up -d`. The client routes go to the Gateway on `http://localhost:8080`;
the rest (`/health/ready`, `/status`, `/logs`, `/metrics`, `/api/v1/dev/slow`) only to an instance
directly - see [§10](#10-gateway-requirements).

### From the published image alone

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name player-service --network student-id-net \
  -e POSTGRES_HOST=<postgres-host> \
  -e POSTGRES_PASSWORD=<password> \
  -e JWT_SECRET=<the Gateway's JWT_SECRET> \
  dimapos/player-service:4.0.0
```

Every other variable has a working default.

### From source (development)

```bash
cd player-service
cp .env.example .env            # then set POSTGRES_PASSWORD and JWT_SECRET
./scripts/run.sh                # builds the image, starts app + postgres, waits for health
```

`./scripts/run.sh --local` runs Postgres in Docker and the service from source;
`--down` stops and keeps the data; `--clean` stops and deletes the volume.

On startup: the schema is applied, then - **only if the `players` table is empty** - six players
are seeded, with shift history, disciplinary actions and friendships. The seed is idempotent and
safe to leave enabled.

---

## 4. Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | - | **yes** | The service refuses to boot without it rather than falling back to something guessable |
| `JWT_SECRET` | - | **yes** | HS256 secret that signs login tokens; the same value as the Gateway's, which needs at least 32 characters. The service refuses to boot without it |
| `JWT_TTL` | `1h` | no | Lifetime of a login token, reported as `expires_in` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Task timeout; reached = `408 REQUEST_TIMEOUT`. Must stay below the Gateway's `10s` and below `HTTP_WRITE_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `50` | no | Concurrent task limit; reached = `429 TOO_MANY_REQUESTS` with `Retry-After: 1` |
| `POSTGRES_HOST` | `localhost` | no | |
| `POSTGRES_PORT` | `5432` | no | |
| `POSTGRES_USER` | `player_user` | no | |
| `POSTGRES_DB` | `player_db` | no | |
| `POSTGRES_SSLMODE` | `disable` | no | |
| `DB_AUTO_MIGRATE` | `true` | no | Applies the schema at boot, so a fresh database needs no migration step |
| `DB_MAX_OPEN_CONNS` / `DB_MAX_IDLE_CONNS` / `DB_CONN_MAX_LIFETIME` | `25` / `5` / `30m` | no | Pool |
| `APP_PORT` | `8080` | no | Listen port inside the container |
| `APP_ENV` | `local` (`docker` in the image) | no | `local` / `docker` / `production`; anything but `local` switches Gin to release mode and the logs to JSON. The image sets `docker`, so it always logs JSON |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error`; an unrecognised value falls back to `info` |
| `SERVICE_VERSION` | the image's `VERSION` | no | Reported by `GET /health`; overrides the version stamped into the image at build time |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` / `SHUTDOWN_TIMEOUT` | `10s` / `10s` / `15s` | no | |
| `XP_PER_LEVEL` | `400` | no | XP step between levels - see [§7](#7-the-xp-curve-and-the-level) |
| `MAX_LEVEL` | `10` | no | Level cap |
| `SEED_ON_START` | `true` | no | Seeds fixtures, but only when the `players` table is empty |
| `ENABLE_DEV_ENDPOINTS` | `true` | no | Mounts `GET /api/v1/dev/slow` |
| `BCRYPT_COST` | `10` | no | Password hashing work factor |
| `SERVICE_DISCOVERY_URL` | *empty* | no | Service Discovery to register with, directly (team stack: `http://service-discovery-service:8090`). Empty = no registration and one warning line at startup |
| `SERVICE_TOKEN` | *empty* | with either URL | The stack's `X-Service-Token`: sent to Service Discovery and to the broker (as the gRPC metadata `x-service-token`), and the token `GET /logs` accepts. The boot fails when `SERVICE_DISCOVERY_URL` or `MESSAGE_BROKER_URL` is set without it |
| `MESSAGE_BROKER_URL` | *empty* | no | The broker's gRPC address, `host:port` with no scheme (team stack: `message-broker-service:8071`). Empty = no subscription and one `broker.disabled` warning: no event and no request reaches the instance through the broker |
| `LOG_FILE` | `/var/log/player/player.jsonl` | no | The copy of the log lines `GET /logs` reads; the image creates the directory for its non-root user. Empty = stdout only, `GET /logs` answers `503` |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | no | The file rotates at this size; this many rotated files are kept |
| `INSTANCE_ID` | `player-<hostname>` | no | This instance's id in the registry, `/status` and every log line |
| `INSTANCE_HOST` | *empty* | no | Sent as `host` at registration, for a run outside Docker; otherwise Service Discovery uses the request's source address |

A variable that is set but unusable fails the boot with every problem listed at once, rather than
silently reverting to a default.

---

## 5. HTTP API

A client reaches this service through the Gateway (`{gateway}/api/v1/player/...`). From Lab 4
(#110) the Gateway serves only the client routes: it checks the player token, removes it, and sends
the request through the broker's queue `requests.player` with only `X-Player-Id`. Session Service's
`GET /players/{player_id}` arrives through the same queue without the Gateway (see
[§13](#13-message-broker-logs-and-metrics-lab-4)). The service itself validates no token. The
**Gateway** column below is the credential the Lab 4 Gateway accepts for each route (*not routed*:
the Gateway answers `404 NOT_FOUND` and the route is reached on an instance directly); the
**Service** column is what the service itself checks.

### 5.1 Contract endpoints

| Method | Path | Consumed by | Gateway | Service |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/auth/login` | the client | public | - |
| `GET` | `/api/v1/players/{player_id}` | Server Moderation Session Service (through the broker), the client | player | - |

**`POST /api/v1/auth/login`.** `{ "username", "password" }` →
`200 { "access_token", "token_type": "Bearer", "expires_in" }`. The token is HS256 with
`JWT_SECRET`; claims `sub` = `player_id`, `iat`, `exp` (`expires_in` seconds later).
`401 INVALID_CREDENTIALS` for an unknown username and for a wrong password alike, and both cost the
same bcrypt work, so neither the answer nor its timing reveals which usernames exist. A missing
field is `400 VALIDATION_ERROR`.

**`GET /api/v1/players/{player_id}`.**

```json
{
  "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "username": "dima_mod",
  "level": 4,
  "xp": 1250,
  "completed_shifts": 12
}
```

**These five fields are the whole contract.** `email`, the password hash, the friends list and the
disciplinary log are never returned here; a test asserts the field *set*, not only the values, so
an accidental addition fails the build. `404 PLAYER_NOT_FOUND` if no player has that id - Session
Service propagates that code verbatim as its own `404 PLAYER_NOT_FOUND` on `POST /sessions`.

Also mandatory for every service, outside the versioned base path:

| Method | Path | Gateway | Notes |
| --- | --- | --- | --- |
| `GET` | `/health` | public | Liveness. Never consults a dependency, so a database outage does not make an orchestrator restart a healthy container |
| `GET` | `/health/ready` | not routed | Readiness. `{"status":"ok","dependencies":{"postgres":{"status":"ok"},"broker":{"status":"ok"}}}` (`broker` only when `MESSAGE_BROKER_URL` is set); `503` with `"status":"degraded"` and a per-dependency `error` if any is down |
| `GET` | `/logs` | not routed | `4.0.0`. This instance's log lines, `X-Service-Token` checked by the service - see [§13](#13-message-broker-logs-and-metrics-lab-4) |
| `GET` | `/metrics` | not routed | `4.0.0`. Prometheus scrapes it directly - see [§13](#13-message-broker-logs-and-metrics-lab-4) |

None counts against the concurrent task limit.

### 5.2 Extension endpoints (beyond contract)

Their shapes are this service's own design.

| Method | Path | Gateway | Service | Notes |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/players` | public | - | Registration. `201` + `Location`. Body: `username`, `email`, `password`, optional `display_name`, `bio`, `avatar_url` |
| `GET` | `/api/v1/players?limit=&offset=` | player | - | `{ "items": [...], "total": n }`, ordered by username. `limit` defaults to 20, capped at 100 |
| `GET` | `/api/v1/players/{player_id}/profile` | player | - | The contract five plus `display_name`, `bio`, `avatar_url`, `created_at`, `updated_at`. **No `email`** |
| `PATCH` | `/api/v1/players/{player_id}` | player | owner | `display_name`, `bio`, `avatar_url`, `email`, `password`. Username, XP and `completed_shifts` are not editable |
| `DELETE` | `/api/v1/players/{player_id}` | player | owner | `204`. Shift history, disciplinary log and friendships cascade |
| `GET` | `/api/v1/players/{player_id}/shifts` | player | - | Paginated, newest first. Written only by applying `session.ended` |
| `GET` | `/api/v1/players/{player_id}/disciplinary-actions` | player | - | Paginated, newest first. Written only by applying `session.ended` |
| `GET` | `/api/v1/players/{player_id}/friends` | player | - | Paginated. Returns **public** projections - a friend's fields are no more visible than anyone else's |
| `POST` | `/api/v1/players/{player_id}/friends` | player | owner | `201`. Body: `{ "friend_id": "<uuid>" }`. Symmetric |
| `DELETE` | `/api/v1/players/{player_id}/friends/{friend_id}` | player | owner | `204`. Removes both directions |
| `GET` | `/api/v1/dev/slow?ms=` | not routed | - | Waits `ms` milliseconds (at most `60000`), then `200 { "waited_ms" }`. Demonstrates `408` (`ms` above `HTTP_REQUEST_TIMEOUT`) and `429` (enough parallel calls). Mounted only when `ENABLE_DEV_ENDPOINTS` is true |

**Owner** means the route needs a calling player and that player must be the one in the path: no
`X-Player-Id` is `401 UNAUTHENTICATED`, a different player is `403 NOT_ACCOUNT_OWNER`. Through the
Gateway a missing or invalid token is already `401` there, so only the `403` reaches a client from
the service.

Request and response bodies are `snake_case`. `items` is always an array, never `null`.

### 5.3 Error codes

| Code | Status | When |
| --- | --- | --- |
| `VALIDATION_ERROR` | 400 | Anything malformed: a body that is not JSON or breaks a field rule, a path id that is not a UUID, a bad query parameter. `details.field` (body) or `details.parameter` (path, query) names it, `details.reason` says why |
| `UNAUTHENTICATED` | 401 | An owner route without a usable `X-Player-Id` |
| `INVALID_CREDENTIALS` | 401 | `POST /auth/login`: unknown username or wrong password |
| `NOT_ACCOUNT_OWNER` | 403 | Beyond contract: an owner route called by another player |
| `PLAYER_NOT_FOUND` | 404 | No player has that id |
| `FRIEND_NOT_FOUND` | 404 | The `friend_id` is unknown, or the two are not friends |
| `NOT_FOUND` | 404 | Unknown route; `details.path` names it |
| `METHOD_NOT_ALLOWED` | 405 | Known path, wrong method |
| `REQUEST_TIMEOUT` | 408 | The task ran longer than `HTTP_REQUEST_TIMEOUT`; its query or transaction was cancelled, nothing was changed |
| `USERNAME_TAKEN` | 409 | |
| `EMAIL_TAKEN` | 409 | |
| `ALREADY_FRIENDS` | 409 | In either direction - it is one friendship |
| `CANNOT_FRIEND_SELF` | 422 | `friend_id` equals the player in the path |
| `TOO_MANY_REQUESTS` | 429 | `MAX_CONCURRENT_TASKS` requests are in progress; nothing was done. Comes with `Retry-After` |
| `INTERNAL_ERROR` | 500 | Anything unexpected, including the database failing. The detail is logged with the request id, never returned |
| `SERVICE_TOKEN_REQUIRED` / `INVALID_SERVICE_TOKEN` | 403 / 401 | `GET /logs` only: no `X-Service-Token` / a wrong one |
| `LOGS_UNAVAILABLE` | 503 | `GET /logs` only: no log file |

`INVALID_EVENT` (`422`) is gone with `POST /api/v1/events` in `4.0.0`; its cases are now the
`PERMANENT` outcome of [§6](#6-events).

Validation rules worth knowing before you call `POST /players`: username 3-32 characters of
`[A-Za-z0-9_]` only; password 8-72 bytes (72 is bcrypt's own limit, past which it ignores input);
`avatar_url` must be an absolute `http`/`https` URL; `display_name` ≤ 64, `bio` ≤ 280. An omitted
`display_name` falls back to the username.

---

## 6. Events

**Produced:** none. **Received:** `session.ended` only. From `4.0.0` it arrives from the Message
Broker: every instance subscribes to the topic `events.session.ended` (queue
`events.session.ended.player`, shared by the instances, so one of them gets each event), and settles
each delivery with `Ack`. `POST /api/v1/events` is removed, and the Lab 4 Gateway does not route it
either: Session `3.0.0`'s relay, which still pushes there through the Gateway, gets `404` until
Session `4.0.0` (#130) publishes to the broker.

| Situation | `Ack` | The broker |
| --- | --- | --- |
| Applied | `OK` | done |
| An `event_id` already applied | `OK`, nothing changes | done |
| A `player_id` with no account here | `OK`; the id is skipped and logged at warn, the rest of the event still applies | done |
| Unparseable envelope, missing `event_id` or `event_type`, an `event_type` other than `session.ended`, a `version` other than `1`, a payload that is not valid JSON or has no `session_id` (the old `422 INVALID_EVENT`) | `PERMANENT`, the reason (at most 200 characters, never the body) | dead-letters it - a retry cannot succeed |
| The database fails, or the task timeout (`HTTP_REQUEST_TIMEOUT`) is reached | `RETRY` | delivers it again later |
| The instance dies before acking | none | delivers it again after its ack timeout, to another instance |

The third row matters for Session Service: **this service will not reject an event because it does
not recognise a player.** Session decides who was in a shift, and one unknown id must not cost the
other players their XP. Ordering is not required.

### What applying the event does

For every entry in `players[]`: add `xp_delta` to the player's XP, record the shift in their
history, and append any `disciplinary_actions` to their log. The level needs no separate
recalculation - it is derived from XP ([§7](#7-the-xp-curve-and-the-level)). All of it happens in
one transaction together with the `event_id` marker, and the `Ack` is sent only after it commits.

`role` (`moderator` / `junior_moderator`) is stored on the shift row for the history view. It is
part of the contract's `session.ended` payload, but is still read leniently - an event without it
applies fine.

### Delivery guarantees

Delivery is at-least-once, so the same event can arrive more than once. Two mechanisms prevent a
shift being counted twice:

1. A `processed_events` table keyed on `event_id`, inserted with `ON CONFLICT DO NOTHING` **inside
   the same transaction** as the XP update, so a concurrent redelivery rolls back rather than
   double-counting.
2. A unique index on `shifts (player_id, session_id)` underneath it, which holds even for an event
   republished under a fresh `event_id`.

---

## 7. The XP curve and the level

```
level = xp / XP_PER_LEVEL + 1,  capped at MAX_LEVEL
```

The CPR contract says only that a player's level is *"recalculated"* from their XP. It defines no
curve, no thresholds, no cap and no maximum anywhere - so **this rule belongs to Player Service**,
and any other service needing a level must read it from
`GET /api/v1/players/{player_id}` rather than deriving one.

The default step is **400**, chosen so the contract's own published example stays true: 1250 XP is
level 4. A step of 500 - the other obvious round number - would have made that same player level 3
and quietly falsified the documentation.

`level` is **derived on read, never stored**, so `xp` and `level` cannot drift apart.

`MAX_LEVEL` defaults to 10 and is only a sanity bound. It is deliberately *not* 5: Session Service
clamps the *average* of its players' levels to 1-5 when it derives `difficulty`, which is its own
concern, and capping individual players at 5 would flatten progression for no contractual reason.

XP totals are floored at zero. A negative `xp_delta` is applied (the contract neither requires nor
forbids one), but a player's total never goes below 0, and the minimum level is therefore always 1 -
a level of 0 would distort the average Session divides by.

---

## 8. Divergences from the CPR contract

`3.0.0` implemented the whole Lab 3 contract slice of this service: login, `GET /players/{player_id}`,
`POST /events`, `X-Player-Id`, the shared error codes, the task timeout and the concurrent task
limit. `4.0.0` implements the Lab 4 contract (#105): the broker subscription, the queue
`requests.player`, `GET /logs` and `GET /metrics`. Item 9 is where it differs from the README; the
rest is beyond the contract rather than against it:

1. **Ten endpoints beyond the contract** (register, list, profile, edit, delete, shifts,
   disciplinary actions, friends) and `GET /dev/slow`.
   *Who this affects:* anyone reading the CPR README and expecting only the contract endpoints. They
   are labelled "beyond contract" here and in the Postman collection. The contract endpoints are
   untouched.

2. **`403 NOT_ACCOUNT_OWNER`** on `PATCH`/`DELETE` of a player and on adding or removing friends.
   The contract has no shared code for "a player acting on another player's account"; this one is
   the service's own.
   *Who this affects:* the client.

3. **The XP curve is this service's own invention** - 400 XP per level, capped at 10. The contract
   defines none. See [§7](#7-the-xp-curve-and-the-level).
   *Who this affects:* Session Service, which reads levels to set difficulty. Nothing else needs to
   know the formula, and nothing else should reimplement it.

4. **`level` is derived from `xp`, never stored.**
   *Who this affects:* nobody over the API - the field is present and correct in every response.
   It matters only to anyone reading `player_db` directly, which the contract forbids anyway.

5. **`completed_shifts` is a counter column, incremented once per applied shift.**
   *Who this affects:* anyone comparing it against `GET /players/{id}/shifts`'s `total`. The field
   appears exactly once in the entire CPR contract and is never defined there; this is the reading
   chosen. The two numbers agree unless a shift row was blocked by the unique index while the
   counter still moved - see [§9](#9-edge-cases).

6. **`role` from `session.ended` is stored on the shift row** (the field is in the contract's
   payload), although the contract does not list it among this service's owned data. It is kept for
   the history view only; role assignment remains entirely Session Service's.

7. **Friendships are symmetric and store no direction.** The contract says only "friends list", so
   "who added whom" is not information this service keeps; adding writes both rows in one
   transaction and removing from either side removes both.

8. **The reads of another player's profile, history and friends are open to any logged-in player.**
   Only changes are restricted to the owner. No endpoint returns `email`, so there is nothing
   private to hide on those reads.

9. **Log event names (Lab 4).** README "Logging" names a request delivered by the broker
   `request.received` and its `Reply` `request.replied`, and puts the `Ack` outcome on
   `event.received`. `4.0.0` logs one `broker.request` line per request (`broker.reply_failed`, `warn`,
   when the `Reply` cannot be sent) and has no outcome field on `event.received`: a `RETRY` is logged
   as `event.retry`, a `PERMANENT` as `event.rejected` ([§12](#logging)). A rename needs a new image;
   until then it is recorded here and in the README.
   *Who this affects:* anyone filtering the logs in Grafana by `event`, where Player's requests do not
   appear under `request.received` / `request.replied`.

---

## 9. Edge cases

- **A malformed id in the path is `400 VALIDATION_ERROR`, not `404`.** Answering 404 would
  disguise a client bug as a legitimate "no such player". The **nil UUID**
  (`00000000-...-0000`) is a *valid* UUID, so it parses and comes back as `404 PLAYER_NOT_FOUND` in
  a path - but as a `friend_id` in a body it is rejected `400 VALIDATION_ERROR`, since a nil id
  cannot be a real friend.
- **A non-numeric or negative `limit`/`offset` is `400`, not ignored.** Silently returning page one
  for a typo'd query string looks like success and hides the bug. A `limit` above 100 is clamped
  rather than rejected.
- **On an owner route the caller is checked before the body.** A request from another player is
  `403` even when its body is malformed, and nothing about the target account is revealed.
- **A deleted account whose holder still has a valid token** gets `404 PLAYER_NOT_FOUND` on its own
  owner routes until the token expires; login fails at once.
- **Re-submitting your own email on `PATCH` is not a conflict.** A client sending an unchanged form
  back must not get a `409`.
- **A player listed twice in one `session.ended` event has their deltas summed**, and the shift is
  recorded once. Letting one entry silently win would lose XP.
- **`ended_at` absent from the payload** falls back to the arrival time; a zero timestamp would sort
  that shift to the bottom of the history for ever.
- **`disciplinary_actions[].type` is stored as it arrives.** The contract only ever shows
  `"warning"` and defines no enumeration, so nothing is validated against a list.
- **An event republished under a fresh `event_id`** passes the `processed_events` check but its
  shift rows are blocked by the unique index on `(player_id, session_id)`. The XP and
  `completed_shifts` counters *do* move in that case - the second event is, as far as this service
  can tell, a legitimately new one. Session Service should not republish a shift under a new id.
- **A `429` is answered before any work**, so it never holds a database connection; a `408` rolls
  back whatever transaction was open.
- **Deleting a player cascades** to shifts, disciplinary actions and both directions of every
  friendship. There is no soft delete, so a `player_id` referenced by a Session that is still open
  will simply stop resolving.
- **Seeding never overwrites.** It runs only when `players` is empty, so a populated database is
  left alone on every boot.
- **An unreachable database fails the boot** rather than starting a service that 500s on every
  request. A missing `JWT_SECRET` fails it too. Nothing else can fail at boot: the service depends
  on no other service.

---

## 10. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) does for this service, prefix `player`:

- **Contract surface:** `POST /api/v1/auth/login` and `GET /api/v1/players/{player_id}`.
  `POST /api/v1/events` is removed in `4.0.0` (events come from the broker). Everything else may
  change without a CPR amendment.
- **Public routes:** `POST /api/v1/auth/login`, `POST /api/v1/players` (registration) and
  `GET /health`.
- **Player token:** every other client route, `GET /api/v1/players/{player_id}` included.
- **Not Gateway routes (Lab 4, #110):** `/api/v1/dev/*`, `GET /health/ready`, `GET /status`,
  `GET /logs`, `GET /metrics` and the removed `POST /api/v1/events`. The Gateway answers `404 NOT_FOUND`
  to them before any credential check, and to a known path with a method it does not take; they are
  reached on an instance directly. The Gateway takes no service token.
- **Lab 4 (#110):** the Gateway hands client requests to the broker's `requests.player`; Session's
  `GET /players/{player_id}` reaches this service through the broker, not the Gateway.
- **`JWT_SECRET` is shared** between this service (signs) and the Gateway (verifies). The Gateway
  requires it to be at least 32 characters.
- **The Gateway strips any client-sent `X-Player-Id`** and sets its own from the token, which is
  what the owner check relies on. This service's port is not published, so a request with
  `X-Player-Id` comes from the Gateway through the broker, or from inside `student-id-net`.
- **`email` is never in a response**, so there is nothing to redact.
- `X-Request-Id` is read from the request when present (a uuid4 is generated otherwise), echoed on
  every response, including errors, and printed as `request_id` on every log line of the request. Pass yours through and one player action can be followed across every service's logs.
- Errors already share the system-wide envelope, so they can be forwarded unchanged.
- The service's `5s` task timeout is below the Gateway's `10s`, so a slow request gets the service's
  own `408` first.

---

## 11. Testing recipes

The first recipe goes through the Gateway on `http://localhost:8080`. The routes the Lab 4 Gateway
does not serve (`/api/v1/dev/slow`, `/health/ready`) are called on an instance directly, by the
instance's own path (no `player` prefix) and with no token: `$PLAYER` below is
`http://player-service:8080` from a shell inside `student-id-net`
(`docker run --rm -it --network student-id-net --entrypoint sh curlimages/curl`), or the host port of
the service's own compose.

### Recipe: log in and read the contract endpoint against the seeded example

```bash
TOKEN=$(curl -s -X POST localhost:8080/api/v1/player/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"dima_mod","password":"seed-password"}' | jq -r .access_token)

curl -s localhost:8080/api/v1/player/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11 \
  -H "Authorization: Bearer $TOKEN"
# {"player_id":"8c1f...0f11","username":"dima_mod","level":4,"xp":1250,"completed_shifts":12}
```

Those are the numbers the CPR README publishes as its example, seeded deliberately so the
documentation is checkable rather than decorative.

### Recipe: apply a shift result through the broker, then prove it is applied only once

With the broker's command-line client (`scripts/smoke.py` in `message-broker-service`, run where it
reaches the broker's gRPC port, with `SERVICE_TOKEN` set):

```bash
P='{"session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e", "players": [
  {"player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11", "role": "moderator", "xp_delta": 30, "disciplinary_actions": []}]}'

python -m scripts.smoke publish --topic events.session.ended --event-id 4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23 --payload "$P"
# the instance logs event.received, duplicate false; the broker logs broker.acked
# GET /players/8c1f...0f11: xp 1280, completed_shifts 13, still level 4

python -m scripts.smoke publish --topic events.session.ended --event-id 4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23 --payload "$P"
# event.received, duplicate true, acked - and the player is unchanged

python -m scripts.smoke publish --topic events.session.ended --payload '{}'
# event.rejected (no session_id), Ack PERMANENT, the broker logs broker.dead_lettered
```

### Recipe: the task timeout and the concurrent task limit

```bash
PLAYER=http://player-service:8080

# 408: the service stops the task at 5s.
curl -s "$PLAYER/api/v1/dev/slow?ms=7000"
# {"error":{"code":"REQUEST_TIMEOUT",...}}

# 429: start the service with MAX_CONCURRENT_TASKS=1 (PLAYER_MAX_CONCURRENT_TASKS in the CPR .env),
# hold the slot, then call the same instance again. With two copies, set PLAYER to one copy's own
# address (its container IP from docker inspect), since the service name resolves to either.
curl -s "$PLAYER/api/v1/dev/slow?ms=3000" &
sleep 0.5
curl -si "$PLAYER/api/v1/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11"
# HTTP/1.1 429, Retry-After: 1, {"error":{"code":"TOO_MANY_REQUESTS",...}}
curl -s "$PLAYER/health"     # still 200 while the slot is held
```

### Recipe: what a teammate can assume about the seeded players

Six players are seeded into an empty database. The first three reuse the ids the CPR README and the
other services' Postman collections already use, so a session flow works against a fresh Player
Service without inventing anyone.

| `player_id` | username | xp | level | shifts | notes |
| --- | --- | --- | --- | --- | --- |
| `8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11` | `dima_mod` | 1250 | 4 | 12 | the contract's example; 2 shift rows, 1 warning, 2 friends |
| `b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10` | `maxim_jr` | 640 | 2 | 5 | 1 shift row |
| `c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21` | `vlad_jr` | 980 | 3 | 9 | no history |
| `d4f6a8c1-3e5b-4d7c-9f1a-2b4c6d8e0f32` | `rookie_one` | 0 | 1 | 0 | brand new account |
| `e5a7b9c3-4f6d-4e8b-a012-3c5d7e9f1a43` | `veteran_max` | 5200 | 10 | 41 | sits at the level cap |
| `f6b8c0d4-5a7e-4f9c-b123-4d6e8f0a2b54` | `repeat_offender` | 300 | 1 | 3 | 2 warnings |

Every seeded account logs in with the password `seed-password`.

### Postman

[`postman/player-service.postman_collection.json`](../postman/player-service.postman_collection.json)
sends the client routes through the Gateway, `base_url` (`http://localhost:8080/api/v1/player`), with
a player token. Every request on a route the Lab 4 Gateway does not serve goes to one instance
directly through `player_direct_url` (`http://player-service:8080` inside `student-id-net`), by the
instance's own path: `GET /health/ready`, `GET /status`, `GET /logs`, `GET /metrics`,
`GET /api/v1/dev/slow` and the `PUT` that shows `405`. Only `GET /logs` sends `service_token`, which
must equal `SERVICE_TOKEN` in `.env`. Its first folder logs in as the
seeded players and stores their tokens. Folders run top to bottom against a freshly seeded
database; requests whose names begin with a number belong to a sequence. The last folder is
destructive - drop the `player_db` volume to restore the seed. Every request name states the status
code it expects, and a test script asserts it.

### Test suite

```bash
cd player-service
make check       # gofmt, vet and every test that needs no database
make test-db     # adds a throwaway postgres for the repository and seeder tests
```

The repository and seeder are tested against a real PostgreSQL, because what matters about them -
the unique indexes, `ON DELETE CASCADE`, the `ON CONFLICT` clauses and the XP floor - is behaviour
of the database rather than of Go code. Those tests skip when `TEST_POSTGRES_DSN` is unset, so
`go test ./...` still works without Docker. CI sets it and runs them on every pull request.

---

## 12. Several instances (Lab 3)

From `3.0.0` the service runs as 2-3 copies, one database shared by all of them; in Lab 3 the
Gateway chose the copy, from `4.0.0` the broker does.

### `GET /status`

At the root, next to `/health`; no credential, outside the concurrent task limit and not counted in
`in_flight`. Service Discovery calls it directly every 10 s.

```json
// 200, or 503 with "status": "degraded" when the PostgreSQL ping (1 s) fails
{ "service": "player", "instance_id": "player-3f4e2a9b1c7d", "version": "3.0.0",
  "status": "up", "in_flight": 3, "max_concurrent_tasks": 50 }
```

`/health` keeps `"service": "player-service"`; the Lab 3 name `player` is used in `/status`, the
logs and the registration.

### Registration with Service Discovery

- `PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}` with `X-Service-Token` and
  `{"service_name": "player", "port": 8080, "version": "4.0.0", "topics": {"publishes": [], "subscribes": ["events.session.ended"]}}`
  (`host` added when `INSTANCE_HOST` is set; `topics` from `4.0.0`), sent right after the HTTP
  listener is up and then every 5 s as the heartbeat.
- `sd.registered` is logged on the first success; a failure logs `sd.heartbeat_failed` (`warn`) and
  is retried on the next tick. The instance keeps serving either way.
- On SIGTERM/SIGINT: `DELETE` the same path (2 s timeout, `sd.deregistered`), then the HTTP server
  drains (`SHUTDOWN_TIMEOUT`). Shutdown never waits on Service Discovery longer than that.
- Every call to Service Discovery has a 2 s timeout.

### Logging

One JSON object per line on stdout. Every line has `time` (UTC, milliseconds, `Z`), `level`
(lowercase), `service` (`player`), `instance_id`, `version`, `event` and `msg`; lines written while
handling a request add `request_id`.

| `event` | Level | Extra fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status`, `/logs` and `/metrics` | `method`, `path`, `status`, `duration_ms` (integer), `client_ip`, `player_id` when `X-Player-Id` is set |
| `http.error` | `info`; `error` with `stack` for a panic or an unexpected `500` (logged once) | `status`, `code`, `error` |
| `player.login` / `player.login_failed` | `info` | `player_id` / `username` (never the password) |
| `player.registered` | `info` | `player_id` |
| `event.received` | `info` | `event_id`, `event_type`, `producer`, `duplicate`, `players_updated`; from `4.0.0` also `message_id`, `queue`, `attempt` |
| `event.unknown_players` / `event.retry` / `event.rejected` | `warn` | as `event.received`, plus `unknown_players` or `reason` (`4.0.0`) |
| `broker.subscribed` / `broker.subscribe_failed` / `broker.stream_ended` / `broker.disabled` | `info` / `warn` | `topics`, `max_concurrent_tasks`; `error`, `retry_in_ms` when failed (`4.0.0`) |
| `broker.request` | `info`; `warn` as `broker.reply_failed` | `message_id`, `correlation_id`, `method`, `path` (no query), `caller`, `status`, `duration_ms` (`4.0.0`; README "Logging" names these `request.received` / `request.replied` - [§8](#8-divergences-from-the-cpr-contract) item 9) |
| `broker.ack_failed` | `warn` | `message_id`, `error` (`4.0.0`) |
| `logs.file_unavailable` | `warn` | `path`, `error`, once at startup (`4.0.0`) |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` / `sd.disabled` | `info` / `warn` | `error` when failed |
| `db.migrated`, `seed.applied`, `seed.skipped` | `info` | counts |
| `startup` / `shutdown` | `info` | address, port, log level, limits, pool size, Service Discovery URL, broker URL, log file - no secrets |

Never logged: `Authorization`, `X-Service-Token`, `JWT_SECRET`, passwords, request or response bodies.

### What makes several copies safe

- **No per-process state decides an answer.** Login tokens are stateless HS256 JWTs any copy can
  issue; every read and write goes to the shared database. The only per-process state is the
  concurrent task limit and the connection pool.
- **Startup.** Migrations and the seed run under one PostgreSQL advisory lock (taken once for the
  migration, once for the seed), on a dedicated connection. Copies starting together on an empty
  database wait for each other; the seed re-counts under the lock and inserts with
  `ON CONFLICT DO NOTHING`, so a copy that lost the race starts normally. Before `3.0.0` the second
  copy exited on the players' primary key.
- **`session.ended` reaching two copies** is applied once: the `processed_events` marker is inserted
  with `ON CONFLICT (event_id) DO NOTHING` in the same transaction as the XP update, and the shifts
  carry a unique index on `(player_id, session_id)`.
- **No circuit breaker.** The service calls no other service; a breaker has nothing to protect.
- **Connection budget.** `DB_MAX_OPEN_CONNS` is `25` per copy: 3 copies use at most 75 of
  PostgreSQL's default 100 `max_connections`.

---

## 13. Message Broker, logs and metrics (Lab 4)

From `4.0.0`.

### The subscription

- One gRPC `Subscribe` stream per instance to `MESSAGE_BROKER_URL`: `service: "player"`,
  `instance_id: INSTANCE_ID`, `topics: ["events.session.ended"]`, `max_concurrent_tasks:
  MAX_CONCURRENT_TASKS`. The broker attaches the queue `requests.player` to the same stream. Every
  call carries the metadata `x-service-token: SERVICE_TOKEN`.
- A stream that cannot be opened or ends is opened again with backoff (0.5 s doubling to 10 s,
  ±20%); what was not settled is redelivered by the broker, and the `event_id` dedup makes a repeat
  harmless.
- `/health/ready` reports `broker`; `GET /status` does not, so Service Discovery does not mark an
  instance down while only its broker is away.
- Shutdown: the stream closes first and the deliveries already received are settled, then the
  instance deregisters and drains its REST port.
- The contract is `internal/brokerpb/broker.proto`, a copy of the CPR's `shared/broker.proto` (by way
  of the broker repository's), with checked-in Go stubs; CI regenerates them and fails on a
  difference.

### Requests from `requests.player`

A delivered request (`method`, `path` with its query, `headers`, `body`) runs through the same Gin
engine as the REST port, so it meets the same concurrent task limit (`429`), task timeout (`408`),
access log and error envelope, and counts in `in_flight`, the load the broker routes by. The answer
goes back with `Reply`: the status, the headers, the body, the request's `correlation_id` and this
instance's id - a `4xx` or `5xx` too, unchanged. `X-Request-ID` comes from the delivery;
`X-Service-Token` and `Authorization` are dropped if they ever arrive. A request without
`X-Player-Id` is a service call (Session reading a player).

### `GET /logs?since=&until=&level=`

As CPR README "Logs download" defines it: the instance's own lines from `LOG_FILE` and its rotated
files, oldest first, `since <= time < until` (RFC 3339 with a zone), `level` and above.

| Answer | When |
| --- | --- |
| `200 application/x-ndjson`, `Content-Disposition: attachment; filename="<instance_id>-<since as 20261105T112700Z, or start>.jsonl"` | the lines, possibly none; headers sent before the files are read |
| `403 SERVICE_TOKEN_REQUIRED` / `401 INVALID_SERVICE_TOKEN` | no `X-Service-Token` / a wrong one |
| `400 VALIDATION_ERROR`, `details.errors: [{field, message}]` | a time that is not RFC 3339 or has no zone, `until <= since`, an unknown `level` |
| `503 LOGS_UNAVAILABLE` | `LOG_FILE` empty or not writable at startup |

Every file is opened before any is read, the current one only up to its size at the start; a last
line without its newline and any line that is not one JSON object are left out. With `APP_ENV=local`
the lines are text, so none is answered. Outside the concurrent task limit and the task timeout.

```bash
curl -s "http://<instance>:8080/logs?since=2026-11-07T17:00:00Z&level=warn" -H "X-Service-Token: $SERVICE_TOKEN"
```

### `GET /metrics`

| Series | Labels |
| --- | --- |
| `http_requests_total` | `method`, `route` (the template, `unmatched` for an unknown path), `status`; `/health*`, `/status`, `/logs`, `/metrics` not counted |
| `http_request_duration_seconds` (histogram) | `method`, `route` |
| `tasks_in_flight`, `max_concurrent_tasks` | - |
| `broker_connected` | - (1 while the stream is open) |
| `events_consumed_total` | `event_type` (`session.ended` or `other`), `outcome` (`ok`, `duplicate`, `retry`, `permanent`) |
| `go_*`, `process_*` | the Go runtime and process collectors |

A method outside the standard ones is `OTHER`, so no caller can grow the number of series.
