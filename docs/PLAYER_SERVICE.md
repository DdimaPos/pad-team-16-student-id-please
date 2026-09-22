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
10. [Notes for a gateway](#10-notes-for-a-gateway)
11. [Mocking strategy (grade 9) and testing recipes](#11-mocking-strategy-grade-9-and-testing-recipes)

---

## 1. What this service is

Player Service owns the moderator player accounts - the people who work the shifts, as opposed to
the applicants trying to get into the server. It holds identity, hashed credentials, profile,
friends, XP, level, shift history and the disciplinary log.

It is the quietest service in the system: it calls nobody, publishes nothing, and consumes exactly
one event.

### Boundary

- **Owns:** `player_id`, username, hashed credentials, email, profile, friends list, XP, level,
  moderation statistics, shift history, disciplinary action log.
- **Does not own:** anything about the people attempting to join the university server - that is
  Applicant, Credential and University Record. It does not own session state either: which players
  are in a shift, their roles and their record scopes all belong to Server Moderation Session
  Service.
- **Calls:** nothing. No outbound HTTP client exists in the binary.
- **Is called by:** Server Moderation Session Service (`GET /players/{player_id}` when a player
  creates or joins a session, to check they exist and read their level) and the game client.

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Go 1.26 / Gin |
| **Container port** | `8080` (mapped to host `8087` by convention) |
| **Base path** | `/api/v1` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports each dependency separately; today that is Postgres alone) |
| **Database** | PostgreSQL 17, `player_db` (own container, host port `5437`). Schema applied at startup by GORM `AutoMigrate` |
| **Broker** | **None** - see [§6](#6-events) |
| **Authentication** | **None.** No token of any kind is read or required - see [§8](#8-divergences-from-the-cpr-contract) |
| **Docker image** | `dimapos/player-service:0.1.0` (also `:latest`), public on Docker Hub |
| **Producer name** | `player-service` (it publishes nothing, but this is the value to expect if it ever does) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`; `details` is always an object, never `null` |
| **Timestamps** | ISO-8601, UTC |
| **Identifiers** | UUID v4 strings |
| **Architecture** | Layered: `domain` (entities, the XP curve, sentinel errors, event wire types), `repository` (interfaces; `postgres` on GORM, `memory` fake for tests), `service` (use cases), `httpapi` (router, middleware, handlers), `events` (transport-neutral decode + retry classification), `seed`, `logging` |

---

## 3. Running it

### From the published image (recommended for teammates)

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name player-service --network student-id-net \
  -p 8087:8080 \
  -e POSTGRES_HOST=<postgres-host> \
  -e POSTGRES_PASSWORD=<password> \
  dimapos/player-service:0.1.0
```

Every other variable has a working default.

### From source (development)

```bash
cd player-service
cp .env.example .env            # then set POSTGRES_PASSWORD
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
| `SERVICE_VERSION` | `0.1.0` | no | Reported by `GET /health` |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` / `SHUTDOWN_TIMEOUT` | `10s` / `10s` / `15s` | no | |
| `XP_PER_LEVEL` | `400` | no | XP step between levels - see [§7](#7-the-xp-curve-and-the-level) |
| `MAX_LEVEL` | `10` | no | Level cap |
| `SEED_ON_START` | `true` | no | Seeds fixtures, but only when the `players` table is empty |
| `ENABLE_DEV_ENDPOINTS` | `true` | no | Mounts `/api/v1/dev/*`. **Enable for the team demo**, disable in anything shared |
| `BCRYPT_COST` | `10` | no | Password hashing work factor |

A variable that is set but unusable fails the boot with every problem listed at once, rather than
silently reverting to a default.

---

## 5. HTTP API

No endpoint requires a header of any kind beyond `Content-Type: application/json` on requests with
a body.

### 5.1 Contract endpoints

| Method | Path | Consumed by | Auth |
| --- | --- | --- | --- |
| `GET` | `/api/v1/players/{player_id}` | Server Moderation Session Service, the client | none |

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

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/health` | Liveness. Never consults a dependency, so a broker or database outage does not make an orchestrator restart a healthy container |
| `GET` | `/health/ready` | Readiness. `{"status":"ok","dependencies":{"postgres":{"status":"ok"}}}`; `503` with `"status":"degraded"` and a per-dependency `error` if any is down |

### 5.2 Extension endpoints (beyond contract - Lab 1 CRUD requirement)

The root README pre-authorises these: *"Account features (register, login, friends, profile
editing) will be added when the client is designed."* Their shapes are this service's own design.

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/api/v1/players` | `201` + `Location`. Body: `username`, `email`, `password`, optional `display_name`, `bio`, `avatar_url` |
| `GET` | `/api/v1/players?limit=&offset=` | `{ "items": [...], "total": n }`, ordered by username. `limit` defaults to 20, capped at 100 |
| `GET` | `/api/v1/players/{player_id}/profile` | The contract five plus `display_name`, `bio`, `avatar_url`, `created_at`, `updated_at`. **No `email`** |
| `PATCH` | `/api/v1/players/{player_id}` | `display_name`, `bio`, `avatar_url`, `email`, `password`. Username, XP and `completed_shifts` are not editable |
| `DELETE` | `/api/v1/players/{player_id}` | `204`. Shift history, disciplinary log and friendships cascade |
| `GET` | `/api/v1/players/{player_id}/shifts` | Paginated, newest first. Written only by applying `session.ended` |
| `GET` | `/api/v1/players/{player_id}/disciplinary-actions` | Paginated, newest first. Written only by applying `session.ended` |
| `GET` | `/api/v1/players/{player_id}/friends` | Paginated. Returns **public** projections - a friend's fields are no more visible than anyone else's |
| `POST` | `/api/v1/players/{player_id}/friends` | `201`. Body: `{ "friend_id": "<uuid>" }`. Symmetric |
| `DELETE` | `/api/v1/players/{player_id}/friends/{friend_id}` | `204`. Removes both directions |
| `POST` | `/api/v1/dev/events/session-ended` | Applies a `session.ended` envelope without a broker. Gated by `ENABLE_DEV_ENDPOINTS` |

Request and response bodies are `snake_case`. `items` is always an array, never `null`.

### 5.3 Error codes

| Code | Status | When |
| --- | --- | --- |
| `PLAYER_NOT_FOUND` | 404 | No player has that id |
| `FRIEND_NOT_FOUND` | 404 | The `friend_id` is unknown, or the two are not friends |
| `NOT_FOUND` | 404 | Unknown route; `details.path` names it |
| `METHOD_NOT_ALLOWED` | 405 | Known path, wrong method |
| `INVALID_PLAYER_ID` | 400 | A path id that is not a UUID; `details.parameter` and `details.value` |
| `MALFORMED_BODY` | 400 | The body is not parseable JSON, or a UUID field in it is malformed |
| `VALIDATION_ERROR` | 422 | A field or query parameter is invalid; `details.field` and `details.reason` name it |
| `CANNOT_FRIEND_SELF` | 422 | `friend_id` equals the player in the path |
| `USERNAME_TAKEN` | 409 | |
| `EMAIL_TAKEN` | 409 | |
| `ALREADY_FRIENDS` | 409 | In either direction - it is one friendship |
| `INTERNAL_ERROR` | 500 | Anything unexpected. The detail is logged with the request id, never returned |

Validation rules worth knowing before you call `POST /players`: username 3-32 characters of
`[A-Za-z0-9_]` only; password 8-72 bytes (72 is bcrypt's own limit, past which it ignores input);
`avatar_url` must be an absolute `http`/`https` URL; `display_name` ≤ 64, `bio` ≤ 280. An omitted
`display_name` falls back to the username.

---

## 6. Events

**Published:** none. **Consumed:** `session.ended` only.

**This service has no broker client.** The team is writing its own broker to replace RabbitMQ and
its protocol is not designed yet, so there is nothing to subscribe with. Treat Player Service as not
being on the bus: today a `session.ended` envelope reaches it by exactly one route, `POST
/api/v1/dev/events/session-ended` ([§11](#11-mocking-strategy-grade-9-and-testing-recipes)).

### Wiring a client later

Everything below is written against the CPR's event envelope rather than a wire format, so it stands
whatever the transport turns out to be. `internal/events` is the transport-neutral half a client
plugs into:

1. Receive a message.
2. `events.Decode(body)` - the envelope and payload, or a permanent error.
3. `shiftService.ApplySessionEnded(ctx, env, payload)` - the same call the dev endpoint makes.
4. `events.DispositionFor(err, alreadyRetried)` - `Ack`, `Retry` or `Park`; settle accordingly.

`alreadyRetried` is a parameter rather than read from the message, because a transport that exposes
no redelivery flag has to count attempts itself.

Requirements on the transport: at-least-once delivery, acknowledgement, redelivery, and somewhere to
park a message that can never be processed. Ordering is not required.

### What applying the event does

For every entry in `players[]`: add `xp_delta` to the player's XP, record the shift in their
history, and append any `disciplinary_actions` to their log. The level needs no separate
recalculation - it is derived from XP ([§7](#7-the-xp-curve-and-the-level)). All of it happens in
one transaction together with the `event_id` marker.

`role` (`moderator` / `junior_moderator`) is stored on the shift row for the history view. The
event catalog table in the CPR README omits `role` while the payload example includes it, so it is
treated as optional - an event without it applies fine.

### Delivery guarantees

These hold no matter which broker is used, because they live in the database rather than in the
transport - which is why the dev endpoint can demonstrate them today.

Delivery is assumed at-least-once, so the same event can arrive more than once. Two mechanisms
prevent a shift being counted twice:

1. A `processed_events` table keyed on `event_id`, inserted with `ON CONFLICT DO NOTHING` **inside
   the same transaction** as the XP update, so a concurrent redelivery rolls back rather than
   double-counting.
2. A unique index on `shifts (player_id, session_id)` underneath it, which holds even for an event
   republished under a fresh `event_id`.

A replay is answered with an **ack**, not an error - it is the deduplication working.

### Failure handling

What `events.DispositionFor` decides, for a client to act on:

| Situation | Disposition |
| --- | --- |
| Undecodable JSON, missing `event_id`, invalid payload | `Park` on the first attempt - retrying cannot change the outcome |
| An event of another type | `Park`; it means a routing or subscription mistake |
| Transient failure (in practice the database) | `Retry` once, then `Park` |
| An `event_id` already applied | `Ack` |
| A `player_id` with no account here | `Ack`; the id is skipped and logged, the rest of the event still applies |

That last row matters for Session Service: **this service will not reject an event because it does
not recognise a player.** Session decides who was in a shift, and one unknown id must not cost the
other players their XP.

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

> **No AMQP consumer**, though the contract's library table still names RabbitMQ - see
> [§6](#6-events). *Who this affects:* anyone expecting to reach this service over the bus.

The rest, in no particular order:
   *Who this affects:* anyone reading the CPR README and expecting a single endpoint. They are
   pre-authorised by the README's note that account features arrive with the client, and labelled
   "beyond contract" here, in the service README and in the Postman collection - the same way
   Server Rules labels its `admin` surface. The contract endpoint itself is untouched.

2. **No authentication anywhere.**
   *Who this affects:* everyone, and the gateway most of all. The contract's API conventions say
   player requests carry a JWT and service-to-service requests carry a service token, while the
   same README says *"Authentication is out of scope for now"*; this service follows the latter.
   There is no token issuer in the system yet - Player Service is the natural owner of one and does
   not have a login endpoint - so **any caller can read, edit or delete any player, friendships
   included**. As partial mitigation, **no endpoint returns `email`**: it is accepted on create and
   update and stored unique, but returned by nothing. It joins `/profile` when authentication is
   implemented.

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

6. **`role` from `session.ended` is stored on the shift row**, although the contract does not list
   it among this service's owned data. It is kept for the history view only; role assignment
   remains entirely Session Service's.

7. **`POST /api/v1/dev/events/session-ended` exists and is enabled by default.**
   *Who this affects:* any shared deployment. It can hand out arbitrary XP to any player without a
   credential. Set `ENABLE_DEV_ENDPOINTS=false` anywhere that matters, and block `/api/v1/dev/*` at
   the gateway.

8. **Friendships are symmetric and store no direction.** The contract says only "friends list", so
   "who added whom" is not information this service keeps; adding writes both rows in one
   transaction and removing from either side removes both.

---

## 9. Edge cases

- **A malformed id in the path is `400 INVALID_PLAYER_ID`, not `404`.** Answering 404 would
  disguise a client bug as a legitimate "no such player". The **nil UUID**
  (`00000000-...-0000`) is a *valid* UUID, so it parses and comes back as `404 PLAYER_NOT_FOUND` in
  a path - but as a `friend_id` in a body it is rejected `422 VALIDATION_ERROR`, since a nil id
  cannot be a real friend.
- **A non-numeric or negative `limit`/`offset` is `422`, not ignored.** Silently returning page one
  for a typo'd query string looks like success and hides the bug. A `limit` above 100 is clamped
  rather than rejected.
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
- **Deleting a player cascades** to shifts, disciplinary actions and both directions of every
  friendship. There is no soft delete, so a `player_id` referenced by a Session that is still open
  will simply stop resolving.
- **Seeding never overwrites.** It runs only when `players` is empty, so a populated database is
  left alone on every boot.
- **An unreachable database fails the boot** rather than starting a service that 500s on every
  request. Nothing else can fail at boot: there is no broker to be unreachable.

---

## 10. Notes for a gateway

- **Only `GET /api/v1/players/{player_id}` is contract surface.** Everything else may change
  without a CPR amendment.
- **Nothing here is authenticated.** Do not expose this service directly. The gateway must be where
  a caller's identity is established, and until it is, `PATCH` and `DELETE` on any player and every
  friends endpoint are open to anyone who can reach the port.
- **Block `/api/v1/dev/*`.** It grants XP.
- **`email` is never in a response**, so there is nothing to redact.
- `X-Request-Id` is read from the request when present and echoed on every response, including
  errors. Pass yours through and one player action can be followed across every service's logs.
- Errors already share the system-wide envelope, so they can be forwarded unchanged.
- `GET /health` is safe to poll at any rate; it touches nothing.

---

## 11. Mocking strategy (grade 9) and testing recipes

Two things this service needs do not exist yet: the `session.ended` event, which Server Moderation
Session Service will publish, and the transport that would carry it. Nothing else is mocked - there
is no outbound call to stub, because this service calls nobody.

`POST /api/v1/dev/events/session-ended` accepts the exact envelope and hands it to the same
`ApplySessionEnded` a real client will call. So XP accrual, level recalculation, shift history, the
disciplinary log and the `event_id` deduplication the contract demands are all verifiable today.

The response reports what happened:

```json
{ "event_id": "...", "duplicate": false, "players_updated": 2, "unknown_players": [] }
```

`duplicate: true` means the `event_id` had already been applied and nothing changed.

### Recipe: the contract endpoint against the seeded example

```bash
curl -s localhost:8087/api/v1/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11
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

curl -s -X POST localhost:8087/api/v1/dev/events/session-ended \
  -H 'Content-Type: application/json' -d "$EVENT"
# {"duplicate":false,...,"players_updated":2,"unknown_players":[]}

curl -s localhost:8087/api/v1/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11
# xp 1280, completed_shifts 13, still level 4

curl -s -X POST localhost:8087/api/v1/dev/events/session-ended \
  -H 'Content-Type: application/json' -d "$EVENT"
# {"duplicate":true,...} - and the player is unchanged
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

Every seeded account shares the password `seed-password`. There is nothing to log in to yet.

### Postman

[`postman/player-service.postman_collection.json`](../postman/player-service.postman_collection.json) -
80 requests in seven folders, covering all 14 endpoints and every error code that can be provoked
from outside - all but `INTERNAL_ERROR`, which by definition cannot be asked for. Folders run top
to bottom against a freshly seeded database; requests whose names begin with a number belong to a
sequence. The last folder is destructive - `make clean-data` in the service repository restores the
seed. Every request name states the status code it expects, and all 80 were replayed against a
running instance to confirm they do.

### Test suite

```bash
cd player-service
make test        # everything that needs no database
make cover-all   # adds a throwaway postgres; total coverage 88.3%
```

The repository and seeder are tested against a real PostgreSQL, because what matters about them -
the unique indexes, `ON DELETE CASCADE`, the `ON CONFLICT` clauses and the XP floor - is behaviour
of the database rather than of Go code. Those tests skip when `TEST_POSTGRES_DSN` is unset, so
`go test ./...` still works without Docker.
