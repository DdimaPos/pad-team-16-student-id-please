# University Record Service - Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway. Event delivery is described as the CPR contract
> requires it since 2026-10-05 (direct HTTP event push). Where the implementation diverges from
> the CPR contract, the divergence is called out explicitly in [§8](#8-divergences-from-the-cpr-contract).

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

---

## 1. What this service is

University Record Service owns the hidden institutional records - enrollment, email/Outlook
groups, courses, FCIM logs - that a Junior Moderator searches to catch a liar. It learns
everything from `applicant.initialized`, `session.started` and `session.ended`, pushed to its
`POST /api/v1/events`; the only call it makes is pushing its own `applicant.initialized`.

### Boundary

- **Owns:** enrollment records, email-group records, the course catalog + registrations,
  FCIM logs, session scopes.
- **Does not own:** the applicant's claimed identity (Applicant Service), documents
  (Credential Service), the admission decision (Moderation Service).
- **Calls:** `POST /api/v1/events` on Applicant and Credential Service, to deliver its own
  `applicant.initialized`. Learns about applicants and sessions purely from events.
- **Is called by:** Moderation Service (`GET /applicants/{id}/records` - full cross-category
  access via service token), the game client (`GET /records/{category}` - scoped per player).

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
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/university-record/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness - reports Postgres) |
| **Database** | PostgreSQL, `university_record_db` (own container, host port `5435`) |
| **Events** | HTTP push through the Gateway, no broker: received on `POST /api/v1/events`, produced through an outbox relay to `{gateway}/api/v1/<consumer>/events`. **Not in `0.1.0`** - see §8 |
| **Authentication** | Contract: checked by the Gateway; the service receives `X-Player-Id` for player calls and nothing for service calls, and validates no token. **`0.1.0` reads `Authorization: Bearer <jwt>` (unverified by default) and `X-Service-Token` itself** - see §8 |
| **Docker image** | `d1vinexd/university-record-service:0.1.0` (also `:latest`), public on Docker Hub |
| **Architecture** | Clean Architecture, five projects: `Domain` (pure - identity helpers, record generation, search semantics, the access-decision table), `Repositories` (interfaces + event DTOs), `Services` (use cases + event handlers), `Infrastructure` (EF Core, event transport), `Api` |

---

## 3. Running it

### From the published image (recommended for teammates)

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name university-record-service --network student-id-net \
  -p 8084:8080 \
  -e ConnectionStrings__UniversityRecordDb="Host=<postgres-host>;Port=5432;Database=university_record_db;Username=university_record_user;Password=<password>" \
  -e REFERENCE_YEAR=2026 \
  -e Auth__ServiceToken="<shared-secret>" \
  -e Dev__EnableTestEndpoints=true \
  d1vinexd/university-record-service:0.1.0
```

Or use the team compose in the CPR root. Until `POST /api/v1/events` exists, the dev-replay
endpoints (§11) exercise the same ingestion code path.

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
| `ConnectionStrings__UniversityRecordDb` | - | **yes** | Npgsql connection string |
| `REFERENCE_YEAR` | `2026` | no | Must be identical across Applicant, Credential, University Record and Moderation, or perfectly honest applicants read as liars |
| `Auth__ServiceToken` | - | **yes** in `0.1.0` | Shared secret for `X-Service-Token`. Under the contract the Gateway checks the token and this setting goes away |
| `Auth__ValidateSignature` | `false` | no | `0.1.0` only: switches the player-JWT reader from unverified to HMAC-verified. Under the contract the Gateway verifies the JWT |
| `Auth__JwtSecret` | - | only if `ValidateSignature=true` | `0.1.0` only: HS256 shared secret |
| `HTTP_REQUEST_TIMEOUT` / `MAX_CONCURRENT_TASKS` | - | contract | Task timeout (`408 REQUEST_TIMEOUT`) and concurrent task limit (`429 TOO_MANY_REQUESTS`), read from these names or mapped to configuration keys. **Not in `0.1.0`** |
| consumer URLs, `SERVICE_TOKEN` | - | contract | Gateway URLs of Applicant and Credential (`http://gateway-service:8080/api/v1/applicant`, `.../credential`) for its own `applicant.initialized`, and the token it sends on those pushes. **Not in `0.1.0`** |
| `Dev__EnableTestEndpoints` | `false` | no | Mounts `/api/v1/dev/*` (event replay + token mint). **Enable for the team demo**, leave `false` in any shared/production deployment |

---

## 5. HTTP API

### 5.1 Contract endpoints

