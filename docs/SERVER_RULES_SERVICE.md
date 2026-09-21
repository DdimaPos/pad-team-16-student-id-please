# Server Rules Service - Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1), or the gateway. Documents what this service does, how to run it,
> how to talk to it, and what it does not do. Where the implementation diverges from the
> CPR contract, the divergence is called out explicitly in [§7](#7-divergences-from-the-cpr-contract).

---

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Running it](#3-running-it)
4. [Configuration](#4-configuration)
5. [HTTP API](#5-http-api)
6. [The condition DSL](#6-the-condition-dsl)
7. [Divergences from the CPR contract](#7-divergences-from-the-cpr-contract)
8. [Edge cases](#8-edge-cases)
9. [Notes for a gateway](#9-notes-for-a-gateway)
10. [Recipes for testing against it](#10-recipes-for-testing-against-it)

---

## 1. What this service is

Server Rules Service owns the current, versioned ruleset for Discord-server admission and
channel access. It is the **only fully standalone service in the system**: it calls no other
service, publishes no event, consumes no event, and stores nothing about applicants
(`applicant_id` in an evaluation request is used only for logging).

### Boundary

- **Owns:** the versioned ruleset - admission rules and channel rules, keyed by `version` and
  `difficulty`.
- **Does not own:** the admission decision itself (Moderation Service), any applicant data.
- **Calls:** nothing. Zero outbound dependencies.
- **Is called by:** Server Moderation Session Service (`GET /rulesets/current` - on the
  critical path of every shift start), Moderation Service (`POST /rulesets/{v}/evaluations`),
  the game client (`GET /rulesets/{version}`).

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | C# / .NET 10, ASP.NET Core minimal APIs |
| **Container port** | `8080` (mapped to host `8083` by convention) |
| **Base path** | `/api/v1` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness) |
| **Database** | PostgreSQL, `rules_db` (own container, host port `5434`) |
| **Broker** | none - this service never touches RabbitMQ |
| **Authentication** | Public endpoints are open. Admin endpoints (`/api/v1/admin/*`) require `X-Service-Token` |
| **Docker image** | `d1vinexd/server-rules-service:0.1.0` (also tagged `:latest`), public on Docker Hub |
| **Architecture** | Clean Architecture, five projects: `Domain` (pure - the condition DSL, evaluator, channel resolver), `Repositories` (interfaces), `Services` (use cases), `Infrastructure` (EF Core + Npgsql), `Api` (minimal APIs) |

---

## 3. Running it

### From the published image (recommended for teammates)

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name server-rules-service --network student-id-net \
  -p 8083:8080 \
  -e ConnectionStrings__RulesDb="Host=<postgres-host>;Port=5432;Database=rules_db;Username=rules_user;Password=<password>" \
  -e Auth__ServiceToken="<shared-secret>" \
  d1vinexd/server-rules-service:0.1.0
```

Or use the team compose in the CPR root (`docker-compose.yml`), which wires this service and
its own `rules-postgres` container together on `student-id-net`.

### From source (development)

Requires .NET 10 SDK and Docker (for Postgres).

```bash
cd server-rules-service
cp .env.example .env        # fill in real values
docker compose up -d        # builds from source, starts its own postgres
```

On startup the service applies EF Core migrations and seeds five rulesets (one per
difficulty 1-5) if the table is empty - this is a correctness requirement, not a
convenience: the contract defines no endpoint to create a ruleset, and
`GET /rulesets/current` must never fail to answer for a valid difficulty, since Server
Moderation Session Service keeps a shift in the lobby otherwise.

---

## 4. Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `ConnectionStrings__RulesDb` | - | **yes** | Npgsql connection string |
| `Auth__ServiceToken` | - | **yes** (for admin routes) | Shared secret required as `X-Service-Token` on `/api/v1/admin/*` |
| `Rules__StrictFactShape` | `false` | no | See [§7](#7-divergences-from-the-cpr-contract) - whether an inconsistent fact (e.g. `major` on a `staff` applicant) is a `422` or silently nulled out |

---

## 5. HTTP API

### 5.1 Contract endpoints

| Method | Path | Consumed by |
| --- | --- | --- |
| `GET` | `/api/v1/rulesets/current?difficulty={1..5}` | Server Moderation Session Service |
| `GET` | `/api/v1/rulesets/{version}` | Game client |
| `POST` | `/api/v1/rulesets/{version}/evaluations` | Moderation Service |

`POST .../evaluations` request/response shapes are exactly as specified in the CPR README.
**Error precedence:** `404 RULESET_NOT_FOUND` is checked **before** facts validation - the
ruleset is the resource being addressed, so a bad version wins over bad facts.

### 5.2 Extension endpoints (beyond contract - Lab 1 CRUD requirement)

All under `/api/v1/admin/rulesets`, guarded by `X-Service-Token`. **Never exposed to
players.**

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/admin/rulesets` | Create a new version. Body: `difficulty`, `notes?`, `rules[]`, or `clone_from_version` + a `rules[]` patch (rules matching an existing `rule_id` are replaced, others carry over, new ones are appended) |
| `GET` | `/admin/rulesets?difficulty=&active=&limit=&offset=` | List - the contract has no list endpoint at all |
| `GET` | `/admin/rulesets/{version}` | Full detail **including the jsonb conditions**, which the public endpoint deliberately omits |
| `PATCH` | `/admin/rulesets/{version}` | **Only `is_active` and `notes`.** Rules are never patched - a rule change is always a new version, since Moderation snapshots `ruleset_version` behind every verdict |
| `DELETE` | `/admin/rulesets/{version}` | Soft delete |

`PATCH`/`DELETE` return `409 LAST_ACTIVE_RULESET` if the change would leave a difficulty
1-5 with no active ruleset.

### 5.3 Error codes

Standard envelope `{ "error": { "code", "message", "details" } }`. Codes used:
`VALIDATION_ERROR` (400), `INVALID_DIFFICULTY` / `INVALID_FACTS` / `INVALID_RULESET` (422),
`RULESET_NOT_FOUND` (404), `LAST_ACTIVE_RULESET` (409), `UNAUTHENTICATED` /
`INVALID_SERVICE_TOKEN` (401), `INTERNAL_ERROR` (500).

---

## 6. The condition DSL

Rule conditions are stored as jsonb and are **not part of the public contract** - the public
`GET /rulesets/*` endpoints return only `{ rule_id, kind, description }` per rule. The admin
detail endpoint exposes the full DSL. Grammar:

```jsonc
{ "op": "always" }
{ "op": "and" | "or", "of": [ <pred>, ... ] }
{ "op": "not", "of": [ <pred> ] }
{ "op": "eq" | "neq", "fact": "university_status", "value": "faf_student" }
{ "op": "in", "fact": "university_status", "values": [...] }
{ "op": "gte" | "gt" | "lte" | "lt", "fact": "years_enrolled", "value": 2 }
{ "op": "is_null" | "not_null", "fact": "year" }
```

`fact` is one of exactly six names: `university_status`, `major`, `year`, `years_enrolled`,
`currently_enrolled`, `previously_banned`.

**Null semantics - the one subtlety.** A comparison against a null fact (major/year for
staff/outsider/alumni-year) evaluates to `false`, never "unknown". Consequence:
`not(eq(year, 1))` is **true** for staff, because `eq(year, 1)` is false and `not` flips it.
To mean "definitely not a first-year", a rule must write
`and(not_null(year), neq(year, 1))`.

**Channel derivation is grant-based with a deny overlay.** Start from the empty set; matching
`channel` rules add to `grant`, matching rules also add to `deny`; `deny` wins. A status
nobody wrote a rule for gets **zero** channels, not everything - the fail-safe default in a
game about not letting the wrong people in.

**Only `admission` rules can ever appear in `violated_rules`.** A `channel` rule contributes
to grants/denies and can never "fail".

---

## 7. Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | The contract defines **no way to create a ruleset**, yet says rules "can be edited between shifts". Resolved as: an admin CRUD surface (§5.2), with rulesets **immutable once published** - "editing" means creating a new version | Anyone reading only the public contract |
| 2 | `version` is **one global monotonic sequence** shared across all five difficulties (not five independent sequences) - required because `GET /rulesets/{version}` takes no `difficulty` parameter, so a per-difficulty sequence would make that endpoint ambiguous | Anyone assuming version numbers are per-difficulty |
| 3 | `Rules__StrictFactShape` defaults to **lenient**: an inconsistent fact (e.g. `major` present for `staff`) is nulled out with a warning, not rejected with `422`. Moderation Service builds these facts; a strict default would deadlock the whole decision flow at integration time over a field this service can safely ignore | Moderation Service |
| 4 | The seeded rulesets for difficulties 1, 2, 4, 5 are **this service's own design** - only difficulty 3 is specified by the contract (verbatim). See the service's own README for the full seed content | Anyone expecting a specific ruleset at another difficulty |

---

## 8. Edge cases

- **`GET /rulesets/current` must never fail to answer** for a valid difficulty 1-5. The
  seeder asserts this at startup and the service refuses to start otherwise.
- **Rulesets are immutable.** `GET /rulesets/{version}` for a soft-deleted or deactivated
  version still returns it - `is_active`/`deleted_at` only affect whether it can be `current`.
- **Wiping the Postgres volume resets the version counter** to 1, silently invalidating any
  snapshot a peer holds of an older `ruleset_version`. Do not drop the volume between demos.

---

## 9. Notes for a gateway

- Every contract endpoint (`/rulesets/*`, `/evaluations`) is open - no authentication, matching
  the team-wide "authentication is out of scope for now" convention.
- Admin endpoints require `X-Service-Token` and must never be routed to a player-facing
  gateway path.
- No CORS headers, no rate limiting, no `Idempotency-Key` support. `POST /evaluations` and
  `POST /admin/rulesets` are not idempotent - two identical requests create two things (a log
  line; a new ruleset version, respectively). Safe to retry: every `GET`, `PATCH`, `DELETE`.

---

## 10. Recipes for testing against it

```bash
BASE=http://localhost:8083

# The contract's own worked example
curl -s "$BASE/api/v1/rulesets/current?difficulty=3" | jq
curl -s -X POST "$BASE/api/v1/rulesets/3/evaluations" -H 'Content-Type: application/json' -d '{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "facts": { "university_status": "faf_student", "major": "FAF", "year": 1,
             "years_enrolled": 1, "currently_enrolled": true, "previously_banned": false }
}' | jq
# => { "ruleset_version": 3, "admitted": true, "violated_rules": [], "allowed_channels": ["general"] }
```

The full Postman collection (`postman/server-rules-service.postman_collection.json` in the
CPR) covers every endpoint including the admin surface and every error branch.

---

*Server Rules Service is owned by Titerez Vladislav. See the service's own repository README
for build/test instructions and the full seeded-ruleset content.*
