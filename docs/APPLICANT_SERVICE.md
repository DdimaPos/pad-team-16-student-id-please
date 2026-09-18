# Applicant Service — Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway, load balancer, authentication layer and other
> cross-cutting system pieces. It documents what this service does, how to run it, how to
> talk to it, what it guarantees, and — importantly — what it does **not** do.
>
> Everything here is stated from the implementation, not from the design documents. Where
> the implementation diverges from the team's Common Public Repository (CPR) contract, the
> divergence is called out explicitly in [§12](#12-divergences-from-the-cpr-contract).

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
14. [Notes for a gateway, load balancer or auth layer](#14-notes-for-a-gateway-load-balancer-or-auth-layer)
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
| **Language / framework** | Go 1.25, Gin |
| **Container port** | `8081` |
| **Default host port** | `8081` |
| **Base path** | `/api/v1` |
| **Health (liveness)** | `GET /health` |
| **Health (readiness)** | `GET /health/ready` |
| **Database** | PostgreSQL 16, `applicant_db` (private — no other service may connect) |
| **Broker** | RabbitMQ, topic exchange `student-id.events` |
| **Publishes** | `applicant.initialized` |
| **Consumes** | `applicant.initialized` (from Credential / University Record only) |
| **Authentication** | **None.** See [§14](#14-notes-for-a-gateway-load-balancer-or-auth-layer) |
| **Outbound HTTP calls** | None |
| **Docker image** | `stewdh/applicant-service:1.0.0` (also `:latest`), public on Docker Hub, `linux/amd64` and `linux/arm64` |
| **Hard dependency** | PostgreSQL only. RabbitMQ is soft — the service runs fully without it |

---

## 3. Prerequisites and running it

### To run it

- **Docker** with Compose v2. Nothing else.

### To develop or test it

- **Go 1.25+**. All dependencies are pure Go (`CGO_ENABLED=0`), so there is no C toolchain
  requirement.

### Start it

```bash
./scripts/run.sh                # build image, start postgres + rabbitmq + service, wait for ready
./scripts/run.sh --local        # run from source against the containerised dependencies
./scripts/run.sh --down         # stop (add --volumes to drop data)
./scripts/run.sh --logs         # follow logs
```

On first run the script creates `.env` from `.env.example` **with randomly generated
passwords**. `.env` is gitignored.

### Start it from the published image only

Use [`deployments/docker-compose.team.yml`](../applicant-service/deployments/docker-compose.team.yml) — the same
stack with `build:` removed and the Docker Hub image pinned. This is the fragment to merge
into the team-wide compose file; it lets anyone run Applicant Service without cloning its
(private) repository.

### Minimum viable configuration

The only required variable is `DATABASE_URL`. Everything else has a working default.

```bash
DATABASE_URL=postgres://user:pass@host:5432/applicant_db?sslmode=disable \
RABBITMQ_URL=amqp://user:pass@rabbit:5672/ \
  ./applicantd
```

### Startup sequence (what a supervisor should expect)

1. Parse and validate configuration. **Invalid configuration exits non-zero immediately** with
   a message naming the variable.
2. Connect to PostgreSQL, retrying with backoff for up to `DB_CONNECT_TIMEOUT` (30s default).
   **If the database is not reachable within that window, the process exits non-zero.**
3. Apply embedded migrations under a PostgreSQL advisory lock (safe with concurrent replicas).
4. Start the background workers: dial RabbitMQ with capped backoff, and start the consumer
   and the outbox relay. Failure here never blocks or fails startup.
5. Start the HTTP server — **the service is now serving**.

Typical cold start against a warm database is well under a second.

---

## 4. Ports and networking

| Port | Component | Notes |
| --- | --- | --- |
| `8081` | Applicant Service HTTP | Set by `APP_PORT` (default `8081`); the shipped compose file pins the container to `8081` and maps it with `APP_HOST_PORT` |
| `5433` → `5432` | PostgreSQL | **Host port is 5433 on purpose.** During integration several teammates' databases run on one laptop and 5432 is taken first |
| `5672` | RabbitMQ AMQP | Shared with the whole team |
| `15672` | RabbitMQ management UI | Useful for inspecting the exchange and queues |

The compose network is named **`student-id-net`** so other teams' stacks can join it. Inside
that network the service is reachable as `http://applicant-service:8081`.

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
| `APP_ENV` | `local` | no | `local` / `test` / `development` → text logs, Gin debug. Anything else → JSON logs, Gin release mode |
| `SERVICE_VERSION` | `dev` | no | Reported by `/health`. The image sets it via ldflags |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` — anything else fails validation |
| `HTTP_READ_TIMEOUT` | `10s` | no | Server read timeout |
| `HTTP_WRITE_TIMEOUT` | `10s` | no | Server write timeout |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Per-request context deadline (see the caveat below) |
| `SHUTDOWN_TIMEOUT` | `10s` | no | Grace period for in-flight requests on SIGTERM |
| `DB_MAX_CONNS` | `10` | no | pgx pool size. Must be ≥ 1 |
| `DB_CONNECT_TIMEOUT` | `30s` | no | How long to retry the database at boot before giving up |
| `MIGRATE_ON_START` | `true` | no | Apply embedded migrations at startup |
| `RABBITMQ_URL` | *(empty)* | no | **Empty disables messaging entirely** — events accumulate in the outbox and none are consumed |
| `RABBITMQ_EXCHANGE` | `student-id.events` | no | Shared topic exchange |
| `RABBITMQ_QUEUE` | `applicant-service.applicant-initialized` | no | This service's queue |
| `RABBITMQ_DLX` | `student-id.dlx` | no | Dead-letter exchange |
| `RABBITMQ_DLQ` | `applicant-service.dlq` | no | Dead-letter queue |
| `RABBITMQ_PREFETCH` | `10` | no | Unacknowledged messages in flight. Must be ≥ 1 |
| `PUBLISH_CONFIRM_TIMEOUT` | `2s` | no | How long to wait for a publisher confirm |
| `OUTBOX_POLL_INTERVAL` | `500ms` | no | How often the relay drains the outbox |
| `OUTBOX_BATCH_SIZE` | `50` | no | Events per drain batch. Must be ≥ 1 |
| `RABBITMQ_RECONNECT_MAX_BACKOFF` | `30s` | no | Cap on reconnect backoff |
| `REFERENCE_YEAR` | `2026` | no | The calendar year the generator treats as "now". Must be 1900–2999. **Must match across all three applicant-data services** — see [§7.3](#73-admission-year-and-study-year) |
| `GENERATOR_SEED` | `0` | no | `0` = a fresh random sequence per boot. Non-zero = reproducible applicants. **See the replica warning in [§15](#15-scaling-concurrency-and-statefulness)** |

**An empty string counts as unset** for every variable, so `RABBITMQ_EXCHANGE=""` silently
falls back to the default rather than failing. The one place this is load-bearing is
`RABBITMQ_URL`, where empty deliberately means "messaging off".

**Caveat on `HTTP_REQUEST_TIMEOUT`:** it installs a context deadline; it does **not** emit a
504. When it fires, in-flight database work is cancelled and the request surfaces as
`500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "postgres"`. A gateway timeout should
therefore be comfortably above 5s, or it will cut the connection before the service can
produce that body.

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
| `GET` | `/api/v1/applicants` | extension | admin / tests | **not player-safe** |
| `POST` | `/api/v1/applicants` | extension | admin / tests | **not player-safe** |
| `PATCH` | `/api/v1/applicants/{applicant_id}` | extension | admin / tests | **not player-safe** |
| `DELETE` | `/api/v1/applicants/{applicant_id}` | extension | admin / tests | **not player-safe** |
| `GET` | `/health` | infra | orchestrator | internal |
| `GET` | `/health/ready` | infra | orchestrator / LB | internal |

"Extension" means **beyond the CPR contract** — added because Lab 1 requires a CRUD service.
See the exposure warning in [§14](#14-notes-for-a-gateway-load-balancer-or-auth-layer).

### 6.2 `POST /api/v1/applicants/next`

Creates the next applicant for a session: invents both profiles, stores them, queues
`applicant.initialized`, returns the identifiers.

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

### 6.8 Health

**`GET /health`** — liveness. **Always `200` while the process is serving.** It deliberately
does not check dependencies: a liveness probe that fails on a dependency restarts a healthy
container because somebody else is having a bad day.

```json
{ "status": "ok", "service": "applicant-service", "version": "1.0.0" }
```

**`GET /health/ready`** — readiness.

```json
{
  "status": "ok",
  "service": "applicant-service",
  "version": "1.0.0",
  "components": {
    "postgres": { "status": "up" },
    "rabbitmq": { "status": "up" }
  },
  "pending_events": 0
}
```

| Condition | HTTP | `status` | `components.rabbitmq.status` |
| --- | --- | --- | --- |
| Everything up | `200` | `ok` | `up` |
| **RabbitMQ down** | **`200`** | `degraded` | `down` |
| **`RABBITMQ_URL` unset** | **`200`** | **`ok`** | `disabled` |
| **PostgreSQL down** | **`503`** | `unavailable` | *(unchanged)* |

`components.rabbitmq.status` is one of `up`, `down`, `disabled`. Note the third row: messaging
being *switched off* is treated as a deliberate configuration, not a fault, so the overall
status stays `ok`. Watch for `disabled` explicitly if you want to catch a missing
`RABBITMQ_URL` — otherwise events accumulate in the outbox indefinitely and nothing says so.

`components.<name>.details` carries the last error. `pending_events` is the outbox backlog —
a number that keeps climbing means the broker has been away for a while. **It is omitted from
the body when the count cannot be taken**, which is precisely when PostgreSQL is down.

> **Do not remove an instance from the load-balancer pool on `degraded`.** The REST surface is
> fully functional without RabbitMQ; events simply queue until it returns.

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
| `404` | `APPLICANT_NOT_FOUND` | No applicant with that id |
| `404` | `NOT_FOUND` | Unknown route |
| `405` | `METHOD_NOT_ALLOWED` | Known path, wrong method |
| `422` | `VALIDATION_ERROR` | Well-formed, but the profile is not internally coherent. `details.invariant`, `details.side`, `details.reason`. `invariant` is usually an `I1`–`I12` id, but is the literal `"DB"` (with `side: "row"`) when a database constraint rejected the row |
| `500` | `DEPENDENCY_UNAVAILABLE` | PostgreSQL unreachable or the request deadline fired. `details.dependency`. **Nothing was changed** |
| `500` | `INTERNAL_ERROR` | A bug, or a panic (recovered). `details` empty |

Both `400` and `422` use the code `VALIDATION_ERROR`, matching the contract's vocabulary; the
status distinguishes "could not parse this" from "parsed it, and it describes an impossible
person".

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

Course codes come from an embedded curriculum keyed by `(major, year)`. A profile's courses
normally belong to that person's own year of their own programme. Properties you can rely on:

- `courses` is **always an array**, never `null`. Empty for `staff`, `alumni` and `outsider`.
- Sorted ascending, no duplicates, at most **5** entries.
- The curriculum is shipped as `internal/generator/catalog/data/courses.json`. **University
  Record Service must agree on this list**, or a fabricated registration and an honest one
  become indistinguishable. Treat a change to it as a contract change.
- A separate `fake_courses.json` holds codes that exist nowhere (`ELSE-NET`, `QBIT-101`, …).
  These are what a naive fabrication uses, so University Record should answer `exists: false`.

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

- Exchange **`student-id.events`**, type `topic`, **durable**, not auto-deleted.
- Routing key **`applicant.initialized`**.
- This service's queue: `applicant-service.applicant-initialized`, durable, dead-lettered to
  `student-id.dlx` with routing key `applicant.initialized.dead`.
- Dead-letter queue `applicant-service.dlq`, bound to `student-id.dlx` with `#`.
- Publishes are **persistent** with **publisher confirms**; `mandatory` is `false` (during
  integration peer queues often do not exist yet, and flagging every publish unroutable would
  bury the real failures).

> **Every service must declare the shared exchange identically** (`topic`, durable, not
> auto-delete). One mismatched declaration gives everyone `PRECONDITION_FAILED (406)`, and
> amqp091-go reports that by *closing the channel*, after which publishes fail quietly. This
> service watches both connection and channel closure and surfaces it in `/health/ready`.

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
- **Ignore your own.** Your queue is bound to the exchange you publish on, so your own events
  come back. Drop any event whose `initialized_by` equals your own service name.
- **Deduplicate on `event_id`.** Delivery is at-least-once (see [§9.5](#95-delivery-guarantees)).
- **Do not require `actual`.** It is always sent by this service, but a lenient reader is what
  keeps an integration day from being lost to a dead-letter queue full of usable messages.

### 9.4 Consumed: `applicant.initialized`

Accepted from Credential Service and University Record Service (i.e. any event whose
`initialized_by` is not `applicant-service`). This service creates its own record under the
same `applicant_id` from the `claimed` profile, and registers the `actual` university address
so its own generator will not later hand the same address to someone else.

Handling policy:

| Situation | Action |
| --- | --- |
| Unparseable envelope, or `event_type` ≠ `applicant.initialized` | Dead-letter immediately (it will never succeed) |
| `initialized_by == "applicant-service"` | Acknowledge and drop — our own |
| Unknown/empty `initialized_by`, unusable payload | Dead-letter |
| Already-seen `event_id` | Acknowledge, do nothing |
| Transient failure, first delivery | Requeue (exactly one retry) |
| Payload the database refuses (wrong shape for our schema) | Dead-letter immediately |
| Transient failure, redelivered | Dead-letter |

**A peer's `difficulty` is silently clamped into 1–5** before storage; an out-of-range value
is not a reason to reject an otherwise usable applicant.

The retry bound uses the AMQP `Redelivered` flag rather than a counter. Without a bound, a
permanently failing message is requeued thousands of times a second and looks from outside
exactly like a healthy, busy consumer.

### 9.5 Delivery guarantees

Publishing uses a **transactional outbox**: the applicant row and the event are written in one
database transaction, and a relay publishes from the outbox afterwards.

| Property | Guarantee |
| --- | --- |
| An applicant exists but no event was ever queued | **Impossible** — same transaction |
| An event is published for an applicant that does not exist | **Impossible** — same transaction |
| The same event published more than once | **Possible** — a crash between a confirmed publish and the bookkeeping update republishes it |
| Ordering | Best-effort (oldest first within a batch); **do not rely on it** |

So: **at-least-once, never at-most-once.** Every consumer must deduplicate on `event_id`.

**Consequences you can build on:** `POST /api/v1/applicants/next` returns `201` whether or not
RabbitMQ is reachable, and the backlog drains automatically on reconnect. `/health/ready`
reports `pending_events` so you can watch the backlog.

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
| `outbox_events` | Events written with their applicant, awaiting publication |
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
dead-lettered merely for spelling a student ID differently.

> This was wrong until migration `0003`: the column-level checks applied to every row, so a
> peer sending the CPR's six-digit `FAF231017` had *every* event rejected, retried once and
> parked — which from their side looks like this service silently ignoring them. Fixed and
> verified end to end.

### Deliberate non-constraints

- **No unique index on `claimed_student_id`.** The `identity_theft` archetype produces two
  applicants claiming the same identifier on purpose. Do not add a uniqueness assumption
  downstream.
- **All `actual_*` columns are nullable**, because a peer's event may omit that profile.

### Retention

Nothing is deleted automatically. Applicants, processed event ids and published outbox rows
accumulate. For a course project that is fine; for a long-lived deployment, `processed_events`
and published `outbox_events` are the two tables that would want pruning.

### Migrations

Embedded in the binary and applied at startup under a PostgreSQL **advisory lock**, so
concurrent replicas cannot race. Explicitly **not** `docker-entrypoint-initdb.d`: those
scripts run only against an empty data directory, so with a persisted volume the second schema
change would silently never apply.

---

## 11. Use cases and interaction flows

### 11.1 Server Moderation Session Service — "give me the next applicant"

```
Moderator (client)  →  Session Service:  POST /api/v1/sessions/{id}/applicants/next
Session Service     →  Applicant Service: POST /api/v1/applicants/next
                                          { session_id, difficulty }
Applicant Service   →  Session Service:   201 { applicant_id, session_id, created_at }
Session Service     :  stores applicant_id as the session's current_applicant_id
Applicant Service   →  (async) publishes applicant.initialized
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

If Credential or University Record is contacted first, it publishes the event and **this**
service creates its record from `claimed`. That path is implemented and tested. Today no
service calls their `POST /applicants/next`, but the contract is identical on all three, so
Session Service could switch without any change on its side.

---

## 12. Divergences from the CPR contract

Raise these in the CPR before integration; they are the parts other services must match.

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | **Student ID is `{MAJOR}{yy}{g}{nn}` (5 digits, `FAF23314`)**, not the CPR's 6-digit examples (`FAF231017`). This service *accepts* either from a peer — it only *issues* the five-digit form | University Record Service parses these. Credential Service prints them |
| 2 | **Admission year and study year are independent**, related by the two-value window in [§7.3](#73-admission-year-and-study-year). `REFERENCE_YEAR` must be shared | All three applicant-data services |
| 3 | **University emails are numbered only on collision**; alumni/outsiders always carry a two-digit suffix | University Record Service's `email-groups` |
| 4 | **Four CRUD endpoints exist beyond the contract** (`GET` list, `POST`, `PATCH`, `DELETE`) | Gateway and auth — see [§14](#14-notes-for-a-gateway-load-balancer-or-auth-layer) |
| 5 | **`POST /api/v1/applicants` does not publish `applicant.initialized`** | Anyone expecting every applicant to be announced |
| 6 | The curriculum (`courses.json`) is a **shared artifact** that University Record must match | University Record Service |

---

## 13. Edge cases and failure modes

### 13.1 Eventual consistency window

Right after an applicant is created by **another** service, `GET /api/v1/applicants/{id}`
returns `404 APPLICANT_NOT_FOUND` until the event arrives. This is normal and expected by the
contract. Clients should retry briefly rather than treating it as an error. Typical window is
milliseconds; it is unbounded if the broker is down.

### 13.2 `POST /applicants/next` is not idempotent

Covered in [§6.2](#62-post-apiv1applicantsnext). The single most important thing for a gateway
or retry policy to know about this service.

### 13.3 Duplicate `student_id` is legal

`identity_theft` deliberately produces two applicants claiming the same identifier. Never key
on `claimed.student_id`.

### 13.4 Broker outage

- `POST /applicants/next` still returns `201`; events queue in the outbox.
- `/health/ready` returns `200` with `status: "degraded"` and a rising `pending_events`.
- Peers receive nothing until the broker returns; their view of applicants goes stale.
- On reconnect the backlog publishes automatically. Confirmed by hand against the running
  stack — three applicants created with RabbitMQ stopped, backlog of three, drained to zero on
  restart with no intervention. **No automated integration test covers this**; the unit tests
  use fakes.

### 13.5 Database outage

- `GET /health` → `200` (liveness is not dependency-aware).
- `GET /health/ready` → `503`.
- Every API call → `500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "postgres"`.
- **Nothing is partially written.** The service recovers on its own when the database returns;
  no restart needed. Confirmed by hand against the running stack, not by an automated test.
- At *startup*, an unreachable database for longer than `DB_CONNECT_TIMEOUT` (30s) exits the
  process non-zero — rely on the orchestrator's restart policy.

### 13.6 Poison messages

An unreadable or wrong-typed message goes straight to `applicant-service.dlq` and never
retries. A payload the database refuses is also parked immediately, since it would fail
identically on a redelivery. Only a genuinely transient failure is retried, exactly once.

**Inspect the DLQ first if a peer reports that its applicants never appear here.** The most
likely cause is a payload shape this service cannot store — see the constraint split in
[§10](#10-what-and-how-it-stores).

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

## 14. Notes for a gateway, load balancer or auth layer

### Authentication — there is none

**Every endpoint is open.** No JWT parsing, no service-token check, no `player_id` extraction.
The team contract says authentication is out of scope "for now"; this service takes that
literally. Anything guarding it must be in front of it.

When auth arrives, the contract's shape is: a player request carries the player's JWT, a
service request carries a service token, and the receiver tells them apart. Applicant Service
does not currently need `player_id` for any decision.

### Endpoint exposure — read this before routing anything publicly

| Endpoint | Safe for players? | Why |
| --- | --- | --- |
| `GET /api/v1/applicants/{id}` | **Yes** | Claimed profile only. This is what the game shows |
| `POST /api/v1/applicants/next` | **No — service only** | Creates an applicant and an event. A player could spam applicants and desynchronise sessions |
| `GET /api/v1/applicants` | **No — admin only** | Enumerates every applicant across every session. A player could pre-read applicants they have not met |
| `POST`, `PATCH`, `DELETE /api/v1/applicants` | **No — admin only** | A player could edit the applicant they are being judged on |
| `/health`, `/health/ready` | **No — internal** | Leaks dependency state and version |

A reasonable default gateway policy: expose `GET /api/v1/applicants/{id}` to authenticated
players; restrict `POST /api/v1/applicants/next` to the Session Service's service identity;
put everything else behind an admin scope or do not route it publicly at all.

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
| Per-request context deadline | 5s → surfaces as `500 DEPENDENCY_UNAVAILABLE`, not `504` |
| Graceful shutdown | 10s |

Set the gateway timeout above 5s so the service's own error body reaches the client.

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

**Treat `200` + `status: "degraded"` as healthy.** It means only RabbitMQ is away, and the
REST surface is fully functional.

### Graceful shutdown

On `SIGTERM` / `SIGINT` the service stops accepting HTTP, drains in-flight requests (up to
`SHUTDOWN_TIMEOUT`), then stops the consumer and relay, then closes the broker and the
database pool — in that order, so a consumer holding a message is never cut off from the
database. Give the orchestrator a termination grace period **above** `SHUTDOWN_TIMEOUT`.

---

## 15. Scaling, concurrency and statefulness

**The HTTP layer is stateless.** No sessions, no sticky routing, no in-memory per-client state.
Round-robin freely.

Replicas are safe:

| Concern | Behaviour |
| --- | --- |
| Migrations | Guarded by a PostgreSQL advisory lock — concurrent starts serialise |
| Consumer | All replicas share one queue → competing consumers, each message handled once |
| Outbox relay | `SELECT … FOR UPDATE SKIP LOCKED` — a second relay takes different rows rather than waiting or double-publishing |
| Email allocation | Arbitrated by a unique index, correct across processes |
| Generator RNG | Mutex-protected; race-clean under `-race` |

> **⚠ Do not run multiple replicas with a fixed non-zero `GENERATOR_SEED`.** Each replica seeds
> its own generator, so they would produce *identical* applicants in lockstep. Use
> `GENERATOR_SEED=0` (the default) in any multi-replica deployment; reserve a fixed seed for
> single-instance demos and reproducible debugging.

**Connection budget:** each replica opens up to `DB_MAX_CONNS` (10) PostgreSQL connections and
2 AMQP channels on 1 connection. Size the database's `max_connections` accordingly.

**Cost per applicant:** one `POST /applicants/next` performs roughly — one victim-pool query,
one or more email reservation attempts, one applicant insert, one outbox insert, all in a
single transaction. It is cheap; the generator itself does no I/O.

---

## 16. Observability

**Logs** are structured via `log/slog` — JSON when `APP_ENV` is not `local`/`test`/
`development`, text otherwise. Every line carries `request_id` when it belongs to a request.

One access-log line per request with `method`, `path`, `status`, `latency_ms`, `bytes`,
`client_ip`, `request_id`. Health probes log at `debug` so they do not bury everything else.

Events worth alerting on:

| Log message | Meaning |
| --- | --- |
| `broker unreachable, retrying` | RabbitMQ down; outbox is filling |
| `broker unavailable, events are queued in the outbox` | Same, throttled to once a minute |
| `parking message …` | A message went to the DLQ — investigate |
| `archetype could not be applied, retrying` | A rare generator sampling edge; harmless unless frequent |
| `falling back to an honest applicant` | **A generator bug** — every archetype attempt failed |
| `request failed` at `error` level | A 5xx |

**No metrics endpoint and no tracing.** There is no `/metrics`, no Prometheus, no OpenTelemetry.
`/health/ready` exposes `pending_events`, which is the single most useful number to scrape if
you are building a dashboard.

---

## 17. Known gaps — deliberately not implemented

Do not assume these exist:

- **Authentication and authorisation** — none at all ([§14](#14-notes-for-a-gateway-load-balancer-or-auth-layer)).
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

Bind a spy queue to the exchange, then create an applicant:

```bash
RU=<rabbit-user>; RP=<rabbit-pass>
curl -sS -u "$RU:$RP" -X PUT http://localhost:15672/api/queues/%2F/spy.peer \
  -H 'content-type: application/json' -d '{"durable":true}'
curl -sS -u "$RU:$RP" -X POST http://localhost:15672/api/bindings/%2F/e/student-id.events/q/spy.peer \
  -H 'content-type: application/json' -d '{"routing_key":"applicant.initialized"}'

# ... create an applicant ...

curl -sS -u "$RU:$RP" -X POST http://localhost:15672/api/queues/%2F/spy.peer/get \
  -H 'content-type: application/json' \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' | jq -r '.[0].payload' | jq
```

### Pretend to be Credential Service

Publish an event and watch this service create its own record. Publish the **same `event_id`**
twice to prove idempotency:

```bash
curl -sS -u "$RU:$RP" -X POST http://localhost:15672/api/exchanges/%2F/student-id.events/publish \
  -H 'content-type: application/json' -d '{
  "properties": {"content_type":"application/json","delivery_mode":2},
  "routing_key": "applicant.initialized",
  "payload_encoding": "string",
  "payload": "{\"event_id\":\"aaaa1111-2222-4333-8444-555566667777\",\"event_type\":\"applicant.initialized\",\"occurred_at\":\"2026-09-13T11:00:00Z\",\"producer\":\"credential-service\",\"version\":1,\"payload\":{\"applicant_id\":\"7c1e4a90-1111-4222-8333-444455556666\",\"session_id\":\"3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e\",\"initialized_by\":\"credential-service\",\"difficulty\":2,\"claimed\":{\"name\":\"Ana Rusu\",\"student_id\":\"FAF24214\",\"email\":\"ana.rusu@isa.utm.md\",\"major\":\"FAF\",\"year\":2,\"university_status\":\"faf_student\",\"courses\":[\"POO\",\"SDA\"],\"role\":\"student\"},\"actual\":{\"name\":\"Ana Rusu\",\"student_id\":\"FAF24214\",\"email\":\"ana.rusu@isa.utm.md\",\"major\":\"FAF\",\"year\":2,\"university_status\":\"faf_student\",\"courses\":[\"POO\",\"SDA\"],\"role\":\"student\"}}}"
}'
```

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