| Method | Path | Consumed by | Auth |
| --- | --- | --- | --- |
| `GET` | `/api/v1/records/{category}?session_id=&q=&limit=&offset=` | Game client | Player JWT at the Gateway; scope-checked here against `X-Player-Id` |
| `GET` | `/api/v1/applicants/{applicant_id}/records` | Moderation Service | Service token only, at the Gateway; arrives without `X-Player-Id`, no scope check |
| `POST` | `/api/v1/applicants/next` | (no service calls it yet) | Service token only, at the Gateway |
| `POST` | `/api/v1/events` | Applicant, Credential, Session Service | Service token only, at the Gateway. **Not in `0.1.0`** |

`{category}` is one of `enrollment`, `email-groups`, `courses`, `fcim-logs` (kebab-case in
the path). The cross-category response at `/applicants/{id}/records` uses the different
snake_case keys `email_groups`/`fcim_logs` for the same categories - **this is intentional
per the contract**, not a bug; see §8 for the resolved `courses` shape contradiction.

Courses are identified by `code` (`^[A-Z]{2,4}$`) in both responses, and `q` on the `courses`
category matches it. Image `0.1.0` still names the field `course_code` - see §8.

**Error precedence for `GET /records/{category}`** (in order - see the service's own README
for the full table): `400` (missing/malformed `session_id`, `q`, `limit`, `offset`) =>
`422 UNKNOWN_CATEGORY` (checked before auth - the four values are public) =>
`401 UNAUTHENTICATED` (contract: no `X-Player-Id`) => service caller bypasses the rest => `403 SESSION_ENDED` (beats
"not a member") => `403 CATEGORY_NOT_ASSIGNED` (covers unknown session, the Moderator, a
non-member, and the wrong category - the contract folds all of these into one code).

### 5.2 Extension endpoints (beyond contract)

All under `/api/v1/admin/*` and `/api/v1/dev/*`, service-token only. `/admin/courses` is
full CRUD over the seeded catalog; `/admin/applicants` **reveals `actual`** (the answer key -
service token only, never route to a player); `/admin/sessions/{id}/scopes` doubles as a
manual mock of Server Moderation Session Service. `/dev/events/*` and `/dev/tokens` are
covered in §11.

### 5.3 Error codes

`VALIDATION_ERROR` (400), `UNKNOWN_CATEGORY` / `INVALID_RULESET`-equivalents (422),
`APPLICANT_NOT_FOUND` / `NOT_FOUND` (404), `SESSION_ENDED` / `CATEGORY_NOT_ASSIGNED` /
`SERVICE_TOKEN_REQUIRED` (403), `COURSE_HAS_REGISTRATIONS` (409), `UNAUTHENTICATED` /
`INVALID_SERVICE_TOKEN` (401), `INTERNAL_ERROR` (500), and on `POST /api/v1/events`
`INVALID_EVENT` (422). Contract, not in `0.1.0`: `REQUEST_TIMEOUT` (408), `TOO_MANY_REQUESTS` (429).
`SERVICE_TOKEN_REQUIRED` and `INVALID_SERVICE_TOKEN` move to the Gateway.

---

## 6. Events

Direct HTTP push, as the CPR's "Event delivery" section defines it - no broker. Peers push to
`POST /api/v1/events` (service token only); this service's own `applicant.initialized` is
relayed from its outbox to `POST /api/v1/events` on Applicant and Credential Service.

| `event_type` | Direction | Notes |
| --- | --- | --- |
| `applicant.initialized` | received (from Applicant/Credential) and produced (only when this service is first contacted) | Builds records from **`actual`**, the truth. Own events (`initialized_by == "university-record-service"`) are ignored |
| `session.started` | received (from Session) | Stores each junior's `record_scopes`. Delete-then-insert on redelivery (idempotent) |
| `session.ended` | received (from Session) | Upsert (not update) - a `session.ended` arriving before `session.started` still closes access |

