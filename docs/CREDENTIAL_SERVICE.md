# Credential Service — Integration Reference

Everything another service, a gateway or a teammate needs in order to work with this service,
without reading its source.

Team 16 · *Student ID, please* · FAF.PAD21.1 · version `3.0.0`

For "how do I start it", see [README.md](../credential-service/README.md). This document is the contract.

Everything here describes the published image `3.0.0`. Where it differs from the CPR contract,
[§11](#11-divergences-from-the-cpr-contract) says so.

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Ports and networking](#3-ports-and-networking)
4. [Configuration](#4-configuration)
5. [HTTP API](#5-http-api)
6. [Document types and field schemas](#6-document-types-and-field-schemas)
7. [Validation rules](#7-validation-rules)
8. [Events](#8-events)
9. [What and how it stores](#9-what-and-how-it-stores)
10. [Interaction flows](#10-interaction-flows)
11. [Divergences from the CPR contract](#11-divergences-from-the-cpr-contract)
12. [Edge cases and failure modes](#12-edge-cases-and-failure-modes)
13. [Gateway requirements](#13-gateway-requirements)
14. [Running several instances](#14-running-several-instances)
15. [Observability](#15-observability)

---

## 1. What this service is

Credential Service owns **the documents an applicant presents** and **each document's
validation status**.

It answers one question — *is this paper what it claims to be* — and deliberately does not
answer the other one — *should this person be let in*. Moderation Service owns that, using
this service's verdicts as evidence alongside University Record Service's records and Server
Rules Service's ruleset.

### Boundary

| | |
| --- | --- |
| **Owns** | the document bundle per applicant; each document's `validation_status` and the `problems` behind it |
| **Does not own** | the applicant's identity profile (Applicant Service); the university's hidden records (University Record Service); the admission decision (Moderation Service) |
| **Calls** | `POST /api/v1/events` of Applicant and University Record Service, through the Gateway: the outbox relay delivers this service's `applicant.initialized` there ([§8.1](#81-transport)), with a circuit breaker per consumer. And Service Discovery, directly, to register each instance (Lab 3, [§14](#14-running-several-instances)). No request this service answers waits on another service |
| **Is called by** | the game client (`/documents`) and Moderation Service (`/documents/validation`) |
| **Listens to** | `applicant.initialized`, from Applicant Service or University Record Service |
| **Publishes** | `applicant.initialized`, only when it was the first service to meet the applicant |

---

## 2. Integration card

| | |
| --- | --- |
| Base path | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/credential/...` |
| Port | `8082` |
| Lab 3 service name | `credential` - the Gateway prefix, the `service` of every log line and of `GET /status`, and the `service_name` it registers under. Each copy is `credential-<hostname>` (`instance_id`) |
| Health | `GET /health`, `GET /health/ready` |
| Status (Service Discovery) | `GET /status` - load and health of this copy ([§5.6](#56-health)) |
| Instances | 2-3 copies share the one database; the Gateway finds them in Service Discovery and spreads requests round-robin ([§14](#14-running-several-instances)) |
| Database | MongoDB, `credential_db` |
| Events | HTTP push through the Gateway, no broker (CPR README "Event delivery"): produced from a transactional outbox to `{gateway}/api/v1/<consumer>/events`, received on `POST /api/v1/events` |
| Produces | `applicant.initialized`, pushed to Applicant and University Record Service |
| Consumes | `applicant.initialized` from Applicant and University Record Service |
| Auth | checked by the Gateway, not here; the service receives only `X-Player-Id` and validates no token - see [§13](#13-gateway-requirements) |
| Producer name | `credential-service` |
| Image | `stewdh/credential-service:3.0.0`, also `:latest` (linux/amd64, linux/arm64), published by CI on every merge to `main` |
| Error envelope | `{"error":{"code","message","details"}}` |
| Timestamps | ISO 8601, UTC, whole seconds |
| Identifiers | UUID v4 strings |

**Hard dependency:** MongoDB only. The Gateway, the consumers and Service Discovery are soft —
the service runs fully without them, events wait in the outbox, see
[§12.2](#122-the-gateway-or-a-consumer-is-away), and the registration is retried every 5 s.

---

## 3. Ports and networking

| Port | What |
| --- | --- |
| `8082` | the HTTP API. The shipped compose file publishes the host range `APP_HOST_PORT`-`APP_HOST_PORT_LAST` (`8082`-`8084`), one port per copy, so `--scale credential-service=3` works; the team compose publishes none |
| `27018` → `27017` | MongoDB, host → container |

`8081` and `5433` belong to Applicant Service; `8082` and `27018` were chosen so both stacks
run on one laptop.

The compose network is named **`student-id-net`**, the same one Applicant Service and the
Gateway declare, so the stacks see each other. There is no broker anywhere.

Inside the network the service is reachable as `credential-service:8082`, and it reaches its
consumers at `http://gateway-service:8080/api/v1/<prefix>` - the Gateway, never a peer's own
address. The one exception is Service Discovery, which it calls directly at
`SERVICE_DISCOVERY_URL` (`http://service-discovery-service:8090` in the team compose): that is
how the Gateway learns where each copy is. Service Discovery records the address the
registration came from, the container's IP on the network.

---

## 4. Configuration

Read once at startup and validated there, so a misconfigured deployment fails immediately with
a message naming the variable rather than at the first request that happens to need it.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MONGODB_URI` | — | **required.** Connection string, credentials included |
| `MONGODB_DATABASE` | `credential_db` | database inside that deployment |
| `DB_MAX_POOL_SIZE` | `20` | driver connection pool |
| `DB_CONNECT_TIMEOUT` | `30s` | also the server-selection timeout |
| `ENSURE_INDEXES_ON_START` | `true` | idempotent; the document store's equivalent of migrations |
| `SERVICE_TOKEN` | *(empty)* | the stack's one `X-Service-Token`, sent on every event push and checked by the Gateway. **Empty switches the relay off**: applicants are still created and their events wait in the outbox |
| `APPLICANT_URL` | *(empty)* | Gateway base URL of Applicant Service, `http://gateway-service:8080/api/v1/applicant`. The relay appends `/events`. Empty: that consumer's deliveries stay pending and `/health/ready` says `not_configured` |
| `UNIVERSITY_RECORD_URL` | *(empty)* | same for University Record Service, `http://gateway-service:8080/api/v1/university-record` |
| `EVENT_PUSH_TIMEOUT` | `15s` | one push as a whole. Above the Gateway's `10s`, so its `408` comes back as an answer rather than a cut connection. No answer within it counts as a failure for the consumer's circuit breaker |
| `OUTBOX_POLL_INTERVAL` | `500ms` | how often the relay looks for deliveries that are due |
| `OUTBOX_BATCH_SIZE` | `50` | deliveries taken per consumer per pass |
| `OUTBOX_LEASE` | `15m` | how long a claimed batch stays reserved for the copy that claimed it. **Must be at least `OUTBOX_BATCH_SIZE` × `EVENT_PUSH_TIMEOUT`** (12.5 min with the defaults), or startup fails: a shorter lease could run out while the batch is still being pushed. Deliveries a relay does not get to are handed back at once ([§8.6](#86-several-instances-and-the-circuit-breaker)) |
| `EVENT_RETRY_MAX_BACKOFF` | `30s` | cap on the wait between two attempts at one delivery (1 s, 2 s, 4 s, ... up to this) |
| `APP_PORT` | `8082` | |
| `APP_ENV` | `local` | `local` / `docker` / `production`; selects the Gin mode. Logs are JSON either way ([§15](#15-observability)) |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SERVICE_VERSION` | `dev` | reported by `/health`, `/status`, every log line and the registration |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` | `10s` | |
| `HTTP_REQUEST_TIMEOUT` | `5s` | task timeout: a request running longer is stopped and answered `408 REQUEST_TIMEOUT` (see below). `0` disables it. Times 3.5 it is also the circuit breakers' window and cooldown (17.5 s) |
| `MAX_CONCURRENT_TASKS` | `64` | concurrent task limit for `/api/v1`: a request above it is refused with `429 TOO_MANY_REQUESTS`. Must be ≥ 1. `GET /status` reports it as `max_concurrent_tasks` |
| `DEV_ENDPOINTS` | `false` | mounts `GET /api/v1/dev/slow?ms=` (see below). Keep `false` in shared deployments |
| `SHUTDOWN_TIMEOUT` | `10s` | graceful drain |
| **`REFERENCE_YEAR`** | `2026` | the calendar year treated as "now". **Applicant, Credential, University Record and Moderation Service must all be given the same value**, or perfectly honest applicants read as liars |
| `GENERATOR_SEED` | `0` | `0` picks a fresh sequence per boot; a fixed number reproduces a run exactly, **for one instance only**: every copy given the same seed generates the same applicants in lockstep |
| `SERVICE_DISCOVERY_URL` | *(empty)* | Service Discovery's base URL, `http://service-discovery-service:8090` in the team compose. The instance registers there directly, with `SERVICE_TOKEN`, which is then required. **Empty: no registration**, one `sd.disabled` warning at startup (fine for a local run, but the Gateway cannot find the instance) |
| `INSTANCE_ID` | `credential-<hostname>` | the id the instance registers under and logs with. In Docker the hostname is the container id, so every copy has its own. Set it only for an instance outside Docker; **never give scaled copies one value** |
| `INSTANCE_HOST` | *(empty)* | sent as `host` at registration, for an instance outside Docker that Service Discovery cannot reach at the address the registration came from. Empty: no `host` is sent |

A consumer URL that is set must be an `http(s)` URL with a host, or startup fails naming the
variable. An empty string counts as unset for every variable.

**Task timeout (`HTTP_REQUEST_TIMEOUT`).** Every request gets a deadline. When it fires,
whatever the request is waiting on in MongoDB is cancelled and the service answers
`408 REQUEST_TIMEOUT`. An applicant is one document written by one operation, and that operation
is not started once the deadline has passed; one that did start finishes and is answered normally.
So `408` always means the applicant was not stored, changed or deleted. The university email
reserved while generating the applicant is a write of its own (standalone MongoDB, no
multi-document transactions), recorded under the new applicant's id; when the applicant is not
stored - a timeout, a failed insert - it is handed back. Only when MongoDB is unreachable for
that too does the address stay reserved, which costs a later applicant with the same name a
numeric suffix; no applicant, document or event refers to it.
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

## 5. HTTP API

### 5.1 Endpoint summary

| Method | Path | Source | Consumed by |
| --- | --- | --- | --- |
| `POST` | `/api/v1/applicants/next` | contract | no service yet |
| `GET` | `/api/v1/applicants/{applicant_id}/documents` | contract | Client |
| `GET` | `/api/v1/applicants/{applicant_id}/documents/validation` | contract | Moderation Service |
| `POST` | `/api/v1/events` | contract | Applicant, University Record Service — see [§5.5b](#55b-post-apiv1events) |
| `GET` | `/api/v1/applicants` | *extension* | — |
| `POST` | `/api/v1/applicants` | *extension* | — |
| `GET` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `PATCH` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `DELETE` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `GET` | `/api/v1/dev/slow?ms=` | dev (`DEV_ENDPOINTS`) | demo / tests |
| `GET` | `/health`, `/health/ready` | infrastructure | orchestrator |
| `GET` | `/status` | infrastructure | Service Discovery (directly, every 10 s) |

### 5.2 `POST /api/v1/applicants/next`

Creates a new applicant, starting from the documents they bring. Stores the bundle, queues
`applicant.initialized` for delivery to Applicant and University Record, returns the
identifiers.

```json
{ "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e", "difficulty": 3 }
```

`201 Created`

```json
{ "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "created_at": "2026-09-10T18:10:00Z" }
```

`difficulty` is `1`–`5`. The higher it is, the more likely the applicant lies and the more
likely an otherwise sound document is damaged.

Because this service invents the whole person — both what they will claim and who they really
are — the event it publishes is indistinguishable from Applicant Service's. Session Service
could point at either.

**Not idempotent.** Two calls make two applicants. There is no request-id deduplication; the
caller owns the retry decision, as it does on Applicant Service.

Errors: `400 VALIDATION_ERROR`.

### 5.3 `GET /api/v1/applicants/{applicant_id}/documents`

What the applicant shows the Moderator. **No validation results.**

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "documents": [
    { "document_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "type": "student_id_card",
      "fields": { "name": "Ion Popescu", "student_id": "FAF25314", "faculty": "FCIM",
                  "major": "FAF", "valid_until": "2029-06-30" } },
    { "document_id": "f1a2b3c4-d5e6-4f7a-8b9c-0d1e2f3a4b5c",
      "type": "university_email",
      "fields": { "name": "Ion Popescu", "email": "ion.popescu@isa.utm.md",
                  "groups": ["faf-students", "faf-253"], "issued_at": "2025-09-01" } }
  ]
}
```

`documents` is always an array. An honest outsider brings nothing and gets `[]`.

Errors: `400 VALIDATION_ERROR` (malformed id), `404 APPLICANT_NOT_FOUND`.

### 5.4 `GET /api/v1/applicants/{applicant_id}/documents/validation`

The same documents plus the verdict. **Services only** — a player who saw this would have
nothing left to work out.

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "documents": [
    { "document_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "type": "student_id_card",
      "fields": { "name": "Ion Popescu", "student_id": "FAF25314", "faculty": "FCIM",
                  "major": "FAF", "valid_until": "2029-06-30" },
      "validation_status": "forged",
      "problems": ["Student ID FAF25314 was never issued to this person"] }
  ]
}
```

`validation_status` is one of `valid`, `expired`, `forged`, `inconsistent`, `incomplete`.
`problems` is always an array, empty exactly when the status is `valid`.

Errors: `400 VALIDATION_ERROR`, `404 APPLICANT_NOT_FOUND`.

### 5.5 Extensions

- **`GET /api/v1/applicants`** — `?limit=` (1–100, default 20), `?offset=`, `?session_id=`.
  Returns `{"items": [], "total": 0}` per the API conventions. Items carry metadata and the
  *player-facing* documents; never the verdicts.
- **`POST /api/v1/applicants`** — hand-craft an applicant. Body: `session_id`, optional
  `applicant_id` and `difficulty`, a `claimed` profile, and an optional `actual` profile
  (without it the applicant is taken to be honest and nothing can be forged). Returns `201`.
  **Publishes nothing** — an applicant somebody typed in is not news the peers should act on.
  `422` if the profile describes an impossible person.
- **`GET /api/v1/applicants/{id}`** — metadata plus the player-facing documents.
- **`PATCH /api/v1/applicants/{id}`** — edits the claimed profile. Fields are the profile's;
  an absent key means "leave it", an explicit `null` means "clear it". **The bundle is rebuilt
  from the result**, because the papers somebody presents are a function of what they claim.
- **`DELETE /api/v1/applicants/{id}`** — `204`, removes the applicant and their documents.

### 5.5b `POST /api/v1/events`

The consumer side of the contract's event delivery. Applicant Service or University Record
Service, having met an applicant first, relays its `applicant.initialized` here through the
Gateway as `POST {gateway}/api/v1/credential/events` with `X-Service-Token`; the Gateway
checks the token, strips it and forwards the envelope unchanged. This service reads no
credential.

**Request body:** the envelope of [§8.2](#82-envelope) with the payload of
[§8.3](#83-published-applicantinitialized).

**Answers** - exactly those of the CPR README "Event delivery", because the producer's relay
keys its behaviour on them:

| HTTP | Body | When | The producer then |
| --- | --- | --- | --- |
| `200` | `{ "event_id": "...", "duplicate": false }` | The bundle was built from `claimed`, judged against `actual`, and stored | Marks the delivery done |
| `200` | `{ "event_id": "...", "duplicate": true }` | An applicant with that `applicant_id` is already stored. Nothing changed - a repeat is the dedup working, not an error | Marks the delivery done |
| `200` | `{ "event_id": "...", "duplicate": false }` | `initialized_by` is `credential-service`: our own event, which the contract never pushes back. Ignored, nothing stored | Marks the delivery done |
| `422` | `INVALID_EVENT` | The envelope cannot be parsed, has no `event_id`, `event_type`, `producer` or `payload`, names an `event_type` other than `applicant.initialized` or a `version` other than `1`, or its payload fails validation (no `applicant_id`, no `initialized_by`, no claimed `name`). `details.reason` says which | Parks the delivery and logs it - a retry cannot succeed |
| `408` | `REQUEST_TIMEOUT` | The task ran past `HTTP_REQUEST_TIMEOUT`; the write was never started | Retries later |
| `429` | `TOO_MANY_REQUESTS` | The concurrent task limit is reached | Retries later |
| `500` | `DEPENDENCY_UNAVAILABLE` | MongoDB did not answer. Nothing was changed | Retries later |

A pushed event is a task like any other: it sits under `/api/v1`, so the task timeout and the
concurrent task limit apply to it. Through the Gateway, `403 SERVICE_TOKEN_REQUIRED` and
`401 INVALID_SERVICE_TOKEN` are answered by the Gateway before the push reaches this service.

Dedup is keyed on `applicant_id`, the document's primary key, rather than on `event_id`: the
insert either creates the bundle or finds it there, with no read-then-write race to lose. It
follows that a second producer announcing the same applicant is also answered `duplicate`.

### 5.6 Health

`GET /health` → `200` whenever the process is serving. It checks no dependency on purpose:
restarting a healthy container because somebody else's database was slow would be wrong.

`GET /health/ready`:

```json
{ "status": "ok", "service": "credential-service", "version": "3.0.0",
  "components": { "mongodb": {"status": "up"}, "event_relay": {"status": "up"} },
  "consumers": { "applicant":         {"status": "configured", "pending": 0, "parked": 0},
                 "university-record": {"status": "configured", "pending": 3, "parked": 0} },
  "pending_events": 3 }
```

| Situation | `status` | HTTP | Where it shows |
| --- | --- | --- | --- |
| everything configured | `ok` | `200` | |
| `SERVICE_TOKEN` or every consumer URL unset | `degraded` | `200` | `components.event_relay.status: "disabled"` |
| a consumer URL unset | `degraded` | `200` | `consumers.<name>.status: "not_configured"` |
| the Gateway or a consumer not answering | `ok` | `200` | `consumers.<name>.pending` keeps climbing |
| Mongo unreachable | `unavailable` | `503` | `components.mongodb` |

`consumers.<name>.pending` is that consumer's backlog: deliveries due or waiting out a retry
backoff. `parked` counts deliveries the consumer refused with `422 INVALID_EVENT`; they are
never retried and somebody has to look at them (`last_error` on the delivery says why).
`pending_events` is the backlog across consumers.

A consumer that does not answer is **not** a readiness failure: every endpoint still works and
the events wait in the outbox. A `pending` that keeps climbing is the signal that the Gateway,
or that consumer behind it, has been away for a while, or does not serve `POST /events` (a
`404`, which is retried).

`GET /status` — this copy's health and load, in the shape every Lab 3 component shares.
Service Discovery polls it directly (not through the Gateway) every 10 s with a 2 s timeout.
No credential; like the health checks it sits outside `/api/v1`, so it is **not counted by the
concurrent task limit and never answers `429`**: a copy at full load reports itself busy instead
of looking broken.

```json
{ "service": "credential", "instance_id": "credential-3f4e2a9b1c7d", "version": "3.0.0",
  "status": "up", "in_flight": 3, "max_concurrent_tasks": 64 }
```

| Situation | HTTP | `status` |
| --- | --- | --- |
| MongoDB answers a ping within 1 s | `200` | `up` |
| it does not | `503` | `degraded`, same body |

`in_flight` is the number of requests under `/api/v1` holding a slot of the concurrent task
limit right now; Service Discovery divides it by `max_concurrent_tasks` and alerts at 80 %.
The relay and the consumers play no part here. Its access-log line is at `debug`, like the
health checks'.

### 5.7 Error codes

| Code | HTTP | When |
| --- | --- | --- |
| `VALIDATION_ERROR` | `400` | malformed request; `details` names the offending field by its **wire** name |
| `VALIDATION_ERROR` | `422` | a well-formed request describing an impossible person; `details` carries `invariant`, `side`, `reason`. The contract keeps `VALIDATION_ERROR` for `400` — see [§11](#11-divergences-from-the-cpr-contract) |
| `INVALID_EVENT` | `422` | `POST /api/v1/events` only: the event can never be applied by this service; `details.reason` says why. See [§5.5b](#55b-post-apiv1events) |
| `REQUEST_TIMEOUT` | `408` | the request ran longer than `HTTP_REQUEST_TIMEOUT` and was stopped; **nothing was changed** |
| `TOO_MANY_REQUESTS` | `429` | `MAX_CONCURRENT_TASKS` requests are already in progress; header `Retry-After: 1`; **nothing was changed** |
| `APPLICANT_NOT_FOUND` | `404` | no such applicant — including the moment before a peer's event arrives |
| `APPLICANT_ALREADY_EXISTS` | `409` | a supplied `applicant_id` is taken |
| `NOT_FOUND` | `404` | unknown route |
| `METHOD_NOT_ALLOWED` | `405` | known path, wrong method |
| `DEPENDENCY_UNAVAILABLE` | `500` | MongoDB did not answer; **nothing was changed** |
| `INTERNAL_ERROR` | `500` | anything else |

`details` is always an object, never `null`.

---

## 6. Document types and field schemas

Four types, fixed by the CPR's shared values. Every field below is required — a missing one
makes the document `incomplete`.

### `student_id_card`

| Field | Example | Notes |
| --- | --- | --- |
| `name` | `"Ion Popescu"` | |
| `student_id` | `"FAF25314"` | `{MAJOR}{yy}{g}{nn}`, regex `^[A-Z]{2,4}[0-9]{5}$` |
| `faculty` | `"FCIM"` | resolved from the programme |
| `major` | `"FAF"` | equals the identifier's alphabetic prefix |
| `valid_until` | `"2029-06-30"` | end of the nominal four-year programme |

Present when the applicant claims a student identifier.

### `university_email`

| Field | Example | Notes |
| --- | --- | --- |
| `name` | `"Ion Popescu"` | |
| `email` | `"ion.popescu@isa.utm.md"` | |
| `groups` | `["faf-students", "faf-253"]` | derived from the identifier; the group never travels as a separate field |
| `issued_at` | `"2025-09-01"` | the September the mailbox was opened |

Present when the claimed address is on a university domain (`isa.utm.md` or `utm.md`). Alumni
and outsiders carry personal addresses and so present no mailbox printout — informative, and
not a defect.

Staff get `groups: ["staff"]`; teaching assistants get `["teaching-assistants", "<group>"]`.

### `enrollment_confirmation`

| Field | Example | Notes |
| --- | --- | --- |
| `name` | `"Ion Popescu"` | |
| `student_id` | `"FAF25314"` | |
| `academic_year` | `"2026-2027"` | first component is `REFERENCE_YEAR` |
| `year` | `2` | the claimed study year |
| `confirmation_number` | `"FCIM-2026-04821"` | the registry reference — see [§11](#11-divergences-from-the-cpr-contract) |
| `issued_at` | `"2026-09-01"` | |

Present when the applicant claims current enrolment, or is an alumnus still carrying their
final confirmation (whose `academic_year` is then their last one, and therefore `expired`).

### `course_registration`

| Field | Example | Notes |
| --- | --- | --- |
| `name` | `"Ion Popescu"` | |
| `student_id` | `"FAF25314"` | |
| `academic_year` | `"2026-2027"` | |
| `semester` | `"autumn"` | |
| `courses` | `[{"code": "POO", "title": "Programarea Orientată pe Obiecte"}]` | `code` is the course identifier from the shipped catalog, which is the CPR's [`shared/courses.json`](../shared/courses.json) plus `LEN1` ([§11](#11-divergences-from-the-cpr-contract)); `title` is informative |
| `issued_at` | `"2026-09-01"` | |

Present when the applicant claims any courses.

### Which documents an applicant brings

Composition follows the *claim*, field by field, rather than a table keyed on status — so a
liar's bundle is automatically the bundle their lie requires, with no separate rule per
archetype.

| Claimed status | Bundle |
| --- | --- |
| `faf_student`, `other_major_student`, `teaching_assistant` | card + mailbox + confirmation + registration (registration only if they claim courses) |
| `alumni` | card + final-year confirmation, both `expired` |
| `staff` | mailbox only |
| `outsider` (honest) | nothing — `"documents": []` |

An outsider *claiming* to be a student produces exactly the same four papers a real student
would. That is the point.

---

## 7. Validation rules

Three passes, in this order.

### Pass 1 — difficulty may damage one document

With probability `P(defect)` — `1 → 0.08`, `2 → 0.16`, `3 → 0.26`, `4 → 0.36`, `5 → 0.45` —
one document is damaged by **editing what is printed on it**: a date run out, a required field
left blank, a name misspelled or an identifier mistyped on one paper but not another.

It never touches a status. Pass 2 then finds the damage on its own.

### Pass 2 — coherence: what the papers say

Everything here is discoverable from the documents alone, which is why these are the statuses
an honest applicant may legitimately carry.

| Status | Rule |
| --- | --- |
| `incomplete` | a required field is absent, empty or zero |
| `expired` | a card whose `valid_until` year is at or before `REFERENCE_YEAR`; a confirmation or registration whose `academic_year` started earlier |
| `inconsistent` | a document naming somebody the student card does not, or carrying a different identifier |
| `inconsistent` | the card's `major` disagrees with its own identifier's prefix |
| `inconsistent` | the confirmation's `year` is impossible for the cohort encoded in the identifier on the same page |
| `inconsistent` | a registered course `code` is not in the catalog, is not taught on the claimed programme, or is not in the claimed year |
| `inconsistent` | a university address that cannot have come from the name beside it (collision ordinals allowed) |

The cohort check is a **range** check, not equality:
`year ∈ {Y − admission, Y − admission + 1} ∩ [1,4]`, where `Y` is the academic year the
document itself covers. A claim outside that window is provably false from the papers; a claim
inside it can still be false, and only the enrollment list can say so.

### Pass 3 — forgery: the claim against the truth

Runs only when the event carried an `actual` profile. Each diverging field is mapped to the
document that **asserts** it with authority:

| Diverging field | Document marked `forged` | Problem |
| --- | --- | --- |
| `student_id` | `student_id_card` | `Student ID X was never issued to this person` |
| `name` | `student_id_card` | `No student card was ever issued to X` |
| `major` | `student_id_card` | `The registry lists this person under programme Y` |
| `email` or `university_status` | `university_email` | `No mailbox exists for X` |
| `student_id` or `university_status` | `enrollment_confirmation` | `The confirmation number does not exist` |
| `year` | `enrollment_confirmation` | `The enrollment list shows year N for this student` |
| `name` | `enrollment_confirmation` | `The enrollment list has no record for X` |
| `student_id` or `university_status` | `course_registration` | `No course registration exists for student ID X` |
| `courses` | `course_registration` | `No registration exists for A, B` |
| `role` | *(none — no document prints it)* | |

So an email fabricator's card stays clean and only their mailbox printout is forged, while an
outsider impersonating a student has every paper forged.

### Severity

A document with several problems reports the worst:

```
forged  >  inconsistent  >  expired  >  incomplete  >  valid
```

All the problems are listed, whatever the status.

### Two guarantees

- **An honest applicant is never forged.** The contract says so. It holds by construction —
  pass 3 iterates a diff that is empty — and a property test runs a thousand generated
  applicants across every difficulty to keep it true.
- **Every non-`valid` status names at least one problem, and every `valid` document names
  none.** A verdict a moderation team cannot explain is a verdict they cannot act on.

---

## 8. Events

### 8.1 Transport

Direct HTTP push through the Gateway, as the CPR README "Event delivery" defines it. There is
no broker.

- **Producer side.** `POST /applicants/next` writes the applicant and the envelope of its
  `applicant.initialized` into the same document, with one pending delivery per consumer. A
  background relay then pushes the stored bytes, unchanged, to
  `POST {gateway}/api/v1/applicant/events` and `POST {gateway}/api/v1/university-record/events`
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
  circuit breaker ([§8.6](#86-several-instances-and-the-circuit-breaker)).
- **Consumer side.** `POST /api/v1/events` ([§5.5b](#55b-post-apiv1events)), reached as
  `{gateway}/api/v1/credential/events`, service token only.
- **No ordering guarantee**, and at-least-once delivery ([§8.5](#85-delivery-guarantees)).

### 8.2 Envelope

```json
{ "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "applicant.initialized",
  "occurred_at": "2026-09-10T18:10:00Z",
  "producer": "credential-service",
  "version": 1,
  "payload": { }
}
```

### 8.3 Published: `applicant.initialized`

Sent only when this service was the first to meet the applicant — i.e. from its own
`POST /api/v1/applicants/next`. Consumed by Applicant Service and University Record Service.

```json
{ "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "initialized_by": "credential-service",
  "difficulty": 3,
  "claimed": { "name": "Ion Popescu", "student_id": "FAF25314", "email": "ion.popescu@isa.utm.md",
               "major": "FAF", "year": 2, "university_status": "faf_student",
               "courses": ["POO", "SDA"], "role": "student" },
  "actual":  { "name": "Ion Popescu", "student_id": null, "email": "ion.popescu99@gmail.com",
               "major": null, "year": null, "university_status": "outsider",
               "courses": [], "role": "guest" } }
```

Both halves travel together: Credential builds documents from `claimed` and University Record
builds the hidden records from `actual`. Ship one without the other and neither peer can do
its job. `courses` is always an array, never `null`. `occurred_at` is whole seconds in UTC.

### 8.4 Consumed: `applicant.initialized`

From Applicant Service or University Record Service, on `POST /api/v1/events`. The bundle is
built from `claimed`, and judged against `actual`.

- Events whose `initialized_by` is `credential-service` are **ignored** and answered `200` —
  our own, which the contract never pushes back.
- `actual` is read **leniently**: a peer that omits it is not refused. Nothing can be forged
  without it, but the applicant is still visible.
- An envelope that cannot be parsed, of another `event_type` or `version`, or a payload
  missing `applicant_id`, `initialized_by` or a claimed name, is answered `422 INVALID_EVENT`
  — it will not read any better on a retry, so the producer parks it.
- MongoDB not answering, or the task timeout, is `500` / `408`, and the producer retries with
  backoff. The same event may therefore arrive again, which is why ingest is an insert keyed
  on `applicant_id`: the repeat is answered `200` with `"duplicate": true` and changes nothing.

### 8.5 Delivery guarantees

Publishing goes through an outbox embedded in the applicant's own document
([§9](#9-what-and-how-it-stores)), with one delivery state per consumer, so:

- an applicant is never created without their announcement being queued, and never announced
  without being created;
- one consumer being down never holds back the other: each delivery is tracked and pushed on
  its own;
- the stamp marking a delivery done is written *after* the consumer's `2xx`, so a crash in
  between pushes again rather than loses. A claim leases the delivery for a while, so a relay
  that dies mid-push hands it back on its own, and two copies never push the same delivery at
  once while the lease holds ([§8.6](#86-several-instances-and-the-circuit-breaker)). Every
  consumer in this system deduplicates on `event_id`, so a duplicate costs nothing while a lost
  event costs an applicant;
- a `422` parks the delivery for good; it is counted in `/health/ready` and never retried;
- **delivery is at-least-once.** Consumers must be idempotent. This one is.

Everything image `2.0.0` left waiting for a broker is delivered by the first `2.1.0` that
starts against the same database: at startup it opens the per-consumer deliveries for every
event still unpublished. That is one atomic `UpdateMany` matching only entries without
deliveries, so copies starting together cannot open them twice.

### 8.6 Several instances and the circuit breaker

Every copy runs a relay over the same documents. What keeps them apart:

- **The claim.** A relay finds due deliveries and takes each with its own conditional
  `UpdateOne`: the filter requires the delivery to be still due, the update moves its
  `next_attempt_at` out by `OUTBOX_LEASE` and stamps it with a claim token of its own, and only
  the relay whose update modified the document owns it. A copy that dies mid-batch hands its
  deliveries back when the lease runs out.
- **The lease covers the batch.** Pushes of one batch go one after another, so the lease must
  outlast `OUTBOX_BATCH_SIZE` × `EVENT_PUSH_TIMEOUT` (50 × 15 s = 12.5 min); the default is
  15 min and startup refuses less.
- **Only the current claim records a failure.** `attempts`, `next_attempt_at` and parking are
  updated only where the delivery's `claim_token` still matches, so a copy whose lease ran out
  cannot overwrite what the copy that took the delivery over has recorded. A `2xx` is recorded
  whoever saw it: a delivery is a fact.
- **A relay stops at a consumer's first failure.** The rest of that consumer's batch is not
  pushed; its deliveries are handed back at once, due with the failed one's retry, without
  counting an attempt - not held until the lease runs out.

**Circuit breaker, one per consumer** (Lab 3 contract). A failure is no answer within
`EVENT_PUSH_TIMEOUT` (a timeout, a refused or reset connection, a DNS failure) or any `5xx`,
the Gateway's `502` and `503` included. Any `4xx` is an answer and does not count - `429`,
`422` and the Gateway's `408` included - even though the delivery itself is retried.

| State | The relay |
| --- | --- |
| Closed | Claims and pushes as above. **3 failures within 17.5 s** (`HTTP_REQUEST_TIMEOUT` × 3.5) open it: `breaker.opened` at `warn` |
| Open | **Claims nothing for that consumer**: its deliveries stay pending and untouched, for this copy after the cooldown or for another copy whose breaker is closed. `breaker.rejected` at `debug` on every pass |
| Half-open, 17.5 s after opening | `breaker.half_open`, then **one trial push**: a claim of one delivery. Success (any answer that is not a failure) closes it, `breaker.closed`, and the backlog drains; failure opens it again for another 17.5 s |

The breaker only logs and stops calling. This service never tells Service Discovery about it:
it reaches its consumers through the Gateway and cannot name one of their instances, and the
Gateway's own breaker marks failing instances down. The service has no synchronous outbound
call, so the contract's `500 DEPENDENCY_UNAVAILABLE` for an open breaker never arises here: the
relay simply leaves the deliveries pending.

---

## 9. What and how it stores

MongoDB, database `credential_db`, **one document per applicant** in `applicants`:

```json
{ "_id": "5d2c8e4a-…",
  "session_id": "3a7e9b1c-…",
  "difficulty": 3,
  "origin": "generated | event | manual",
  "initialized_by": "credential-service",
  "claimed": { }, "actual": { },
  "documents": [ { "document_id": "…", "type": "student_id_card",
                   "fields": { }, "validation_status": "forged", "problems": [ ] } ],
  "outbox":    [ { "event_id": "…", "event_type": "applicant.initialized",
                   "routing_key": "applicant.initialized", "envelope": "<bytes>",
                   "created_at": "…", "published_at": null,
                   "deliveries": [ { "consumer": "applicant", "attempts": 0,
                                     "next_attempt_at": "…", "delivered_at": null, "parked_at": null },
                                   { "consumer": "university-record", "attempts": 2,
                                     "next_attempt_at": "…", "delivered_at": null, "parked_at": null,
                                     "last_status": 404, "last_error": "university-record answered 404: …" } ] } ],
  "is_honest": false, "lie_archetype": "outsider_impersonates_student",
  "created_at": "…", "updated_at": "…" }
```

**Why the event lives inside the applicant.** MongoDB gives no multi-document transaction
without a replica set, but a write to *one* document is always atomic. Embedding the outbox
entry buys the transactional-outbox guarantee — applicant and announcement durable at the same
instant — without asking every teammate to run a replica set to demo the system. Each entry
carries one `deliveries` element per consumer, which is the relay's unit of work;
`published_at` is set once every consumer has the event. `routing_key` predates HTTP delivery
and simply repeats the event type. Since `3.0.0` an entry also keeps `request_id`, the
`X-Request-ID` of the request that created it, sent with every push, and a delivery being
pushed carries `claim_token`, the claim that holds it ([§8.6](#86-several-instances-and-the-circuit-breaker)).
Documents written by earlier images simply lack both fields; no migration is needed.

A second collection, `email_reservations`, keys each allocated address by `_id`. The address
*is* the primary key, so two requests racing for the same name cannot both win. This is how
the contract's "does any applicant-data service already hold this address" is answered locally:
the store is the union of what this service generated and every address it ingested from a
peer's event.

**Only truthful university addresses are registered.** A liar's fabricated address is
deliberately left out — its absence from the group lists is exactly the tell a junior moderator
with the `email-groups` scope discovers.

**Indexes** (created at startup, idempotently): `session_id + created_at`, `created_at`,
a partial index on deliveries still owed (`outbox.deliveries.next_attempt_at`), and
`session_id + actual.university_status` for impersonation victims.

**`actual` never leaves the service.** It is stored because validation is computed at ingest —
the one moment the truth is available — and because the email namespace is answered from it.
No response type in this service has a field for it.

**Retention.** Nothing is deleted automatically. A shift's applicants stay until somebody
removes them.

---

## 10. Interaction flows

Every call below, event pushes included, passes through the Gateway: the caller sends
`{gateway}/api/v1/<prefix>/...`, and the paths shown are the service's own (see the CPR README
"Gateway").

### 10.1 Session Service asks Applicant Service for the next applicant

```
Session → Applicant:   POST /api/v1/applicants/next
Applicant → Credential: POST /api/v1/events  (applicant.initialized, through the Gateway)
Credential:            builds the bundle from `claimed`, marks forgeries against `actual`
```

Between the `201` and the bundle existing here there is a window of a few milliseconds. The
client's `GET /documents` may answer `404 APPLICANT_NOT_FOUND` in it, and should retry. This is
named in the contract and is not an error condition.

### 10.2 The client shows the applicant

```
Client → Applicant:    GET /api/v1/applicants/{id}         ← the claims
Client → Credential:   GET /api/v1/applicants/{id}/documents ← the papers, no verdicts
```

### 10.3 Moderation Service checks a decision

All five calls go through the Gateway with `X-Service-Token`, never with the Moderator's token.

```
Moderation → Session:            GET /api/v1/sessions/{id}
Moderation → Applicant:          GET /api/v1/applicants/{id}          ┐
Moderation → Credential:         GET .../documents/validation         ├ in parallel
Moderation → University Record:  GET .../records                      ┘
Moderation → Server Rules:       POST /api/v1/rulesets/{v}/evaluations
```

This service supplies **whether the papers hold up**, not whether the applicant is admissible.
A forged document is evidence; the verdict is Moderation's and the ruleset's.

### 10.4 Credential meets the applicant first

`POST /api/v1/applicants/next` here generates the whole person and pushes
`applicant.initialized` with `"initialized_by": "credential-service"` to
`POST {gateway}/api/v1/applicant/events` and `POST {gateway}/api/v1/university-record/events`.
Applicant Service and University Record Service build their own records from it. The relay is
covered by unit tests against a fake Gateway; the round trip against the running Applicant
Service is verified by hand.

---

## 11. Divergences from the CPR contract

Raise these in the CPR before integration.

| # | Divergence | Who is affected |
| --- | --- | --- |
| 2 | **`GET .../documents/validation` is protected only by the Gateway** and by this port being unpublished. Reading no credential in the service is correct under the contract | Gateway, Lab 2 grading |
| 3 | **`422 VALIDATION_ERROR`** for an impossible person. The contract keeps `VALIDATION_ERROR` for `400` and reserves `422` for endpoint-specific codes | generic clients |
| 4 | **`courses.json` must be the CPR's [`shared/courses.json`](../shared/courses.json)**, byte-identical, with course codes matching `^[A-Z]{2,4}$`. Image `3.0.0` still ships the copy taken from Applicant Service before that file existed, and it does not match: 53 entries against the CPR's 49 - the same 49 plus `LEN1` ("Limba Engleză I", year 1, spring) for each of the four majors, a code that also breaks the format. Its `fake_courses.json` (`ELSE-NET`, `QBIT-101`, `WEB5`, …) does not follow the format either | University Record Service, Moderation |
| 5 | **Five CRUD endpoints exist beyond the contract** (`GET` list, `POST`, `GET`, `PATCH`, `DELETE`) | gateway and auth — see [§13](#13-gateway-requirements) |
| 6 | **`POST /api/v1/applicants` does not produce `applicant.initialized`** | anyone expecting every applicant to be announced |
| 7 | **The contract read endpoints do not use the `{items, total}` list envelope.** The API conventions prescribe it for lists; both document endpoints are specified with `{applicant_id, documents}` and the endpoint spec wins. The extension list endpoint does use `{items, total}` | anyone writing a generic client |
| 8 | **Forgery is mapped to the document that asserts the claim**, not smeared across the bundle ([§7](#7-validation-rules)). The contract says "the documents that support the false claim"; this table is the reading of *which* | Moderation Service |
| 9 | **`POST /api/v1/events` deduplicates on `applicant_id`, not `event_id`** ([§5.5b](#55b-post-apiv1events)). The contract says a consumer "remembers the `event_id` values it has seen"; keying on the document's primary key gives the same idempotency without a second collection or a transaction, and additionally folds two producers announcing the same applicant into one | nobody in practice; noted for the record |

Lab 3 (`3.0.0`) follows the team decisions of 2026-10-27 for the status endpoint, logging,
registration and the circuit breaker; issue #71, which writes them into the README contract, was
not merged when this image was built. Two additions on top of them, neither of which changes an
answer: the breaker logs its move to half-open as `breaker.half_open`, and routine heartbeats
are logged at `debug` as `sd.heartbeat`.

The document field schemas of [§6](#6-document-types-and-field-schemas), including
`confirmation_number` and `course_registration.courses[] {code, title}`, are now part of the
CPR contract and no longer a divergence.

### An observation for the team, not a divergence

Recorded in the CPR as a "Known gap" next to Moderation's expected-action table.

The contract says every field where `claimed` and `actual` differ makes the supporting
documents `forged`, and Moderation's expected-action table is first-match-wins with
`forged → ban` at the top. Read together, **every lying applicant produces at least one forged
document and therefore a ban**, which leaves `reject` and `flag` reachable only through
difficulty-driven defects.

This service implements the contract as written. If the team wants the full verdict range in
play, the change belongs in Moderation's table or in the CPR's forgery rule — not in a silent
deviation here.

---

## 12. Edge cases and failure modes

### 12.1 The eventual-consistency window

Right after a peer creates an applicant, `GET /documents` answers `404` until the event
arrives — the relay's poll interval plus one round trip normally, longer if the Gateway or
the producer was down. Clients retry. This is the documented cost of no cross-service writes.

### 12.2 The Gateway or a consumer is away

The service starts, serves every endpoint and keeps creating applicants. The deliveries owed
to the consumer that cannot be reached wait in the outbox and go out when it answers again,
oldest first; the other consumer is served all along. `/health/ready` stays `200 ok` with a
climbing `consumers.<name>.pending`, and the relay retries with a backoff that doubles up to
30 s, so a consumer down for a minute sees a handful of attempts rather than hundreds. A
consumer that answers `404` because it does not serve `POST /events` is treated the same.

After 3 failures within 17.5 s (no answer, or a `5xx` such as the Gateway's `502`/`503`) that
consumer's circuit breaker opens: the relay stops claiming its deliveries, tries one trial push
every 17.5 s, and drains the backlog once a trial is answered
([§8.6](#86-several-instances-and-the-circuit-breaker)). The other consumer is not affected.

No peer events arrive while the Gateway is away; they wait in the producers' outboxes.

### 12.3 MongoDB is away

`/health/ready` answers `503` and reads and writes return
`500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "mongodb"`. Nothing is changed.

### 12.4 The same event arrives twice

Ingest is an insert keyed on `applicant_id`, so the second arrival changes nothing and is
answered `200` with `"duplicate": true`. No read-then-write race to lose.

### 12.5 A peer sends a profile we would never generate

Accepted as it comes. Only applicants this service generated are held to its own coherence
invariants; a peer must never be able to poison the consumer with a constraint failure. A
claimed profile may legitimately be incoherent — that is what a liar looks like.

### 12.6 A peer omits `actual`

Accepted. The bundle is built and judged for coherence, but nothing can be forged: an
unverifiable claim is not a proven forgery.

### 12.7 A malformed or foreign student identifier

Parsing is deliberately tolerant. A malformed identifier does not stop a bundle from being
built; it produces a bundle whose defects the validator then names. A peer encoding identifiers
slightly differently should produce a *flag*, not a hard failure.

### 12.8 Rebuilding is stable

The parts of a document that are neither claimed nor derivable — the confirmation number, which
defect was injected — are seeded from the `applicant_id`. Rebuilding the same applicant after a
`PATCH` that fixes a spelling does not silently reroll everything else.

---

## 13. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `credential`:

- **`GET .../documents/validation` must never reach a player.** It is the answer key. The
  Gateway admits it only with `X-Service-Token`, together with `POST /applicants/next` and
  `POST /events`; `GET .../documents` takes the player's `Authorization: Bearer <jwt>`. This
  service checks nothing itself, so the Gateway is the only guard.
- The five extension endpoints are administrative: service token only. `POST` and `PATCH` can
  manufacture any applicant at all.
- `GET .../documents` is the only genuinely player-facing endpoint.
- `/health` and `/health/ready` are infrastructure and sit outside `/api/v1`; they should not
  be routed publicly. Neither should `/status`: Service Discovery polls it directly inside the
  network.
- Every response, including errors, is JSON. Rate limiting, if added, should keep the
  `{"error":{"code","message","details"}}` envelope so clients need only one error path.

---

## 14. Running several instances

**The HTTP layer is stateless.** No sessions, no sticky routing, no in-memory per-client state,
so the Gateway spreads requests over the copies round-robin. The team compose runs 2 copies
(`deploy.replicas: 2`) against the one database; `docker compose up -d --scale
credential-service=3` adds a third. Every answer is the same whichever copy gives it.

**Registration with Service Discovery.** Each copy registers itself as soon as its listener is
up, directly with Service Discovery and not through the Gateway:

```
PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/credential-<hostname>
X-Service-Token: {SERVICE_TOKEN}
{"service_name": "credential", "port": 8082, "version": "3.0.0"}     (+ "host" only with INSTANCE_HOST)
```

The same `PUT` is repeated every 5 s as the heartbeat; Service Discovery forgets a copy it has
not heard from for 15 s, and the first `PUT` after a Service Discovery restart registers it
again. Every call has a 2 s timeout, and a failure only logs `sd.heartbeat_failed` - it never
touches a request. On `SIGTERM` / `SIGINT` the copy stops its heartbeat, sends
`DELETE /api/v1/instances/{instance_id}` (2 s at most), and only then stops accepting HTTP,
drains in-flight requests, stops the relay and disconnects from MongoDB.

| Concern | Behaviour |
| --- | --- |
| Indexes at startup | `CreateMany` on every start; creating an index that already exists is a no-op, so copies starting together all succeed and all start |
| Backfill at startup | One atomic `UpdateMany` that matches only entries without deliveries: copies starting together cannot open them twice |
| `POST /api/v1/events` | The dedup is the `applicant_id` primary key: a second insert of the same applicant is a duplicate-key error, answered `200` with `"duplicate": true`, whichever copy receives it |
| Email namespace | `email_reservations` is keyed on the lower-cased address, so two copies racing for one name cannot both win; reservations carry the applicant id and are handed back when the applicant is not stored |
| Outbox relay | Per-delivery conditional claims with a lease covering the whole batch and a claim token ([§8.6](#86-several-instances-and-the-circuit-breaker)) |
| Circuit breakers | One per consumer in each copy, in memory. They decide when that copy pushes, never what a request answers - the one piece of state per process besides the task limiter and the connection pool |
| Generator | `GENERATOR_SEED=0` (the default) in any multi-copy deployment; a fixed seed makes every copy generate the same applicants in lockstep |

**Connection budget:** each copy opens up to `DB_MAX_POOL_SIZE` (20) MongoDB connections; three
copies use at most 60, well within a standalone MongoDB's limit.

**Personal addresses are drawn, not reserved.** A university address is unique across all
copies. The personal address of an alumnus or an outsider is drawn from 40 first names × 40 last
names × 4 domains × a two-digit suffix, 633,600 combinations, and is not reserved, so two
applicants can share one: about a 1 % chance after 100 such applicants, about 50 % after 1,000.
It is the same with one copy or three, and this service treats a personal address as plain
profile data, never as a key.

---

## 15. Observability

**Logs** are one JSON object per line on stdout, in the shape every Lab 3 component shares,
whatever `APP_ENV` says. Level from `LOG_LEVEL`. Every line carries `time` (ISO 8601 UTC with
milliseconds), `level` (`debug`, `info`, `warn`, `error`), `service` (`credential`),
`instance_id` (which copy wrote it), `version`, `event` (a stable name, below) and `msg`, plus
`request_id` on every line written while handling a request and on the relay's lines for a
push.

```json
{"time":"2026-10-27T12:00:00.123Z","level":"info","msg":"request","service":"credential","instance_id":"credential-3f4e2a9b1c7d","version":"3.0.0","event":"http.request","method":"GET","path":"/api/v1/applicants/5d2c8e4a-…/documents","status":200,"duration_ms":7,"client_ip":"172.18.0.9","player_id":"8c1f6a2e-…","request_id":"9d2d…"}
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
| `applicant.created` / `.updated` / `.deleted` | `info` | `applicant_id`, `session_id`, `origin`, `event_id` for one created from an event, the archetype and document count of a generated one | Every change to an applicant |
| `config`, `db`, `relay`, `email.record_failed`, `email.release_failed`, `generator.retry`, `generator.fallback` | as fits | | Configuration gaps, the database connection and indexes, outbox bookkeeping errors, the email namespace, generator edge cases (`generator.fallback` is a bug) |

**Never logged:** `X-Service-Token`, the MongoDB URI (it carries the credentials), request or
response bodies, and anything of an applicant's profile - lines name applicants by
`applicant_id` only.

**No metrics endpoint and no tracing.** `/health/ready` exposes `pending` and `parked` per
consumer, and `GET /status` the load of one copy.
