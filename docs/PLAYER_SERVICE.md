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
- **Calls:** nothing. No outbound HTTP client exists in the binary.
- **Is called by:** the client (login, its own account) and Server Moderation Session Service
  (`GET /players/{player_id}` when a player creates or joins a session, to check they exist and read
  their level; `POST /events` to push `session.ended`) - always through the Gateway.

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Go 1.26 / Gin |
| **Container port** | `8080` |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/player/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres). Through the Gateway: `/api/v1/player/health` (public) and `/api/v1/player/health/ready` (service token) |
| **Database** | PostgreSQL 17, `player_db` (own container). Schema applied at startup by GORM `AutoMigrate` |
| **Events** | Receives `session.ended` on `POST /api/v1/events` - see [§6](#6-events). Produces none |
| **Authentication** | Checked by the Gateway, not here: the service reads the calling player from `X-Player-Id` and validates no token. It **issues** the player JWT (`POST /api/v1/auth/login`, HS256 with `JWT_SECRET`) |
| **Task limits** | `HTTP_REQUEST_TIMEOUT` (`5s`) → `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (`50`) → `429 TOO_MANY_REQUESTS` + `Retry-After`. `/health` and `/health/ready` are exempt |
| **Docker image** | `dimapos/player-service:2.0.0` (also `:latest`), `linux/amd64` and `linux/arm64`, published by GitHub Actions on merge to `main` |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`; `details` is always an object, never `null` |
| **Timestamps** | ISO-8601, UTC |
| **Identifiers** | UUID v4 strings |
| **Architecture** | Layered: `domain` (entities, the XP curve, sentinel errors, event wire types), `repository` (interfaces; `postgres` on GORM, `memory` fake for tests), `service` (use cases), `auth` (token issuer), `httpapi` (router, middleware, handlers), `seed`, `logging` |

---

## 3. Running it

### In the team stack (recommended)

The CPR `docker-compose.yml` runs `dimapos/player-service:2.0.0` next to its database and the
Gateway. Set `PLAYER_POSTGRES_PASSWORD` and `JWT_SECRET` in `.env` (the same `JWT_SECRET` the Gateway
reads), then `docker compose up -d`. Every call goes to the Gateway on `http://localhost:8080`.

### From the published image alone

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name player-service --network student-id-net \
  -e POSTGRES_HOST=<postgres-host> \
  -e POSTGRES_PASSWORD=<password> \
  -e JWT_SECRET=<the Gateway's JWT_SECRET> \
  dimapos/player-service:2.0.0
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
| `APP_ENV` | `local` | no | `local` / `docker` / `production`; anything but `local` switches Gin to release mode and the logs to JSON |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error`; an unrecognised value falls back to `info` |
| `SERVICE_VERSION` | the image's `VERSION` | no | Reported by `GET /health`; overrides the version stamped into the image at build time |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` / `SHUTDOWN_TIMEOUT` | `10s` / `10s` / `15s` | no | |
| `XP_PER_LEVEL` | `400` | no | XP step between levels - see [§7](#7-the-xp-curve-and-the-level) |
| `MAX_LEVEL` | `10` | no | Level cap |
| `SEED_ON_START` | `true` | no | Seeds fixtures, but only when the `players` table is empty |
| `ENABLE_DEV_ENDPOINTS` | `true` | no | Mounts `GET /api/v1/dev/slow` |
| `BCRYPT_COST` | `10` | no | Password hashing work factor |

A variable that is set but unusable fails the boot with every problem listed at once, rather than
silently reverting to a default.

---

## 5. HTTP API

Every caller reaches this service through the Gateway (`{gateway}/api/v1/player/...`), which checks
the credential, removes it, and forwards only `X-Player-Id` for a player. The service itself
validates no token. The **Gateway** column below is the credential the Gateway accepts for each
route; the **Service** column is what the service itself checks.

### 5.1 Contract endpoints

| Method | Path | Consumed by | Gateway | Service |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/auth/login` | the client | public | - |
| `GET` | `/api/v1/players/{player_id}` | Server Moderation Session Service, the client | player or service | - |
| `POST` | `/api/v1/events` | Server Moderation Session Service (`session.ended`) | service | - |

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

**`POST /api/v1/events`** - see [§6](#6-events).

Also mandatory for every service, outside the versioned base path:

| Method | Path | Gateway | Notes |
| --- | --- | --- | --- |
| `GET` | `/health` | public | Liveness. Never consults a dependency, so a database outage does not make an orchestrator restart a healthy container |
| `GET` | `/health/ready` | service | Readiness. `{"status":"ok","dependencies":{"postgres":{"status":"ok"}}}`; `503` with `"status":"degraded"` and a per-dependency `error` if any is down |

Neither counts against the concurrent task limit.

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
| `GET` | `/api/v1/dev/slow?ms=` | service | - | Waits `ms` milliseconds (at most `60000`), then `200 { "waited_ms" }`. Demonstrates `408` (`ms` above `HTTP_REQUEST_TIMEOUT`) and `429` (enough parallel calls). Mounted only when `ENABLE_DEV_ENDPOINTS` is true |

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
| `INVALID_EVENT` | 422 | `POST /events` only - see [§6](#6-events) |
| `TOO_MANY_REQUESTS` | 429 | `MAX_CONCURRENT_TASKS` requests are in progress; nothing was done. Comes with `Retry-After` |
| `INTERNAL_ERROR` | 500 | Anything unexpected, including the database failing. The detail is logged with the request id, never returned |

Validation rules worth knowing before you call `POST /players`: username 3-32 characters of
`[A-Za-z0-9_]` only; password 8-72 bytes (72 is bcrypt's own limit, past which it ignores input);
`avatar_url` must be an absolute `http`/`https` URL; `display_name` ≤ 64, `bio` ≤ 280. An omitted
`display_name` falls back to the username.

---

## 6. Events

**Produced:** none. **Received:** `session.ended` only, pushed by Server Moderation Session Service's
outbox relay as `POST {gateway}/api/v1/player/events` with `X-Service-Token`, as the CPR's "Event
delivery" section defines it.

### `POST /api/v1/events`

| Situation | Answer | The producer |
| --- | --- | --- |
| Applied | `200 { "event_id", "duplicate": false }` | marks it delivered |
| An `event_id` already applied | `200 { "event_id", "duplicate": true }`, nothing changes | marks it delivered |
| A `player_id` with no account here | `200`; the id is skipped and logged at warn, the rest of the event still applies | marks it delivered |
| Unparseable envelope, missing `event_id` or `event_type`, an `event_type` other than `session.ended`, a `version` other than `1`, a payload that is not valid JSON or has no `session_id` | `422 INVALID_EVENT`, `details.reason` says which | parks it - a retry cannot succeed |
| The database fails | `500 INTERNAL_ERROR` | retries with backoff |
| The task timeout is reached | `408 REQUEST_TIMEOUT`, the transaction is rolled back | retries with backoff |

The third row matters for Session Service: **this service will not reject an event because it does
not recognise a player.** Session decides who was in a shift, and one unknown id must not cost the
other players their XP. Ordering is not required.

### What applying the event does

For every entry in `players[]`: add `xp_delta` to the player's XP, record the shift in their
history, and append any `disciplinary_actions` to their log. The level needs no separate
recalculation - it is derived from XP ([§7](#7-the-xp-curve-and-the-level)). All of it happens in
one transaction together with the `event_id` marker, and the `200` is sent only after it commits.

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

`2.0.0` implements the whole contract slice of this service: login, `GET /players/{player_id}`,
`POST /events`, `X-Player-Id`, the shared error codes, the task timeout and the concurrent task
limit. What remains is beyond the contract rather than against it:

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

- **Contract surface:** `POST /api/v1/auth/login`, `GET /api/v1/players/{player_id}` and
  `POST /api/v1/events`. Everything else may change without a CPR amendment.
- **Public routes:** `POST /api/v1/auth/login`, `POST /api/v1/players` (registration) and
  `GET /health`.
- **Service token only:** `POST /api/v1/events`, `/api/v1/dev/*` and `GET /health/ready`.
- **Player or service:** `GET /api/v1/players/{player_id}`. Every other route needs a player token.
- **`JWT_SECRET` is shared** between this service (signs) and the Gateway (verifies). The Gateway
  requires it to be at least 32 characters.
- **The Gateway strips any client-sent `X-Player-Id`** and sets its own from the token, which is
  what the owner check relies on. This service's port is not published, so nothing but the Gateway
  can reach it.
- **`email` is never in a response**, so there is nothing to redact.
- `X-Request-Id` is read from the request when present and echoed on every response, including
  errors. Pass yours through and one player action can be followed across every service's logs.
- Errors already share the system-wide envelope, so they can be forwarded unchanged.
- The service's `5s` task timeout is below the Gateway's `10s`, so a slow request gets the service's
  own `408` first.

---

## 11. Testing recipes

The recipes go through the Gateway on `http://localhost:8080`, with `SERVICE_TOKEN` from `.env`.

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

### Recipe: apply a shift result, then prove it is applied only once

```bash
EVENT='{
  "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "session.ended",
  "occurred_at": "2026-09-10T18:45:00Z",
  "producer": "server-moderation-session-service",
  "version": 1,
  "payload": {
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "score": 40, "penalties": 10, "applications_processed": 6,
    "players": [
      { "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11", "role": "moderator", "xp_delta": 30,
        "disciplinary_actions": [
          { "type": "warning", "reason": "Accepted an applicant with a forged student ID" } ] },
      { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "role": "junior_moderator",
        "xp_delta": 40, "disciplinary_actions": [] }
    ],
    "ended_at": "2026-09-10T18:45:00Z"
  }
}'

curl -s -X POST localhost:8080/api/v1/player/events \
  -H "X-Service-Token: $SERVICE_TOKEN" -H 'Content-Type: application/json' -d "$EVENT"
# {"duplicate":false,"event_id":"4f0c2a8e-..."}

curl -s localhost:8080/api/v1/player/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11 \
  -H "X-Service-Token: $SERVICE_TOKEN"
# xp 1280, completed_shifts 13, still level 4

curl -s -X POST localhost:8080/api/v1/player/events \
  -H "X-Service-Token: $SERVICE_TOKEN" -H 'Content-Type: application/json' -d "$EVENT"
# {"duplicate":true,"event_id":"4f0c2a8e-..."} - and the player is unchanged
```

### Recipe: the task timeout and the concurrent task limit

```bash
# 408: the service stops the task at 5s, before the Gateway's 10s.
curl -s "localhost:8080/api/v1/player/dev/slow?ms=7000" -H "X-Service-Token: $SERVICE_TOKEN"
# {"error":{"code":"REQUEST_TIMEOUT",...}}

# 429: start the service with MAX_CONCURRENT_TASKS=1 (PLAYER_MAX_CONCURRENT_TASKS in the CPR .env),
# hold the slot, then call again.
curl -s "localhost:8080/api/v1/player/dev/slow?ms=3000" -H "X-Service-Token: $SERVICE_TOKEN" &
sleep 0.5
curl -si "localhost:8080/api/v1/player/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11" \
  -H "X-Service-Token: $SERVICE_TOKEN"
# HTTP/1.1 429, Retry-After: 1, {"error":{"code":"TOO_MANY_REQUESTS",...}}
curl -s localhost:8080/api/v1/player/health     # still 200 while the slot is held
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
goes through the Gateway: one `base_url` variable (`http://localhost:8080/api/v1/player`) and a
`service_token` variable that must equal `SERVICE_TOKEN` in `.env`. Its first folder logs in as the
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