Delivery is at-least-once; every domain write this service performs is independently
idempotent (`ON CONFLICT DO NOTHING` on a natural key: `student_id`, `email`,
`(code, student_id)`, `message_id`), so redelivery is always safe to repeat. A repeat is
answered `200` with `"duplicate": true`; an unusable event `422 INVALID_EVENT`.
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
| 2 | **No HTTP event delivery in image `0.1.0`.** It has no `POST /api/v1/events` and no relay to Applicant and Credential; events reach it only through `/api/v1/dev/events/*` (§11), and its own `applicant.initialized` reaches nobody | Applicant, Credential and Session Service; Moderation, which reads the records built from those events |
| 3 | **`course_code` instead of `code`** in `GET /records/courses` and in the `courses` entries of `/applicants/{id}/records`. The contract names the course identifier `code` everywhere (breaking for Moderation) | Moderation Service, the game client |
| 4 | **`courses.json` must be byte-identical to the CPR's [`shared/courses.json`](../shared/courses.json).** Image `0.1.0` seeds the copy taken from Applicant Service before that file existed; whether it matches is unverified | Applicant, Credential, Moderation |
| 5 | **Callers are authenticated here, not by the Gateway.** `0.1.0` reads the player from `Authorization: Bearer <jwt>` and recognises services by `X-Service-Token`. The Gateway strips both, so through it every scoped search answers `401` and `/applicants/{id}/records` answers `403 SERVICE_TOKEN_REQUIRED`. Under the contract the player comes from `X-Player-Id`, and a service call is a request on a service-only route without `X-Player-Id` | Moderation Service, the game client |
| 6 | **The `expelled` enrollment status is unreachable through events.** The shared applicant profile's `university_status` enum has no "expelled" value, so `actual.university_status` can never produce it - only this service's own `/applicants/next` generator can. Raised with the team as a gap in the shared identity model, not fixed unilaterally here | Anyone designing an "expelled student" scenario |
| 7 | **`q` is required on `GET /records/{category}`**, per the contract - there is no way to browse the course catalog without a search term. Flagged to the team as worth making optional for `courses` specifically; not changed unilaterally | Junior Moderators wanting to browse |
| 8 | **No task timeout or concurrent task limit** (`408` / `429`), no outbound calls through the Gateway, and the image is tagged `0.1.0`, not a Lab 2 `2.x.y` | Gateway, Lab 2 grading |

---

## 9. Edge cases

- **The eventual-consistency window.** Right after a peer creates an applicant,
  `GET /applicants/{id}/records` may answer `404` for a few milliseconds until the event
  arrives - the same documented behavior as Applicant/Credential Service.
- **A producer cannot reach this service.** Its events wait in that producer's outbox and
  arrive once this service answers again. Postgres down is the only thing that makes readiness
  `503`.
- **Ruleset/session ordering.** A junior can legitimately query before `session.started` has
  arrived; this reads as `403 CATEGORY_NOT_ASSIGNED` (a session this service has not
  heard of grants no scope to anyone) and is expected to resolve on retry.

---

## 10. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `university-record`:

- `/applicants/{id}/records` and every `/admin/*` route are **player-lethal or
  service-only** - `actual`, cross-category access, and admin CRUD must never reach a client.
  Service token only, and the request must arrive **without** `X-Player-Id`: that absence is how
  this service tells Moderation's full-access call from a junior's scoped one.
- `GET /records/{category}` is the only genuinely player-facing endpoint: player JWT at the
  Gateway, scope checked here against `X-Player-Id`.
- `POST /applicants/next` and `POST /events`: service token only. `POST /applicants/next` is **not
  idempotent** - the Gateway never retries it.
- No CORS headers, no rate limiting. `X-Request-ID` is echoed/generated on every response.

---

## 11. Mocking strategy (grade 9) and testing recipes

Three peers were missing when `0.1.0` was built (the event producers, the session service, a
JWT issuer) - all three are mocked the same way, through code paths that are otherwise real:

1. **`POST /api/v1/applicants/next`** is a contract-mandated endpoint, not throwaway scaffolding - it lets this service generate a whole applicant (with lies driven by `difficulty`) and exercises the exact same `ApplicantRecordFactory` the event consumer uses.
2. **`/api/v1/dev/events/{applicant-initialized|session-started|session-ended}`** (only when `Dev__EnableTestEndpoints=true`) accept a **full event envelope** and dispatch into the same handler classes the event receiver uses - the whole ingest => search => Moderation-view loop is demoable in Postman without any producer running. They are beyond the contract and give way to `POST /api/v1/events`.
3. **`GET /api/v1/dev/tokens?player_id=`** mints an unsigned, JWT-shaped token for Postman variables like `{{junior_a_jwt}}`. Under the contract the token comes from Player Service's `POST /api/v1/auth/login` and the Gateway verifies it, so this route only serves direct-port testing of `0.1.0`.

```bash
BASE=http://localhost:8084
TOK=<service-token>

# Mint a token, ingest an honest FAF student, search for them
JWT=$(curl -s "$BASE/api/v1/dev/tokens?player_id=$(uuidgen)" -H "X-Service-Token: $TOK" | jq -r .token)
curl -s -X POST "$BASE/api/v1/dev/events/applicant-initialized" -H "X-Service-Token: $TOK" -H 'Content-Type: application/json' -d @honest-applicant-event.json
```

The full Postman collection (`postman/university-record-service.postman_collection.json` in
the CPR) runs the honest-student, identity-theft and session-end scenarios end to end, with
assertions on every step.

---

*University Record Service is owned by Titerez Vladislav. See the service's own repository
README for build/test instructions and the EF Core migration history.*
