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
9. [Gateway requirements](#9-gateway-requirements)
10. [Recipes for testing against it](#10-recipes-for-testing-against-it)
11. [Message Broker, logs and metrics (Lab 4)](#11-message-broker-logs-and-metrics-lab-4)

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
- **Calls:** no other service. Its only outbound connections are the registration with Service
  Discovery and, from `4.0.0`, one subscription stream to the Message Broker.
- **Is called by:** Server Moderation Session Service (`GET /rulesets/current` - on the
  critical path of every shift start), Moderation Service (`POST /rulesets/{v}/evaluations`),
  the game client (`GET /rulesets/{version}`). From `4.0.0` these requests arrive from the broker's
  queue `requests.server-rules` - see [§11](#11-message-broker-logs-and-metrics-lab-4).

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | C# / .NET 10, ASP.NET Core minimal APIs |
| **Container port** | `8080` (mapped to host `8083` by convention) |
| **Base path** | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/server-rules/...` |
| **Health** | `GET /health` (liveness), `GET /health/ready` (readiness) |
| **Database** | PostgreSQL, `rules_db` (own container, host port `5434`) |
| **Events** | none - this service neither produces nor receives events, and from `4.0.0` subscribes to no broker topic |
| **Message Broker** | One gRPC `Subscribe` stream to `MESSAGE_BROKER_URL` as service `server-rules`, no topic; the broker delivers the requests of the queue `requests.server-rules` on it (`4.0.0`) - see [§11](#11-message-broker-logs-and-metrics-lab-4) |
| **Logs** | One JSON object per line on stdout, and the same lines in the rotating `LOG_FILE`, read back by `GET /logs` (`4.0.0`) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (`4.0.0`) |
| **Circuit breaker** | None: the service calls no other service, through the broker or otherwise |
| **Authentication** | Lab 3: checked by the Gateway, not here: `GET /rulesets/current`, `POST /rulesets/{v}/evaluations` and `/admin/*` only with the service token, `GET /rulesets/{version}` with a player JWT. From `4.0.0` the broker checks the token as gRPC metadata of every call and never passes it on. The contract endpoints validate no token. The routes called directly, never through the broker or the Gateway, check `X-Service-Token` themselves (CPR README "Authentication" > "Through the Message Broker", rule 4): `GET /logs` (`4.0.0`) and, from `4.0.1` (#150), `/admin/*` and `/dev/*`: `403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN` when wrong, compared in constant time with `SERVICE_TOKEN`; an empty `SERVICE_TOKEN` matches no token, so those routes stay closed. `/admin/*` and `/dev/*` refuse a request that carries `X-Player-Id` first (`403 SERVICE_TOKEN_REQUIRED`), even with the right token |
| **Docker image** | `d1vinexd/server-rules-service:4.0.1` (also tagged `:latest`), public on Docker Hub, `linux/amd64` and `linux/arm64`. `4.0.1` (#150) changes only the token check of `/admin/*` and `/dev/*`; the contract routes, the broker subscription, `/logs` and `/metrics` are those of `4.0.0` |
| **Architecture** | Clean Architecture, five projects: `Domain` (pure - the condition DSL, evaluator, channel resolver), `Repositories` (interfaces), `Services` (use cases), `Infrastructure` (EF Core + Npgsql), `Api` (minimal APIs; from `4.0.0` also `Messaging`, the broker consumer and the loopback dispatch, and the log file and metrics in `Observability`) |

---

## 3. Running it

### From the published image (recommended for teammates)

```bash
docker network create student-id-net   # once, if it does not already exist
docker run -d --name server-rules-service --network student-id-net \
  -p 8083:8080 \
  -e ConnectionStrings__RulesDb="Host=<postgres-host>;Port=5432;Database=rules_db;Username=rules_user;Password=<password>" \
  d1vinexd/server-rules-service:4.0.1
```

Without `MESSAGE_BROKER_URL` the instance takes no request from the broker and logs one
`broker.disabled` warning; its REST port answers as before.

Or use the team compose in the CPR root (`docker-compose.yml`), which wires this service and
its own `rules-postgres` container together on `student-id-net`, with `MESSAGE_BROKER_URL`
`message-broker-service:8071`.

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
| `HTTP_REQUEST_TIMEOUT` | `5` | no | Task timeout in seconds (`5` or `5s`): a longer request is cancelled and answered `408 REQUEST_TIMEOUT`. `/health*` and `/status` are exempt, and from `4.0.0` `/logs` and `/metrics` |
| `MAX_CONCURRENT_TASKS` | `100` | no | Concurrent task limit: one more request is refused at once with `429 TOO_MANY_REQUESTS` and `Retry-After: 1`, no work done. From `4.0.0` requests from the broker count too, and it is also the `max_concurrent_tasks` of the broker subscription. `/health*` and `/status` are exempt, and from `4.0.0` `/logs` and `/metrics`. The team compose sets `64` |
| `Dev__EnableTestEndpoints` | `false` | no | Mounts `GET /api/v1/dev/slow?ms=` (service-only, with `X-Service-Token` from `4.0.1`, sleeps `ms` milliseconds, at most a minute) to demonstrate the two limits above. The team compose enables it |
| `Rules__StrictFactShape` | `false` | no | See [§7](#7-divergences-from-the-cpr-contract) - whether an inconsistent fact (e.g. `major` on a `staff` applicant) is a `422` or silently nulled out |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn` or `error`. One JSON object per line on stdout and, from `4.0.0`, in `LOG_FILE` |
| `SERVICE_DISCOVERY_URL` | empty | no | Base URL of Service Discovery. Empty turns registration off |
| `INSTANCE_ID` | `server-rules-<hostname>` | no | Name of this instance in logs, `/status` and Service Discovery |
| `INSTANCE_HOST` | unset | no | Address Service Discovery polls and Prometheus scrapes (the Gateway routed to it in Lab 3), sent as `host` only when set (a run outside Docker) |
| `SERVICE_TOKEN` | - | with `SERVICE_DISCOVERY_URL` or `MESSAGE_BROKER_URL`, and for `GET /logs`, `/admin/*`, `/dev/*` | The stack's one token: sent as `X-Service-Token` to Service Discovery and, from `4.0.0`, as the gRPC metadata `x-service-token` to the broker, and the token `GET /logs` (`4.0.0`), `/api/v1/admin/*` and `/api/v1/dev/*` (`4.0.1`) check. Empty: those routes refuse every request. The contract routes do not check it |
| `MESSAGE_BROKER_URL` | empty | yes in the team stack | `4.0.0`. The broker's gRPC target without a scheme (team stack: `message-broker-service:8071`). Empty turns the request consumer off, with one `broker.disabled` warning: no request reaches the instance through the broker |
| `LOG_FILE` | `/var/log/server-rules/server-rules.jsonl` | no | `4.0.0`. The log file `GET /logs` reads; the image creates the directory for its non-root user. Empty: stdout only, and `GET /logs` answers `503 LOGS_UNAVAILABLE`. A path that cannot be written logs one `logs.file_unavailable` warning and leaves stdout only |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | no | `4.0.0`. The file rotates at this size (`server-rules_001.jsonl`, `_002`, ...); this many rotated files are kept next to the current one |

`Auth__ServiceToken` of `0.1.0` is gone: the one credential the service checks is `SERVICE_TOKEN`, on `GET /logs`, `/admin/*` and `/dev/*` only (§2).

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

From `4.0.0` these requests arrive from the broker's queue
`requests.server-rules` and are dispatched to the same routes over loopback, so the paths, payloads and
answers are unchanged - see [§11](#11-message-broker-logs-and-metrics-lab-4). The REST port still
serves every route. `/admin/*` and `/dev/*` are called on it directly only, with `X-Service-Token`
(`4.0.1`, §5.2): through the broker, which never passes the token on, they are refused.

### 5.2 Extension endpoints (beyond contract - Lab 1 CRUD requirement)

All under `/api/v1/admin/rulesets`, for services only, called directly on the instance inside
`student-id-net` (not a route of the Lab 4 Gateway, §9). From `4.0.1` (#150) the service checks
`X-Service-Token` itself: `403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN` when
wrong. Through the broker they are refused, since no request there carries the token. A request that
carries `X-Player-Id` is refused first (`403 SERVICE_TOKEN_REQUIRED`), even with the right token. The
same holds for `/api/v1/dev/*`. **Never exposed to players.**

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
`RULESET_NOT_FOUND` (404), `LAST_ACTIVE_RULESET` (409), `SERVICE_TOKEN_REQUIRED` (403, `/admin/*` and
`/dev/*` called with `X-Player-Id`, or from `4.0.1` without `X-Service-Token`), `INVALID_SERVICE_TOKEN`
(401, `/admin/*` and `/dev/*` with a wrong `X-Service-Token`, `4.0.1`), `REQUEST_TIMEOUT` (408), `TOO_MANY_REQUESTS` (429, with
`Retry-After`), `INTERNAL_ERROR` (500). The Gateway answers `401` / `403` for a missing or wrong credential
before the service is called.

From `4.0.0`, `GET /logs` adds `SERVICE_TOKEN_REQUIRED` (403, no `X-Service-Token`),
`INVALID_SERVICE_TOKEN` (401, a wrong one), `VALIDATION_ERROR` (400, a bad window) and
`LOGS_UNAVAILABLE` (503, no log file). A request from the broker that cannot be dispatched locally is
answered by the instance itself in the same envelope: `400 VALIDATION_ERROR` for a method or path it
cannot serve, `408 REQUEST_TIMEOUT` when the local call outlives its timeout, `500 INTERNAL_ERROR`
when it fails.

### 5.4 Operational endpoints (outside `/api/v1`)

| Method | Path | Gateway | Notes |
| --- | --- | --- | --- |
| `GET` | `/health` | public | Liveness |
| `GET` | `/health/ready` | service | Readiness: `503` until the migrations and the seed are done |
| `GET` | `/status` | called directly | Service Discovery polls it on the instance - see [Lab 3](#lab-3-status-logs-discovery-several-instances) |
| `GET` | `/logs` | not routed | `4.0.0`. This instance's log lines, `X-Service-Token` checked by the service - see [§11](#11-message-broker-logs-and-metrics-lab-4) |
| `GET` | `/metrics` | not routed | `4.0.0`. Prometheus scrapes it directly, no credential - see [§11](#11-message-broker-logs-and-metrics-lab-4) |

None counts against the concurrent task limit or the task timeout.

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

## Lab 3: status, logs, discovery, several instances

- **`GET /status`** answers without a credential and outside the concurrent task limit (like `/health`): `{ service, instance_id, version, status, in_flight, max_concurrent_tasks }`, `service` is `server-rules`. `status` is `up`, or `degraded` with `503` when the database does not answer. `/health` and `/health/ready` are unchanged.
- **Logs** are JSON lines with `time`, `level`, `service`, `instance_id`, `version`, `event`, `msg` and the fields of the event (`http.request` carries `request_id`, `method`, `path`, `status`, `duration_ms`). An error is logged once, with its stack for an unexpected one. `startup` / `shutdown` carry the version, instance id, address and settings (a token only as `service_token_set`).
- **Service Discovery**: with `SERVICE_DISCOVERY_URL` set the instance registers as `server-rules` (`PUT /api/v1/instances/<instance_id>` with its port, `host` only when `INSTANCE_HOST` is set; from `4.0.0` also `"topics": {"publishes": [], "subscribes": []}`, #111: it publishes and consumes no event), repeats it every 5 s as the heartbeat, and removes itself with `DELETE` on a clean stop; calls time out after 2 s and a failure is logged and retried at the next beat, it never stops the service.
- **Database**: the Npgsql pool is capped at 20 connections per instance unless the connection string sets `Maximum Pool Size`. Migrations and seeding run under a Postgres advisory lock, so instances starting together on an empty database run them once.
- **Several instances**: the rules of a ruleset never change, so each instance caches a resolved version for good. `is_active` and `notes` can change on another instance, so the admin endpoints (and the guards before a change) read the database, never the cache. A public read of a version can show an `is_active` or `notes` another instance has just changed until that instance restarts. This service makes no outbound calls, so it has no circuit breaker.

## 8. Edge cases

- **`GET /rulesets/current` must never fail to answer** for a valid difficulty 1-5. The
  seeder asserts this at startup and the service refuses to start otherwise.
- **Rulesets are immutable.** `GET /rulesets/{version}` for a soft-deleted or deactivated
  version still returns it - `is_active`/`deleted_at` only affect whether it can be `current`.
- **Wiping the Postgres volume resets the version counter** to 1, silently invalidating any
  snapshot a peer holds of an older `ruleset_version`. Do not drop the volume between demos.

---

## 9. Gateway requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md)) must do for this service, prefix `server-rules`:

- Lab 2-3: `GET /rulesets/current` and `POST /rulesets/{v}/evaluations`: service token only (Session and
  Moderation call them). `GET /rulesets/{version}`: player JWT.
- Lab 2-3: `/admin/*` and `/dev/*`: service token only, never on a player JWT alone. The service refuses a
  request that carries `X-Player-Id`, as a second line.
- This service checks no credential on its contract endpoints: the Gateway checks a player's JWT and, from
  Lab 4, the broker checks the service token of a service call (README "Authentication").
- From `4.0.1` (#150) the service checks `X-Service-Token` itself on `/admin/*` and `/dev/*`, as on
  `GET /logs` (README "Authentication" > "Through the Message Broker", rule 4): they are called directly
  inside `student-id-net`, never through the Gateway or the broker.
- **Lab 4 (#110):** the Gateway keeps only `GET /rulesets/{version}` (player JWT) and `/health` of this
  service, and hands the player route to the broker's `requests.server-rules`; Session and Moderation
  reach this service through the broker, not the Gateway. `GET /logs` and `GET /metrics` are not
  Gateway routes. #110 (IacovlevMaxim/gateway-service#15) shipped in the Gateway's `4.0.0`, which the
  compose runs since #113, so the service-token routes above answer `404` at the Gateway; Session `4.0.0` calls `GET /rulesets/current`
  through the broker.
- No CORS headers, no rate limiting, no `Idempotency-Key` support. `POST /evaluations` and
  `POST /admin/rulesets` are not idempotent - two identical requests create two things (a log
  line; a new ruleset version, respectively). Safe to retry: every `GET`, `PATCH`, `DELETE`.

---

## 10. Recipes for testing against it

The recipes call the service's own port `8083`, which the team compose does not publish: run the image alone
with `-p 8083:8080`. None of these routes is a Lab 4 Gateway route (§9), so they go to the instance
itself, as service calls: no `X-Player-Id`; `X-Service-Token` on `/admin/*` and `/dev/*` (from `4.0.1`) and
on `/logs`, the contract routes check no token. Through the
Gateway only `GET /health` and `GET rulesets/{version}` (player JWT) remain, at
`http://localhost:8080/api/v1/server-rules/`.

```bash
BASE=http://localhost:8083
TOKEN=<SERVICE_TOKEN of the instance>

# The contract's own worked example
curl -s "$BASE/api/v1/rulesets/current?difficulty=3" | jq
curl -s -X POST "$BASE/api/v1/rulesets/3/evaluations" -H 'Content-Type: application/json' -d '{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "facts": { "university_status": "faf_student", "major": "FAF", "year": 1,
             "years_enrolled": 1, "currently_enrolled": true, "previously_banned": false }
}' | jq
# => { "ruleset_version": 3, "admitted": true, "violated_rules": [], "allowed_channels": ["general"] }

# The limits: with HTTP_REQUEST_TIMEOUT=2, this sleeps past it and is answered 408 REQUEST_TIMEOUT
curl -s "$BASE/api/v1/dev/slow?ms=4000" -H "X-Service-Token: $TOKEN" | jq
# Without the header: 403 SERVICE_TOKEN_REQUIRED; with a wrong one: 401 INVALID_SERVICE_TOKEN (4.0.1)
```

The full Postman collection (`postman/server-rules-service.postman_collection.json` in the
CPR) covers every endpoint including the admin surface and every error branch. Only the Lab 4 Gateway's
routes of this service go through it (`base_url`): `GET /health` and `GET rulesets/{version}` with a
player JWT. Every other request (`/health/ready`, `/status`, `rulesets/current`, the evaluations,
`/admin/*`, `/logs`, `/metrics`) goes to one instance directly through `server_rules_direct_url`, by its
own path (`/api/v1/...` without the `server-rules` prefix), since the Lab 4 Gateway answers `404` to it
(§9). A direct request is a service call: no `X-Player-Id`, and `X-Service-Token: {{service_token}}` on
`/admin/*`, `/dev/*` and `/logs`, the routes the instance checks it on (`/admin/*` and `/dev/*` from
`4.0.1`); the admin folder also sends no token and a wrong one to an admin route (`403`, `401`).
Postman cannot send the broker's gRPC calls.

---

## 11. Message Broker, logs and metrics (Lab 4)

From `4.0.0`, as CPR README "Message Broker", "Authentication" ("Through the Message Broker"), "Logs
download" and "Monitoring" describe it (#105). `Protos/broker.proto` is a byte-identical
copy of the CPR's [`shared/broker.proto`](../shared/broker.proto). `4.0.1` (#150) adds the
`X-Service-Token` check of `/admin/*` and `/dev/*` (§5.2), so those routes are reached only directly.

### The subscription

- One gRPC `Subscribe` stream per instance to `MESSAGE_BROKER_URL`: `service: "server-rules"`,
  `instance_id: INSTANCE_ID`, `topics: []`, `max_concurrent_tasks: MAX_CONCURRENT_TASKS`. The broker
  delivers the requests of the queue `requests.server-rules` on it, to the least loaded instance. Every
  call carries the metadata `x-service-token: SERVICE_TOKEN`.
- The stream opens once the HTTP listener is up. When it cannot be opened or ends, `broker.subscribe_failed`
  is logged and it is opened again after 1 s, 2 s, 4 s ... up to 30 s; meanwhile the instance serves
  `/health`, `/status`, `/logs` and `/metrics`. gRPC keepalive (2 s) notices a dead broker within seconds.
- `/health/ready` and `/status` do not report the broker.
- An event delivered anyway (the service subscribes to none) is acked `PERMANENT` with the reason
  `server-rules consumes no event`, so the broker dead-letters it instead of sending it again.
- Graceful stop: the stream is closed first, so the broker stops routing here, and the requests already
  received are still answered, for up to 5 s.
- No circuit breaker: the service calls nothing through the broker, or otherwise.

### Requests from `requests.server-rules`

Each delivered request (`method`, `path` with its query, `headers`, `body`) is sent to the instance's
own HTTP pipeline on `http://127.0.0.1:<port>` (the port of `ASPNETCORE_URLS`, `8080`), so the routes,
`X-Request-ID`, the task timeout, the concurrent task limit (and so `in_flight`, which the broker routes
by) and the access log work exactly as for a direct call. Requests run concurrently. The answer goes
back with `Reply`: the same status, headers and body, the request's `correlation_id` and this
instance's id - a `4xx` or `5xx` too, unchanged.

- **Headers pass verbatim**, `X-Player-Id` included, so a request the Gateway made for a player stays a
  player's request and a service call (no `X-Player-Id`) stays one. `X-Service-Token`, `Authorization`,
  hop-by-hop headers, `Host` and `Content-Length` are dropped (#124); no token is ever added, so from
  `4.0.1` `/admin/*` and `/dev/*` refuse every request that comes this way (`403 SERVICE_TOKEN_REQUIRED`). A header value that is not one line
  of printable ASCII is dropped.
- **Request id:** the `X-Request-ID` header, else the request's or the delivery's `request_id`, only
  when it is 1 to 200 visible ASCII characters; otherwise the pipeline generates one. The same rule
  applies to `X-Request-ID` on a direct call.
- **Local limits:** the local call may take the caller's `timeout_ms`, 10 s without one, at most 60 s.
  A method or path that cannot be served is `400 VALIDATION_ERROR`, a local call that outlives its
  timeout `408 REQUEST_TIMEOUT`, one that fails `500 INTERNAL_ERROR`. The URI always stays on loopback.

### `GET /logs?since=&until=&level=`

As CPR README "Logs download" defines it: the instance's own lines from `LOG_FILE` and its rotated
files, oldest first, unchanged, `since <= time < until` (RFC 3339 with a zone, both optional), `level`
and above. Reachable only directly: no request through the broker or the Gateway carries the token.

| Answer | When |
| --- | --- |
| `200 application/x-ndjson`, `Content-Disposition: attachment; filename="<instance_id>-<since as 20261105T112700Z, or start>.jsonl"` | the lines, possibly none; headers sent before the files are read |
| `403 SERVICE_TOKEN_REQUIRED` / `401 INVALID_SERVICE_TOKEN` | no `X-Service-Token` / a wrong one (compared in constant time) |
| `400 VALIDATION_ERROR`, `details.errors: [{field, message}]` | a time that is not RFC 3339 or has no zone, `until <= since` (field `until`), an unknown `level` |
| `503 LOGS_UNAVAILABLE` | `LOG_FILE` empty or not writable at startup |

Every file is opened and measured before any is read, so a line written meanwhile is never half
included; a line that is not one whole JSON object is left out. Outside the concurrent task limit and
the task timeout; its access line is at `debug`. The file lives in the container: it survives a
restart, not a recreation.

```bash
curl -s "http://<instance>:8080/logs?since=2026-11-07T17:00:00Z&level=warn" -H "X-Service-Token: $SERVICE_TOKEN"
```

### `GET /metrics`

Prometheus text format, no credential, outside the limit, access line at `debug`.

| Series | Labels |
| --- | --- |
| `http_requests_total` | `method`, `route` (the route template, `unmatched` for none), `status` |
| `http_request_duration_seconds` (histogram) | `method`, `route` |
| `tasks_in_flight` | - (requests holding a concurrent-limit slot) |

A method outside the standard ones is `OTHER`, so no caller can grow the number of series. No
`breaker_state`, `outbox_pending` or `outbox_parked`: the service has neither a breaker nor an outbox.

### New log events

| `event` | Level | Extra fields |
| --- | --- | --- |
| `request.received` / `request.replied` | `info` | `correlation_id`, `message_id`, `method`, `path` (no query), `caller`; `attempt` when received; `status`, `duration_ms` when replied |
| `request.reply_failed` | `warn` | `correlation_id`, `message_id`, `error` |
| `broker.subscribed` | `info` | `target`, `max_concurrent_tasks`, `topics` |
| `broker.subscribe_failed` | `warn` | `target`, `error`, `attempt`, `retry_in_ms` |
| `broker.disabled` | `warn` | once at startup, `MESSAGE_BROKER_URL` empty |
| `broker.acked` / `broker.ack_failed` | `warn` | an event rejected `PERMANENT`: `message_id`, `queue`, `event_id`, `event_type`, `outcome`, `reason` / `message_id`, `error` |
| `logs.file_unavailable` | `warn` | `path`, `error`, once at startup |

`startup` also carries `message_broker_url`, `log_file`, `log_file_max_mb` and `log_file_keep`. A
request from the broker is dispatched over loopback, so its `http.request` line has `client_ip`
`127.0.0.1`; its `request_id` is the caller's `X-Request-ID`. Headers and bodies are never logged.

---

*Server Rules Service is owned by Titerez Vladislav. See the service's own repository README
for build/test instructions and the full seeded-ruleset content.*
