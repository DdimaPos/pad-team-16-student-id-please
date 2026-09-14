# Credential Service — Integration Reference

Everything another service, a gateway or a teammate needs in order to work with this service,
without reading its source.

Team 16 · *Student ID, please* · FAF.PAD21.1 · version `1.0.0`

For "how do I start it", see [README.md](../credential-service/README.md). This document is the contract.

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
13. [Notes for a gateway or auth layer](#13-notes-for-a-gateway-or-auth-layer)

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
| **Calls** | nothing. No outbound HTTP at all |
| **Is called by** | the game client (`/documents`) and Moderation Service (`/documents/validation`) |
| **Listens to** | `applicant.initialized`, from Applicant Service or University Record Service |
| **Publishes** | `applicant.initialized`, only when it was the first service to meet the applicant |

---

## 2. Integration card

| | |
| --- | --- |
| Base path | `/api/v1` |
| Port | `8082` |
| Health | `GET /health`, `GET /health/ready` |
| Database | MongoDB, `credential_db` |
| Exchange | `student-id.events` (topic, durable) |
| Queue | `credential-service.applicant-initialized` |
| Dead letters | `student-id.dlx` → `credential-service.dlq` |
| Producer name | `credential-service` |
| Image | `stewdh/credential-service:1.0.0`, also `:latest` (linux/amd64, linux/arm64) |
| Error envelope | `{"error":{"code","message","details"}}` |
| Timestamps | ISO 8601, UTC, whole seconds |
| Identifiers | UUID v4 strings |

**Hard dependency:** MongoDB only. The broker is optional at runtime — see
[§12.2](#122-the-broker-is-away).

---

## 3. Ports and networking

| Port | What |
| --- | --- |
| `8082` | the HTTP API (container and host) |
| `27018` → `27017` | MongoDB, host → container |

`8081` and `5433` belong to Applicant Service; `8082` and `27018` were chosen so both stacks
run on one laptop.

The compose network is named **`student-id-net`**, the same one Applicant Service declares, so
the two stacks see each other. RabbitMQ sits behind the `broker` compose profile and is off by
default: the team shares one broker, and a second container behind the same `rabbitmq` DNS
alias would split the event stream in a way that is genuinely hard to debug.

Inside the network the service is reachable as `credential-service:8082`.

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
| `RABBITMQ_URL` | *(empty)* | **empty disables messaging entirely** and the service still serves every endpoint |
| `RABBITMQ_EXCHANGE` | `student-id.events` | must match every other service exactly |
| `RABBITMQ_QUEUE` | `credential-service.applicant-initialized` | |
| `RABBITMQ_DLX` / `RABBITMQ_DLQ` | `student-id.dlx` / `credential-service.dlq` | |
| `RABBITMQ_PREFETCH` | `10` | |
| `PUBLISH_CONFIRM_TIMEOUT` | `2s` | |
| `OUTBOX_POLL_INTERVAL` | `500ms` | how often the relay looks for unpublished events |
| `OUTBOX_BATCH_SIZE` | `50` | |
| `RABBITMQ_RECONNECT_MAX_BACKOFF` | `30s` | |
| `APP_PORT` | `8082` | |
| `APP_ENV` | `local` | `local` / `docker` / `production`; selects log format and Gin mode |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SERVICE_VERSION` | `dev` | reported by `/health` |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` | `10s` | |
| `HTTP_REQUEST_TIMEOUT` | `5s` | per-request deadline |
| `SHUTDOWN_TIMEOUT` | `10s` | graceful drain |
| **`REFERENCE_YEAR`** | `2026` | the calendar year treated as "now". **Applicant, Credential and University Record Service must all be given the same value**, or perfectly honest applicants read as liars |
| `GENERATOR_SEED` | `0` | `0` picks a fresh sequence per boot; a fixed number reproduces a run exactly |

---

## 5. HTTP API

### 5.1 Endpoint summary

| Method | Path | Source | Consumed by |
| --- | --- | --- | --- |
| `POST` | `/api/v1/applicants/next` | contract | no service yet |
| `GET` | `/api/v1/applicants/{applicant_id}/documents` | contract | Client |
| `GET` | `/api/v1/applicants/{applicant_id}/documents/validation` | contract | Moderation Service |
| `GET` | `/api/v1/applicants` | *extension* | — |
| `POST` | `/api/v1/applicants` | *extension* | — |
| `GET` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `PATCH` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `DELETE` | `/api/v1/applicants/{applicant_id}` | *extension* | — |
| `GET` | `/health`, `/health/ready` | infrastructure | orchestrator |

### 5.2 `POST /api/v1/applicants/next`

Creates a new applicant, starting from the documents they bring. Stores the bundle, queues
`applicant.initialized`, returns the identifiers.

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

### 5.6 Health

`GET /health` → `200` whenever the process is serving. It checks no dependency on purpose:
restarting a healthy container because somebody else's database was slow would be wrong.

`GET /health/ready`:

```json
{ "status": "degraded", "service": "credential-service", "version": "1.0.0",
  "components": { "mongodb": {"status": "up"},
                  "rabbitmq": {"status": "down", "details": "dial tcp: connection refused"} },
  "pending_events": 3 }
```

| Situation | `status` | HTTP |
| --- | --- | --- |
| everything up | `ok` | `200` |
| broker away, Mongo fine | `degraded` | `200` |
| `RABBITMQ_URL` unset | `ok` (rabbitmq `disabled`) | `200` |
| Mongo unreachable | `unavailable` | `503` |

A broker outage is **not** a readiness failure: every endpoint still works and events queue in
the outbox. `pending_events` climbing is the signal to look at the broker.

### 5.7 Error codes

| Code | HTTP | When |
| --- | --- | --- |
| `VALIDATION_ERROR` | `400` | malformed request; `details` names the offending field by its **wire** name |
| `VALIDATION_ERROR` | `422` | a well-formed request describing an impossible person; `details` carries `invariant`, `side`, `reason` |
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
| `courses` | `[{"code": "POO", "title": "Programarea Orientată pe Obiecte"}]` | |
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
| `inconsistent` | a registered course exists nowhere, is not taught on the claimed programme, or is not in the claimed year |
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

- Exchange **`student-id.events`**, type `topic`, **durable**, not auto-deleted.
- Routing key **`applicant.initialized`**.
- Queue `credential-service.applicant-initialized`, durable, dead-lettered to
  `student-id.dlx` with routing key `applicant.initialized.dead`.
- Dead-letter queue `credential-service.dlq`, bound to `student-id.dlx` with `#`.
- Publishes are **persistent** with **publisher confirms**; `mandatory` is `false` — during
  integration peer queues often do not exist yet, and flagging every publish unroutable would
  bury the real failures.

> **Every service must declare the shared exchange identically** (`topic`, durable, not
> auto-delete). One mismatched declaration gives everyone `PRECONDITION_FAILED (406)`, which
> amqp091-go reports by *closing the channel*, after which publishes fail quietly. This
> service watches both connection and channel closure and surfaces it in `/health/ready`.

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

From Applicant Service or University Record Service. The bundle is built from `claimed`, and
judged against `actual`.

- Events whose `initialized_by` is `credential-service` are **ignored** — our own messages
  come back to us because the queue is bound to the exchange we publish on.
- `actual` is read **leniently**: a peer that omits it is not parked. Nothing can be forged
  without it, but the applicant is still visible.
- An envelope that cannot be parsed, or a payload missing `applicant_id`, `initialized_by` or
  a claimed name, is **parked** in the DLQ — it will not read any better on a retry.
- A transient failure is requeued **once** (bounded by the `Redelivered` flag, not a counter),
  then parked. Without that bound a message that always fails would be requeued thousands of
  times a second and look like a healthy busy consumer from outside.

### 8.5 Delivery guarantees

Publishing goes through an outbox embedded in the applicant's own document
([§9](#9-what-and-how-it-stores)), so:

- an applicant is never created without their announcement being queued, and never announced
  without being created;
- the stamp marking an event published is written *after* the broker confirms it, so a crash
  in between republishes rather than loses. Every consumer in this system deduplicates on
  `event_id`, so a duplicate costs nothing while a lost event costs an applicant;
- **delivery is at-least-once.** Consumers must be idempotent. This one is.

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
                   "created_at": "…", "published_at": null } ],
  "is_honest": false, "lie_archetype": "outsider_impersonates_student",
  "created_at": "…", "updated_at": "…" }
```

**Why the event lives inside the applicant.** MongoDB gives no multi-document transaction
without a replica set, but a write to *one* document is always atomic. Embedding the outbox
entry buys the transactional-outbox guarantee — applicant and announcement durable at the same
instant — without asking every teammate to run a replica set to demo the system.

A second collection, `email_reservations`, keys each allocated address by `_id`. The address
*is* the primary key, so two requests racing for the same name cannot both win. This is how
the contract's "does any applicant-data service already hold this address" is answered locally:
the store is the union of what this service generated and every address it ingested from a
peer's event.

**Only truthful university addresses are registered.** A liar's fabricated address is
deliberately left out — its absence from the group lists is exactly the tell a junior moderator
with the `email-groups` scope discovers.

**Indexes** (created at startup, idempotently): `session_id + created_at`, `created_at`,
a partial index on unpublished outbox entries, and `session_id + actual.university_status` for
impersonation victims.

**`actual` never leaves the service.** It is stored because validation is computed at ingest —
the one moment the truth is available — and because the email namespace is answered from it.
No response type in this service has a field for it.

**Retention.** Nothing is deleted automatically. A shift's applicants stay until somebody
removes them.

---

## 10. Interaction flows

### 10.1 Session Service asks Applicant Service for the next applicant

```
Session → Applicant:   POST /api/v1/applicants/next
Applicant → broker:    applicant.initialized
broker → Credential:   builds the bundle from `claimed`, marks forgeries against `actual`
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

`POST /api/v1/applicants/next` here generates the whole person and publishes
`applicant.initialized` with `"initialized_by": "credential-service"`. Applicant Service and
University Record Service build their own records from it. This path is implemented and
tested end to end against the running Applicant Service.

---

## 11. Divergences from the CPR contract

Raise these in the CPR before integration.

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | **`enrollment_confirmation` carries a `confirmation_number`.** The CPR's own validation example returns the problem `"The confirmation number does not exist"` for a document whose documented fields contain no such number. The field had to exist for the example to mean anything | Moderation Service, if it reads document fields |
| 2 | **The fourth document type is `course_registration`.** The Service Boundaries prose calls it "course registration proof"; the normative Shared values enum is `course_registration`, and that is what travels | anyone matching on `type` |
| 3 | **Field schemas for `course_registration` are defined here** — the CPR example only ever shows three of the four types. `courses` is an array of `{code, title}` objects | University Record Service, comparing registrations |
| 4 | **Five CRUD endpoints exist beyond the contract** (`GET` list, `POST`, `GET`, `PATCH`, `DELETE`) | gateway and auth — see [§13](#13-notes-for-a-gateway-or-auth-layer) |
| 5 | **`POST /api/v1/applicants` does not publish `applicant.initialized`** | anyone expecting every applicant to be announced |
| 6 | **The contract read endpoints do not use the `{items, total}` list envelope.** The API conventions prescribe it for lists; both document endpoints are specified with `{applicant_id, documents}` and the endpoint spec wins. The extension list endpoint does use `{items, total}` | anyone writing a generic client |
| 7 | **Forgery is mapped to the document that asserts the claim**, not smeared across the bundle ([§7](#7-validation-rules)). The contract says "the documents that support the false claim"; this table is the reading of *which* | Moderation Service |
| 8 | The identity model (`{MAJOR}{yy}{g}{nn}`, the cohort window, email rules) and `courses.json` are **shared artifacts** copied from Applicant Service. A change to either copy is a contract change | all three applicant-data services |

### An observation for the team, not a divergence

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
arrives — milliseconds normally, longer if the broker is busy or was down. Clients retry. This
is the documented cost of no cross-service writes.

### 12.2 The broker is away

The service starts, serves every endpoint and keeps creating applicants. Their events
accumulate in the outbox and drain automatically when the broker returns. `/health/ready`
reports `degraded` with a climbing `pending_events`, and the log complains once a minute
rather than on every attempt.

No peer events are consumed while it is away; they wait in the durable queue.

### 12.3 MongoDB is away

`/health/ready` answers `503` and reads and writes return
`500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "mongodb"`. Nothing is changed.

### 12.4 The same event arrives twice

Ingest is an insert keyed on `applicant_id`, so the second arrival changes nothing. No
read-then-write race to lose.

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

## 13. Notes for a gateway or auth layer

- **`GET .../documents/validation` must never reach a player.** It is the answer key. The
  contract says a request from another service carries a service token; authentication is out
  of scope for Lab 1 across the whole team, so this service enforces nothing yet. A gateway
  should gate this path until it does.
- The five extension endpoints are administrative. They should not be exposed to players
  either — `POST` and `PATCH` can manufacture any applicant at all.
- `GET .../documents` is the only genuinely player-facing endpoint.
- `/health` and `/health/ready` are infrastructure and sit outside `/api/v1`; they should not
  be routed publicly.
- Every response, including errors, is JSON. Rate limiting, if added, should keep the
  `{"error":{"code","message","details"}}` envelope so clients need only one error path.
