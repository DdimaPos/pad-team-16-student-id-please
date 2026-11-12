# Credential Service — Integration Reference

Everything another service, a gateway or a teammate needs in order to work with this service,
without reading its source.

Team 16 · *Student ID, please* · FAF.PAD21.1 · version `4.0.0`

For "how do I start it", see [README.md](../credential-service/README.md). This document is the contract.

Everything here describes the published image `4.0.0`. Where it differs from the CPR contract,
[§11](#11-divergences-from-the-cpr-contract) says so.

**Lab 4** moved every request and every event of this service onto the Message Broker:
requests arrive on the queue `requests.credential`, events are published to and received from
`events.applicant.initialized`, all over gRPC ([§5.5b](#55b-requests-and-events-through-the-message-broker),
[§8](#8-events)). The REST port stays for the probes, `/logs`, `/metrics` and direct calls
inside the network.

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
13. [Gateway and broker requirements](#13-gateway-and-broker-requirements)
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
| **Calls** | nobody synchronously. It publishes its own `applicant.initialized` to the Message Broker once ([§8.1](#81-transport)), with one circuit breaker on the broker; receives its requests and events from the broker; and registers each instance with Service Discovery directly ([§14](#14-running-several-instances)). No request this service answers waits on another service |
| **Is called by** | the game client (`/documents`, through the Gateway and the broker) and Moderation Service (`/documents/validation`, through the broker) |
| **Listens to** | `applicant.initialized`, from Applicant Service or University Record Service |
| **Publishes** | `applicant.initialized`, only when it was the first service to meet the applicant |

---

## 2. Integration card

| | |
| --- | --- |
| Base path | `/api/v1` |
| How requests arrive | from the Message Broker on `requests.credential`, over the instance's gRPC stream, dispatched in-process to the router of the REST port ([§5.5b](#55b-requests-and-events-through-the-message-broker)). The Gateway forwards one player route to the broker: `GET {gateway}/api/v1/credential/applicants/{id}/documents` |
| Port | `8082` (REST) |
| Short name | `credential` - the Gateway prefix, the `service` of every log line and of `GET /status`, the `service_name` it registers under and the broker queue `requests.credential`. Each copy is `credential-<hostname>` (`instance_id`) |
| Health | `GET /health`, `GET /health/ready` |
| Status (Service Discovery) | `GET /status` - load and health of this copy ([§5.6](#56-health)) |
| Logs and metrics | `GET /logs` (service token) and `GET /metrics` (Prometheus), on the REST port ([§15](#15-observability)) |
| Instances | 2-3 copies share the one database; each subscribes to the broker, which hands every request to the least loaded copy ([§14](#14-running-several-instances)) |
| Database | MongoDB, `credential_db` |
| Events | through the Message Broker over gRPC (CPR README "Event delivery"): published once from a transactional outbox to `events.applicant.initialized`, received on the instance's subscription to that topic and acked |
| Produces | `applicant.initialized`; the broker hands a copy to Applicant and University Record Service |
| Consumes | `applicant.initialized` from Applicant and University Record Service (its own copy is ignored) |
| Auth | none in the service: the broker checks the service token on every gRPC call, and the Gateway checks a player's JWT before it hands a request to the broker, which passes on only `X-Player-Id`. `GET /logs` is the exception: it checks `X-Service-Token` itself - see [§13](#13-gateway-and-broker-requirements) |
| Outbound calls | gRPC to the broker at `MESSAGE_BROKER_URL` (`Subscribe`, `Publish`, `Ack`, `Reply`) with `x-service-token` metadata; its registration with Service Discovery, directly |
| Producer name | `credential-service` |
| Image | `stewdh/credential-service:4.0.0`, also `:latest` (linux/amd64, linux/arm64), published by CI on every merge to `main` |
| Error envelope | `{"error":{"code","message","details"}}` |
| Timestamps | ISO 8601, UTC, whole seconds |
| Identifiers | UUID v4 strings |

**Hard dependency:** MongoDB only. The broker and Service Discovery are soft: without the broker
no request reaches the instance and its events wait in the outbox, and it subscribes again with
backoff ([§12.2](#122-the-broker-is-away)); the registration is retried every 5 s.

---

## 3. Ports and networking

| Port | What |
| --- | --- |
| `8082` | the REST port. The shipped compose file publishes the host range `APP_HOST_PORT`-`APP_HOST_PORT_LAST` (`8082`-`8084`), one port per copy, so `--scale credential-service=3` works; the team compose publishes none. Inside the network it serves `/health`, `/status`, `/logs` and `/metrics` to Service Discovery and Prometheus, and the whole `/api/v1` router to direct calls |
| `27018` → `27017` | MongoDB, host → container |

`8081` and `5433` belong to Applicant Service; `8082` and `27018` were chosen so both stacks
run on one laptop.

The compose network is named **`student-id-net`**. Inside it the service reaches the Message
Broker at `MESSAGE_BROKER_URL` (`message-broker-service:8071`, gRPC) and opens the one stream on
which it receives everything; the broker never dials an instance. The other address it uses is
Service Discovery's, called directly at `SERVICE_DISCOVERY_URL`
(`http://service-discovery-service:8090` in the team compose): Service Discovery records the
address the registration came from, the container's IP on the network, and polls `/status`
there. No other service's address is configured anywhere.

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
| `SERVICE_TOKEN` | *(empty)* | the stack's one service token: `x-service-token` metadata on every call to the broker, `X-Service-Token` on every call to Service Discovery, and the one credential `GET /logs` accepts. Required when `MESSAGE_BROKER_URL` or `SERVICE_DISCOVERY_URL` is set |
| `MESSAGE_BROKER_URL` | *(empty)* | the Message Broker's gRPC target, `host:port` with no scheme: `message-broker-service:8071` in the compose files. A scheme or a missing port fails startup. **Empty: no subscription and no relay** - the instance serves its REST port only, events wait in the outbox, and `/health/ready` says `degraded` |
| `EVENT_PUBLISH_TIMEOUT` | `5s` | one `Publish` to the broker. No answer within it counts as a failure for the circuit breaker on the broker |
| `OUTBOX_POLL_INTERVAL` | `500ms` | how often the relay looks for deliveries that are due |
| `OUTBOX_BATCH_SIZE` | `50` | deliveries taken per claim |
| `OUTBOX_LEASE` | `5m` | how long a claimed batch stays reserved for the copy that claimed it. **Must be at least `OUTBOX_BATCH_SIZE` × `EVENT_PUBLISH_TIMEOUT`** (250 s with the defaults), or startup fails: a shorter lease could run out while the batch is still being published. Deliveries a relay does not get to are handed back at once ([§8.6](#86-several-instances-and-the-circuit-breaker)) |
| `EVENT_RETRY_MAX_BACKOFF` | `30s` | cap on the wait between two attempts at one delivery (1 s, 2 s, 4 s, ... up to this) |
| `APP_PORT` | `8082` | |
| `APP_ENV` | `local` | `local` / `docker` / `production`; selects the Gin mode. Logs are JSON either way ([§15](#15-observability)) |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SERVICE_VERSION` | `dev` | reported by `/health`, `/status`, every log line and the registration |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` | `10s` | |
| `HTTP_REQUEST_TIMEOUT` | `5s` | task timeout: a request running longer is stopped and answered `408 REQUEST_TIMEOUT` (see below). `0` disables it. It also bounds applying one event from the broker, and times 3.5 it is the window and cooldown of the circuit breaker on the broker (17.5 s) |
| `MAX_CONCURRENT_TASKS` | `64` | concurrent task limit for `/api/v1`: a request above it is refused with `429 TOO_MANY_REQUESTS`. Must be ≥ 1. `GET /status` reports it as `max_concurrent_tasks` |
| `DEV_ENDPOINTS` | `false` | mounts `GET /api/v1/dev/slow?ms=` (see below). Keep `false` in shared deployments |
| `SHUTDOWN_TIMEOUT` | `10s` | graceful drain |
| **`REFERENCE_YEAR`** | `2026` | the calendar year treated as "now". **Applicant, Credential, University Record and Moderation Service must all be given the same value**, or perfectly honest applicants read as liars |
| `GENERATOR_SEED` | `0` | `0` picks a fresh sequence per boot; a fixed number reproduces a run exactly, **for one instance only**: every copy given the same seed generates the same applicants in lockstep |
| `SERVICE_DISCOVERY_URL` | *(empty)* | Service Discovery's base URL, `http://service-discovery-service:8090` in the team compose. The instance registers there directly, with `SERVICE_TOKEN`, which is then required. **Empty: no registration**, one `sd.disabled` warning at startup (fine for a local run, but the broker does not choose an instance Service Discovery does not list as `up`) |
| `INSTANCE_ID` | `credential-<hostname>` | the id the instance registers under and logs with. In Docker the hostname is the container id, so every copy has its own. Set it only for an instance outside Docker; **never give scaled copies one value** |
| `INSTANCE_HOST` | *(empty)* | sent as `host` at registration, for an instance outside Docker that Service Discovery cannot reach at the address the registration came from. Empty: no `host` is sent |
| `LOG_FILE` | `/var/log/credential/credential.jsonl` | the rotating copy of the log that `GET /logs` serves. Its directory is created. **Set and empty: no file**, stdout only, and `GET /logs` answers `503 LOGS_UNAVAILABLE`; a path the process cannot write to does the same, with one `logs.file_unavailable` warning |
| `LOG_FILE_MAX_MB` | `50` | size at which the file is rotated. Must be ≥ 1 |
| `LOG_FILE_KEEP` | `5` | rotated files kept next to the current one. Must be ≥ 0 |

An empty string counts as unset for every variable but `LOG_FILE`, where set to empty switches
the file off (CPR README "Logs download").

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
The broker waits the caller's `timeout_ms` for the reply (`10 s` for the Gateway, `4 s` for
Moderation Service), and the instance stops a request at whichever of the two comes first.

**Concurrent task limit (`MAX_CONCURRENT_TASKS`).** At most that many requests under `/api/v1` are
in progress at once. One more is refused at once - not queued - with `429 TOO_MANY_REQUESTS` and
`Retry-After: 1`, before any work is done. Requests from the broker are counted like any other;
`/health`, `/health/ready`, `/status`, `/logs` and `/metrics` are not, and `GET /status` reports
how many slots are taken as `in_flight`.

**Dev endpoint (`DEV_ENDPOINTS=true`).** `GET /api/v1/dev/slow?ms=<0..60000>` does nothing for `ms`
milliseconds and answers `200 { "slept_ms": <ms> }`; it counts as a task. `?ms=6000` answers `408`
after the timeout, and with `MAX_CONCURRENT_TASKS` of them open one more request to `/api/v1`
answers `429` while `/health` still answers `200`. Without the flag the path is `404 NOT_FOUND`.
A bad `ms` (not an integer, or outside `0..60000`) answers `400 VALIDATION_ERROR`.

---

## 5. HTTP API

### 5.1 Endpoint summary

| Method | Path | Source | Consumed by | Reached through |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/applicants/next` | contract | no service yet | the broker (`requests.credential`) |
| `GET` | `/api/v1/applicants/{applicant_id}/documents` | contract | Client | the Gateway's player route, which hands it to the broker |
| `GET` | `/api/v1/applicants/{applicant_id}/documents/validation` | contract | Moderation Service | the broker; not a Gateway route since Lab 4 |
| `GET` | `/api/v1/applicants` | *extension* | — | REST port only |
| `POST` | `/api/v1/applicants` | *extension* | — | REST port only |
| `GET` | `/api/v1/applicants/{applicant_id}` | *extension* | — | REST port only |
| `PATCH` | `/api/v1/applicants/{applicant_id}` | *extension* | — | REST port only |
| `DELETE` | `/api/v1/applicants/{applicant_id}` | *extension* | — | REST port only |
| `GET` | `/api/v1/dev/slow?ms=` | dev (`DEV_ENDPOINTS`) | demo / tests | REST port only |
| `GET` | `/health`, `/health/ready` | infrastructure | orchestrator | REST port; `/health` also public at the Gateway |
| `GET` | `/status` | infrastructure | Service Discovery (directly, every 10 s) | REST port |
| `GET` | `/logs` | infrastructure (Lab 4) | developers, Service Discovery's aggregate download | REST port, service token |
| `GET` | `/metrics` | infrastructure (Lab 4) | Prometheus | REST port |

A request the broker delivers can name any path of the router, so the broker and the Gateway
together decide what is reachable; see [§13](#13-gateway-and-broker-requirements).
`POST /api/v1/events` is gone in Lab 4: events arrive on the subscription
([§5.5b](#55b-requests-and-events-through-the-message-broker)).

### 5.2 `POST /api/v1/applicants/next`

Creates a new applicant, starting from the documents they bring. Stores the bundle, queues
`applicant.initialized` for the broker, which hands it to Applicant and University Record,
returns the identifiers.

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

### 5.5b Requests and events through the Message Broker

Every instance opens **one gRPC stream** to the broker, `Subscribe(service="credential",
instance_id, topics=["events.applicant.initialized"], max_concurrent_tasks)`. The broker sends
on it the requests of the queue `requests.credential`, which the instances of the service share
(each request goes to one of them), and a copy of every event published to the topic. Each
delivery is served in a goroutine of its own.

**Requests.** A `Delivery.request` carries `correlation_id`, `method`, `path` (the service's own
path with its query, `/api/v1/applicants/{id}/documents/validation`), `headers`, `body`, `caller`
and `timeout_ms`. The instance builds an `http.Request` from it and serves it with **the same
router as the REST port**, in-process, so everything of [§4](#4-configuration) and
[§5](#5-http-api) applies unchanged: the task timeout, the concurrent task limit, the access log,
the error envelope. The answer goes back as `Reply(correlation_id, status, headers, body,
instance_id)`, which settles the request at the broker.

- `X-Request-ID` and `X-Player-Id` are taken from `headers`; a missing `X-Request-ID` is taken
  from `request_id`, or generated. `X-Service-Token` and `Authorization` are dropped even if a
  caller sent them: the broker's token check is the boundary, and no credential reaches a
  handler.
- The request is bounded by `timeout_ms` as well as by the task timeout, whichever ends first.
- Every log line of the request carries `correlation_id` next to `request_id`, and
  `request.received` / `request.replied` frame it ([§15](#15-observability)).
- `client_ip` in its access log is the broker's address.
- A `Reply` that does not reach the broker is logged at `warn`; the broker then answers its
  caller `408` when `timeout_ms` passes.

**Events.** A `Delivery.event` carries the producer's envelope byte for byte. The instance
applies it with the same handler `POST /api/v1/events` used in Lab 3, and acks it:

| Outcome | Ack | When | The broker then |
| --- | --- | --- | --- |
| Applied | `OK` | The bundle was built from `claimed`, judged against `actual`, and stored | Drops it from the queue |
| A repeat | `OK`, reason `duplicate` | An applicant with that `applicant_id` is already stored. Nothing changed | Drops it |
| Our own | `OK` | `initialized_by` is `credential-service`: the producer receives its own event on the topic too. Ignored, nothing stored | Drops it |
| Can never be applied | `PERMANENT`, with the reason | The envelope cannot be parsed, has no `event_id`, `event_type`, `producer` or `payload`, names an `event_type` other than `applicant.initialized` or a `version` other than `1`, or its payload fails validation (no `applicant_id`, no `initialized_by`, no claimed `name`) - the old `422 INVALID_EVENT` | Dead-letters it at once |
| Not this time | `RETRY`, with the reason | MongoDB did not answer, or the task timeout (`HTTP_REQUEST_TIMEOUT`) ran out; the write was never started | Delivers it again, to another instance if it can, until its attempts run out |

An `Ack` that does not reach the broker is logged at `warn`: the broker delivers the event
again after its ack timeout, and the dedup makes that a no-op.

Dedup is keyed on `applicant_id`, the document's primary key, rather than on `event_id`: the
insert either creates the bundle or finds it there, with no read-then-write race to lose. A
redelivery that reaches two instances at once therefore creates the bundle, and records its
email reservations, once. It follows that a second producer announcing the same applicant is
also acked as a `duplicate`.

**Shutdown.** When the instance is told to stop it takes no more deliveries, lets every one in
progress reach its `Reply` or `Ack` on the open stream, and only then closes the stream. A
request that arrives meanwhile is answered `503 SERVICE_UNAVAILABLE` (`details.service`) at once,
since it never ran; an event goes back as `RETRY`.

**Reconnect.** A stream that fails is opened again after 1 s, 2 s, 4 s ... up to 30 s, each
attempt logged `broker.subscribe_failed` at `warn`; the wait starts again from 1 s once a stream
has delivered something or stayed open for 30 s. gRPC keepalive pings the broker every 10 s and
gives up on a connection after 2 s more without an answer, so a dead broker is noticed within
about 12 s (10 s is the least grpc-go allows a client: it raises a shorter interval and warns on
every dial). The broker pings each instance every 2 s itself, so it notices a dead instance
within about 4 s.

### 5.6 Health

`GET /health` → `200` whenever the process is serving. It checks no dependency on purpose:
restarting a healthy container because somebody else's database was slow would be wrong.

`GET /health/ready`:

```json
{ "status": "ok", "service": "credential-service", "version": "4.0.0",
  "components": { "mongodb": {"status": "up"}, "message_broker": {"status": "up"},
                  "event_relay": {"status": "up"} },
  "pending_events": 0, "parked_events": 0 }
```

| Situation | `status` | HTTP | Where it shows |
| --- | --- | --- | --- |
| everything configured and subscribed | `ok` | `200` | |
| `MESSAGE_BROKER_URL` unset | `degraded` | `200` | `components.message_broker` and `components.event_relay` `disabled` |
| the broker not answering | `degraded` | `200` | `components.message_broker.status: "down"`; `pending_events` climbs when applicants are created on the REST port |
| Mongo unreachable | `unavailable` | `503` | `components.mongodb` |

`pending_events` is the outbox backlog: events not yet published, due or waiting out a retry
backoff. `parked_events` counts events set aside because they can never be published (the
broker refused them as malformed, or the stored envelope cannot be read); somebody has to look at
them (`last_error` on the delivery says why). **Both are omitted when the count cannot be
taken**, which is precisely when MongoDB is down.

A broker that is away is **not** a readiness failure: the instance's database is fine, it
subscribes again on its own, and its events wait in the outbox until then.

`GET /status` — this copy's health and load, in the shape every component shares. Service
Discovery polls it directly every 10 s with a 2 s timeout, and the broker reads the load it
reports from Service Discovery. No credential; like the health checks it sits outside
`/api/v1`, so it is **not counted by the concurrent task limit and never answers `429`**: a copy
at full load reports itself busy instead of looking broken.

```json
{ "service": "credential", "instance_id": "credential-3f4e2a9b1c7d", "version": "4.0.0",
  "status": "up", "in_flight": 3, "max_concurrent_tasks": 64 }
```

| Situation | HTTP | `status` |
| --- | --- | --- |
| MongoDB answers a ping within 1 s | `200` | `up` |
| it does not | `503` | `degraded`, same body |

`in_flight` is the number of requests under `/api/v1` holding a slot of the concurrent task
limit right now, the broker's requests included; Service Discovery divides it by
`max_concurrent_tasks` and alerts at 80 %. The broker plays no part here. Its access-log line is
at `debug`, like the health checks'.

`GET /logs` and `GET /metrics` are in [§15](#15-observability).

### 5.7 Error codes

| Code | HTTP | When |
| --- | --- | --- |
| `VALIDATION_ERROR` | `400` | malformed request; `details` names the offending field by its **wire** name |
| `VALIDATION_ERROR` | `422` | a well-formed request describing an impossible person; `details` carries `invariant`, `side`, `reason`. The contract keeps `VALIDATION_ERROR` for `400` — see [§11](#11-divergences-from-the-cpr-contract) |
| `REQUEST_TIMEOUT` | `408` | the request ran longer than `HTTP_REQUEST_TIMEOUT`, or than the `timeout_ms` of the broker's request, and was stopped; **nothing was changed** |
| `INVALID_SERVICE_TOKEN` | `401` | `GET /logs` only: `X-Service-Token` is not the stack's token |
| `SERVICE_TOKEN_REQUIRED` | `403` | `GET /logs` only: no `X-Service-Token` |
| `VALIDATION_ERROR` | `400` | `GET /logs`: a bad parameter, with `details.errors: [{field, message}]` (CPR README "Logs download") |
| `LOGS_UNAVAILABLE` | `503` | `GET /logs` only: the instance writes no log file (`LOG_FILE` empty, or it could not be opened) |
| `SERVICE_UNAVAILABLE` | `503` | only as a reply through the broker, to a request that arrived while the instance was shutting down; `details.service`; **nothing was changed** |
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

Through the Message Broker over gRPC, as the CPR README "Event delivery" defines it for Lab 4.

- **Producer side.** `POST /applicants/next` writes the applicant and the envelope of its
  `applicant.initialized` into the same document, with one pending delivery, to the consumer
  `message-broker`. A background relay then publishes the stored bytes, unchanged, with
  `Publish(topic="events.applicant.initialized", event_id, event_type, producer, version,
  envelope_json, request_id)`, and records the outcome:

  | Outcome | The relay |
  | --- | --- |
  | `Publish` returned | Marks the delivery done (`published_at` set): the broker has it |
  | `INVALID_ARGUMENT`, or a stored envelope that cannot be read | Parks the delivery, with the reason, and never publishes it again |
  | Anything else: `UNAVAILABLE`, `DEADLINE_EXCEEDED` after `EVENT_PUBLISH_TIMEOUT`, a broker-side error, a refused token, `RESOURCE_EXHAUSTED` | Retries after a backoff that doubles from 1 s and is capped at `EVENT_RETRY_MAX_BACKOFF` (30 s) |

  The broker fans the event out to every service subscribed to the topic: Applicant, University
  Record, and this service itself, which ignores its own. A consumer being down costs the relay
  nothing; its copy waits in the broker. Each publish carries the `X-Request-ID` of the request
  that created the applicant, stored with the event, as `request_id`, so that request can be
  followed through the broker into the consumers' logs; an event stored without one gets a
  fresh id.
- **Consumer side.** The instance's subscription to `events.applicant.initialized`, acked per
  event ([§5.5b](#55b-requests-and-events-through-the-message-broker)).
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

From Applicant Service or University Record Service, on the subscription to
`events.applicant.initialized`. The bundle is built from `claimed`, and judged against `actual`.

- Events whose `initialized_by` is `credential-service` are **ignored** and acked `OK` — our
  own, which the topic delivers back to its producer.
- `actual` is read **leniently**: a peer that omits it is not refused. Nothing can be forged
  without it, but the applicant is still visible.
- An envelope that cannot be parsed, of another `event_type` or `version`, or a payload
  missing `applicant_id`, `initialized_by` or a claimed name, is acked `PERMANENT` — it will not
  read any better on a retry, so the broker dead-letters it.
- MongoDB not answering, or the task timeout, is acked `RETRY`, and the broker delivers the
  event again. The same event may therefore arrive again, which is why ingest is an insert
  keyed on `applicant_id`: the repeat is acked `OK` with reason `duplicate` and changes nothing.

### 8.5 Delivery guarantees

Publishing goes through an outbox embedded in the applicant's own document
([§9](#9-what-and-how-it-stores)), with one delivery to the broker per event, so:

- an applicant is never created without their announcement being queued, and never announced
  without being created;
- one consumer being down never holds back the other: the relay publishes once, and the broker
  keeps one queue per subscribed service;
- the stamp marking a delivery done is written *after* `Publish` returned, so a crash in between
  publishes again rather than loses. A claim leases the delivery for a while, so a relay that
  dies mid-publish hands it back on its own, and two copies never publish the same delivery at
  once while the lease holds ([§8.6](#86-several-instances-and-the-circuit-breaker)). Every
  consumer in this system deduplicates, so a duplicate costs nothing while a lost event costs an
  applicant;
- an event the broker refuses as malformed is parked for good; it is counted in
  `/health/ready` and never published again;
- **delivery is at-least-once.** Consumers must be idempotent. This one is.

Two kinds of events left by earlier images get their delivery to the broker at startup, each
with one atomic `UpdateMany` matching only what is left to do, so copies starting together
cannot open a delivery twice: entries image `2.0.0` wrote without any delivery, and entries a
Lab 3 image left waiting for Applicant or University Record, whose pending per-consumer
deliveries are replaced by the one to the broker (delivered and parked ones stay as history).

### 8.6 Several instances and the circuit breaker

Every copy runs a relay over the same documents. What keeps them apart:

- **The claim.** A relay finds due deliveries and takes each with its own conditional
  `UpdateOne`: the filter requires the delivery to be still due, the update moves its
  `next_attempt_at` out by `OUTBOX_LEASE` and stamps it with a claim token of its own, and only
  the relay whose update modified the document owns it. A copy that dies mid-batch hands its
  deliveries back when the lease runs out.
- **The lease covers the batch.** Publishes of one batch go one after another, so the lease must
  outlast `OUTBOX_BATCH_SIZE` × `EVENT_PUBLISH_TIMEOUT` (50 × 5 s = 250 s); the default is 5 min
  and startup refuses less.
- **Only the current claim records a failure.** `attempts`, `next_attempt_at` and parking are
  updated only where the delivery's `claim_token` still matches, so a copy whose lease ran out
  cannot overwrite what the copy that took the delivery over has recorded. A publish is recorded
  whoever saw it: a delivery is a fact.
- **A relay stops at the first failure.** The rest of the batch is not published; its deliveries
  are handed back at once, due with the failed one's retry, without counting an attempt - not
  held until the lease runs out.

The Lab 3 MongoDB claims are unchanged by Lab 4: only the consumer they claim for is now
`message-broker`.

**Circuit breaker, one, on the broker** (CPR README "Circuit breaker"; target `message-broker`).
A failure is no answer within `EVENT_PUBLISH_TIMEOUT`, a cut connection, or a broker-side error
(`UNAVAILABLE`, `DEADLINE_EXCEEDED`, `INTERNAL`, `UNKNOWN`, `UNIMPLEMENTED`, `DATA_LOSS`). A
refusal is an answer and does not count - `INVALID_ARGUMENT`, `PERMISSION_DENIED`,
`UNAUTHENTICATED`, `RESOURCE_EXHAUSTED` included - even though the delivery itself is retried.

| State | The relay |
| --- | --- |
| Closed | Claims and publishes as above. **3 failures within 17.5 s** (`HTTP_REQUEST_TIMEOUT` × 3.5) open it: `breaker.opened` at `warn` |
| Open | **Claims nothing**: the deliveries stay pending and untouched, for this copy after the cooldown or for another copy whose breaker is closed. `breaker.rejected` at `debug` on every pass |
| Half-open, 17.5 s after opening | `breaker.half_open`, then **one trial publish**: a claim of one delivery. Success closes it, `breaker.closed`, and the backlog drains; failure opens it again for another 17.5 s |

The breaker only logs and stops calling; `breaker_state{target="message-broker"}` on `/metrics`
shows it. The per-instance breakers that mark an instance down in Service Discovery live in the
broker. The subscription has no breaker: it is the reconnect loop of
[§5.5b](#55b-requests-and-events-through-the-message-broker). The service has no synchronous
outbound call, so the contract's `500 DEPENDENCY_UNAVAILABLE` for an open breaker never arises
here: the relay simply leaves the deliveries pending.

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
                   "deliveries": [ { "consumer": "message-broker", "attempts": 2,
                                     "next_attempt_at": "…", "delivered_at": null, "parked_at": null,
                                     "last_status": 0, "last_error": "publish to message-broker: … Unavailable …" } ] } ],
  "is_honest": false, "lie_archetype": "outsider_impersonates_student",
  "created_at": "…", "updated_at": "…" }
```

**Why the event lives inside the applicant.** MongoDB gives no multi-document transaction
without a replica set, but a write to *one* document is always atomic. Embedding the outbox
entry buys the transactional-outbox guarantee — applicant and announcement durable at the same
instant — without asking every teammate to run a replica set to demo the system. Each entry
carries one `deliveries` element per consumer, which is the relay's unit of work; since Lab 4
that is one, `message-broker` (`last_status` stays `0`: a publish has no HTTP status).
`published_at` is set once every delivery of the entry is done. `routing_key` predates HTTP
delivery and simply repeats the event type. Since `3.0.0` an entry also keeps `request_id`, the
`X-Request-ID` of the request that created it, sent with its publish, and a delivery being
published carries `claim_token`, the claim that holds it ([§8.6](#86-several-instances-and-the-circuit-breaker)).
Documents written by earlier images simply lack both fields; entries left waiting for Lab 3
consumers are moved to the broker at startup ([§8.5](#85-delivery-guarantees)).

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

Since Lab 4 every call between services below is a request through the Message Broker, and
every event a publish to its topic; the game client's calls enter at the Gateway as
`{gateway}/api/v1/<prefix>/...`, which hands them to the broker. The paths shown are the
service's own (see the CPR README "Gateway").

### 10.1 Session Service asks Applicant Service for the next applicant

```
Session → Applicant:   POST /api/v1/applicants/next
Applicant → broker:    Publish applicant.initialized to events.applicant.initialized
broker → Credential:   the event on its subscription, acked once applied
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

All five calls are requests through the broker, with no `X-Player-Id`, never with the
Moderator's token.

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
`applicant.initialized` with `"initialized_by": "credential-service"` to
`events.applicant.initialized`. Applicant Service and University Record Service build their own
records from it. The relay is covered by unit tests against a fake broker client and the
subscription by tests against an in-memory gRPC broker; the round trip with a running Applicant
Service through a stand-in broker is verified by hand.

---

## 11. Divergences from the CPR contract

Raise these in the CPR before integration.

| # | Divergence | Who is affected |
| --- | --- | --- |
| 2 | **`GET .../documents/validation` is protected only by the broker's token check** (and, since Lab 4, by not being a Gateway route) and by this port being unpublished. Reading no credential in the service is correct under the contract | the broker, the Gateway |
| 3 | **`422 VALIDATION_ERROR`** for an impossible person. The contract keeps `VALIDATION_ERROR` for `400` and reserves `422` for endpoint-specific codes | generic clients |
| 4 | **`courses.json` must be the CPR's [`shared/courses.json`](../shared/courses.json)**, byte-identical, with course codes matching `^[A-Z]{2,4}$`. Image `4.0.0` still ships the copy taken from Applicant Service before that file existed, and it does not match: 53 entries against the CPR's 49 - the same 49 plus `LEN1` ("Limba Engleză I", year 1, spring) for each of the four majors, a code that also breaks the format. Its `fake_courses.json` (`ELSE-NET`, `QBIT-101`, `WEB5`, …) does not follow the format either | University Record Service, Moderation |
| 5 | **Five CRUD endpoints exist beyond the contract** (`GET` list, `POST`, `GET`, `PATCH`, `DELETE`) | the broker and the Gateway — see [§13](#13-gateway-and-broker-requirements) |
| 6 | **`POST /api/v1/applicants` does not produce `applicant.initialized`** | anyone expecting every applicant to be announced |
| 7 | **The contract read endpoints do not use the `{items, total}` list envelope.** The API conventions prescribe it for lists; both document endpoints are specified with `{applicant_id, documents}` and the endpoint spec wins. The extension list endpoint does use `{items, total}` | anyone writing a generic client |
| 8 | **Forgery is mapped to the document that asserts the claim**, not smeared across the bundle ([§7](#7-validation-rules)). The contract says "the documents that support the false claim"; this table is the reading of *which* | Moderation Service |
| 9 | **The event consumer deduplicates on `applicant_id`, not `event_id`** ([§5.5b](#55b-requests-and-events-through-the-message-broker)). The contract says a consumer "remembers the `event_id` values it has seen"; keying on the document's primary key gives the same idempotency without a second collection or a transaction, and additionally folds two producers announcing the same applicant into one | nobody in practice; noted for the record |

**Lab 4 (`4.0.0`).** Built against the broker contract proposed for CPR issue #105 before it was
merged: `broker.proto` (package `broker.v1`) is vendored in `api/proto/` byte for byte, with
the queue and topic names, the ack outcomes, the `x-service-token` metadata and the logs
endpoint as the Lab 4 brief proposed them. Where the merged contract differs, the contract wins
and this section gets a line.

**Decided by the team, to be written into the contract on #105:** the service token travels only
as the `x-service-token` metadata of a gRPC call to the broker, never in a request's `headers`.
The broker and the Gateway never put it there; if a request carries it anyway, this service
drops it, and `Authorization` with it, before the handler runs. CPR issue #107 still says the
token travels in the headers: that line is from the first version of the issues and no longer
holds.

Choices the proposal left open, none of which changes an answer the contract defines:

- The client's keepalive pings every 10 s, not the brief's 2 s: grpc-go raises anything shorter
  to 10 s and warns on every dial. The broker's own pings stay at 2 s, so it still notices a dead
  instance within about 4 s; this service notices a dead broker within about 12 s.

- A `Publish` refused with `INVALID_ARGUMENT` is parked; any other refusal is retried and does
  not count against the breaker.
- A request arriving while the instance shuts down is answered `503 SERVICE_UNAVAILABLE` rather
  than left to the broker's timeout.
- `GET /logs` follows the shared definition of CPR issue #112 (README "Logs download", CPR PR
  #123, open when this image was built).
- `/health/ready` reports `parked_events` next to `pending_events`, and `degraded` while the
  broker is not subscribed.
- The MongoDB outbox claims of Lab 3, `REFERENCE_YEAR` and the identity model shared with
  Applicant and University Record are unchanged by Lab 4.

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
arrives — the relay's poll interval plus the broker's delivery normally, longer if the broker or
the producer was down. Clients retry. This is the documented cost of no cross-service writes.

### 12.2 The broker is away

No request reaches the instance except on its REST port, and `/health/ready` says `degraded`
(`components.message_broker: "down"`). The instance subscribes again on its own, 1 s, 2 s, 4 s
... up to 30 s apart, logging `broker.subscribe_failed`, and keeps answering `/health`,
`/status`, `/logs` and `/metrics` all along. An applicant created meanwhile on the REST port is
stored and its event waits in the outbox (`pending_events` climbs); the relay retries with a
backoff that doubles up to 30 s, and after 3 failures within 17.5 s its breaker on the broker
opens: it stops claiming, tries one trial publish every 17.5 s, and drains the backlog once a
trial goes through ([§8.6](#86-several-instances-and-the-circuit-breaker)).

A **consumer** being down costs this service nothing: the broker keeps its copy of every event
in that consumer's queue. No peer events arrive while the broker is away; they wait in the
producers' outboxes.

### 12.3 MongoDB is away

`/health/ready` answers `503` and reads and writes return
`500 DEPENDENCY_UNAVAILABLE` with `details.dependency = "mongodb"`. Nothing is changed.

### 12.4 The same event arrives twice

Ingest is an insert keyed on `applicant_id`, so the second arrival changes nothing and is
acked `OK` with reason `duplicate`, on whichever instance it reaches. No read-then-write race to
lose, and the email reservations of the first arrival are the only ones made.

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

## 13. Gateway and broker requirements

What the Gateway ([`docs/GATEWAY.md`](GATEWAY.md))
and the Message Broker must do for this service, prefix and queue `credential`:

| Route | At the Gateway (Lab 4) | Through the broker |
| --- | --- | --- |
| `GET /api/v1/applicants/{id}/documents` | **The one player route**: `GET {gateway}/api/v1/credential/applicants/{id}/documents` with a player token | the Gateway's request |
| `GET /api/v1/applicants/{id}/documents/validation` | `404` | Moderation Service |
| `POST /api/v1/applicants/next` | `404` | no caller yet |
| `GET /health` | public | - |
| Everything else: the five extensions, `/health/ready`, `/status`, `/logs`, `/metrics`, `/dev/*`, `/events` | `404` | not used |

- **`GET .../documents/validation` must never reach a player.** It is the answer key. Since
  Lab 4 it is not a Gateway route at all; the broker delivers it, and the broker accepts calls
  only with the service token. This service checks nothing itself.
- A request the broker delivers can name any path of the router, so the broker must accept
  requests only with the service token, and the Gateway must forward only the player route
  above. The five extension endpoints are administrative: `POST` and `PATCH` can manufacture any
  applicant at all.
- **Neither the broker nor anyone else may redeliver `POST /api/v1/applicants/next`.** It is
  not idempotent. When the instance fails while holding a non-`GET` request, the broker answers
  `503`, because it may already have run.
- Every response, including errors, is JSON. Rate limiting, if added, should keep the
  `{"error":{"code","message","details"}}` envelope so clients need only one error path.

## 14. Running several instances

**The HTTP layer is stateless.** No sessions, no sticky routing, no in-memory per-client state,
so any copy may serve any request: every copy subscribes to `requests.credential`, and the
broker hands each request to the least loaded copy whose breaker is closed. The team compose runs 2 copies
(`deploy.replicas: 2`) against the one database; `docker compose up -d --scale
credential-service=3` adds a third. Every answer is the same whichever copy gives it.

**Registration with Service Discovery.** Each copy registers itself as soon as its listener is
up, directly with Service Discovery, with the topics it publishes and subscribes to (CPR issue
#111):

```
PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/credential-<hostname>
X-Service-Token: {SERVICE_TOKEN}
{"service_name": "credential", "port": 8082, "version": "4.0.0",
 "topics": {"publishes": ["events.applicant.initialized"],
            "subscribes": ["events.applicant.initialized"]}}     (+ "host" only with INSTANCE_HOST)
```

The same `PUT` is repeated every 5 s as the heartbeat; Service Discovery forgets a copy it has
not heard from for 15 s, and the first `PUT` after a Service Discovery restart registers it
again. Every call has a 2 s timeout, and a failure only logs `sd.heartbeat_failed` - it never
touches a request. On `SIGTERM` / `SIGINT` the copy stops its heartbeat, sends
`DELETE /api/v1/instances/{instance_id}` (2 s at most), so the broker stops choosing it; then it
leaves the broker, answering every delivery in progress on the open stream before closing it
([§5.5b](#55b-requests-and-events-through-the-message-broker)); and only then stops the REST
port, drains in-flight requests, stops the relay and disconnects from MongoDB.

| Concern | Behaviour |
| --- | --- |
| Indexes at startup | `CreateMany` on every start; creating an index that already exists is a no-op, so copies starting together all succeed and all start |
| Backfill at startup | Two atomic `UpdateMany`s (entries without deliveries; entries waiting for Lab 3 consumers), each matching only what is left to do: copies starting together cannot open a delivery twice |
| Events from the broker | The dedup is the `applicant_id` primary key: a second insert of the same applicant is a duplicate-key error, acked `OK` as a `duplicate`, whichever copy receives it |
| Email namespace | `email_reservations` is keyed on the lower-cased address, so two copies racing for one name cannot both win; reservations carry the applicant id and are handed back when the applicant is not stored |
| Outbox relay | Per-delivery conditional claims with a lease covering the whole batch and a claim token ([§8.6](#86-several-instances-and-the-circuit-breaker)) |
| Circuit breaker | One, on the broker, in each copy, in memory. It decides when that copy publishes, never what a request answers - the one piece of state per process besides the task limiter, the subscription and the connection pools |
| Generator | `GENERATOR_SEED=0` (the default) in any multi-copy deployment; a fixed seed makes every copy generate the same applicants in lockstep |

**Connection budget:** each copy opens up to `DB_MAX_POOL_SIZE` (20) MongoDB connections and one
gRPC connection to the broker, which carries the stream and every call; three copies use at most
60 MongoDB connections, well within a standalone MongoDB's limit.

**Personal addresses are drawn, not reserved.** A university address is unique across all
copies. The personal address of an alumnus or an outsider is drawn from 40 first names × 40 last
names × 4 domains × a two-digit suffix, 633,600 combinations, and is not reserved, so two
applicants can share one: about a 1 % chance after 100 such applicants, about 50 % after 1,000.
It is the same with one copy or three, and this service treats a personal address as plain
profile data, never as a key.

---

## 15. Observability

**Logs** are one JSON object per line on stdout, in the shape every component shares, whatever
`APP_ENV` says, and the same lines go to the rotating file `LOG_FILE`. Level from `LOG_LEVEL`.
Every line carries `time` (ISO 8601 UTC with milliseconds), `level` (`debug`, `info`, `warn`,
`error`), `service` (`credential`), `instance_id` (which copy wrote it), `version`, `event` (a
stable name, below) and `msg`, plus `request_id` on every line written while handling a request
or an event and on the relay's lines for a publish, and `correlation_id` on every line of a
request the broker delivered.

```json
{"time":"2026-11-02T12:00:00.123Z","level":"info","msg":"request","service":"credential","instance_id":"credential-3f4e2a9b1c7d","version":"4.0.0","event":"http.request","method":"GET","path":"/api/v1/applicants/5d2c8e4a-…/documents","status":200,"duration_ms":7,"client_ip":"172.18.0.12","player_id":"8c1f6a2e-…","request_id":"9d2d…","correlation_id":"7a74…"}
```

**`X-Request-ID`** is read from the request or generated (uuid4), echoed on the response,
printed as `request_id`, stored with the event in the outbox and sent as `request_id` with its
publish.

| `event` | Level | Fields | When |
| --- | --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status`, `/logs` and `/metrics` | `method`, `path`, `status`, `duration_ms` (integer), `client_ip`, `player_id` when `X-Player-Id` is present | Once per request, from the REST port or the broker |
| `http.error` | `warn` for a `4xx`, `error` with `stack` for a `5xx` or a panic | `status`, `code`, `error` | Every error answered, `404`, `405`, `408`, `422` and `429` included |
| `request.received` / `request.replied` | `info`; `warn` when the reply did not reach the broker | `message_id`, `queue`, `method`, `path`, `caller` / `status`, `duration_ms` | A request from the broker arrives / its `Reply` is sent |
| `broker.received` | `debug` | `message_id`, `queue`, `attempt`, `event_id`, `event_type`, `producer` | An event arrives on the subscription |
| `event.received` | `info`; `warn` when rejected | `event_id`, `event_type`, `producer`, `duplicate`, or `error` when it can never be applied | An event applied, recognised as a repeat, or rejected |
| `broker.acked` | `info` for `ok`, `warn` otherwise | `message_id`, `queue`, `attempt`, `event_id`, `event_type`, `outcome` (`ok`, `retry`, `permanent`), `reason` | Every ack |
| `broker.subscribed` / `broker.subscribe_failed` | `info` / `warn` | `broker`, `queue`, `topics` / `code`, `error`, `retry_in_ms` | The stream opens / fails and is opened again after the wait |
| `broker.published` | `info` published, `warn` to retry | `event_id`, `event_type`, `topic`, `attempt`, `code`, `duration_ms`, `message_id`; `next_attempt_at` and `error` when it will be retried | Every publish |
| `event.parked` | `error` | the same, with the reason | The broker refused an event as malformed, or its stored envelope cannot be read — somebody has to look |
| `breaker.opened` / `breaker.half_open` / `breaker.closed` | `warn` / `info` / `info` | `target` (`message-broker`), `failures`, `window_s` (17.5), `retry_at` when opened | Every move of the circuit breaker on the broker |
| `breaker.rejected` | `debug` | `target`, `state`, `failures`, `window_s` | A relay pass skipped while the breaker is open |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` | `info` / `warn` / `info` | `instance_id`, `status`, `error` when failed | The first registration and the first after a failure / a failed heartbeat / shutdown |
| `sd.heartbeat` / `sd.disabled` | `debug` / `warn` | `instance_id` | A routine heartbeat / no `SERVICE_DISCOVERY_URL` |
| `startup` / `shutdown` | `info` | version, instance id, port and the configuration, without secrets | Start and stop |
| `applicant.created` / `.updated` / `.deleted` | `info` | `applicant_id`, `session_id`, `origin`, `event_id` for one created from an event, the archetype and document count of a generated one | Every change to an applicant |
| `logs.file_unavailable` | `warn` | `path`, `error` | Once at startup, when `LOG_FILE` cannot be opened |
| `config`, `db`, `relay`, `email.record_failed`, `email.release_failed`, `generator.retry`, `generator.fallback` | as fits | | Configuration gaps (no broker), the database connection, indexes and the outbox moves at startup, outbox bookkeeping errors, the email namespace, generator edge cases (`generator.fallback` is a bug) |

**Never logged:** `X-Service-Token`, the MongoDB URI (it carries the credentials), request or
response bodies, and anything of an applicant's profile - lines name applicants by
`applicant_id` only.

**`GET /logs?since=&until=&level=`** (CPR issue #112, README "Logs download"), on the REST port,
with `X-Service-Token`: the lines of this instance's log file within the window, oldest first,
across the rotated files and the current one, unchanged.

- **Window:** `since <= time < until` on the line's `time`, so two consecutive windows never
  share a line. Both are optional RFC 3339 times with a zone (`Z` or `+02:00`); `level` keeps
  that level and above. An empty window is an empty `200`.
- **Answer:** `200` with its headers flushed at once, before any file is scanned;
  `Content-Type: application/x-ndjson`, `Content-Disposition: attachment;
  filename="<instance_id>-<since>.jsonl"`, `since` as `20261105T112700Z`, or `start` without it.
- **Errors:** `403 SERVICE_TOKEN_REQUIRED` without the token, `401 INVALID_SERVICE_TOKEN` with a
  wrong one; `400 VALIDATION_ERROR` with `details.errors: [{field, message}]` for a malformed time,
  a time without a zone, `until <= since` or an unknown `level`; `503 LOGS_UNAVAILABLE` without a
  log file, or when its files cannot be opened.
- **No broken lines:** every file is opened under the lock the writer takes, before any is read,
  so a rotation is wholly before or after the download, and an open file keeps its content when
  a rotation renames it. The current file is read only up to its size at that moment. A last line
  without its newline, and any line that is not one whole JSON object, is left out.
- **Limits:** outside the concurrent task limit and the task timeout, and the handler lifts the
  server's write timeout (`HTTP_WRITE_TIMEOUT`, 10 s) for itself, so a busy instance can still be
  read and a long download is not cut off; its access line is at `debug`.

The file is `LOG_FILE`, rotated at `LOG_FILE_MAX_MB` with `LOG_FILE_KEEP` old files named
`credential-<UTC time of the rotation>.jsonl`, written through `io.MultiWriter(os.Stdout, file)`
with `gopkg.in/natefinch/lumberjack.v2`. It belongs to one container: never share a volume between
copies.

**`GET /metrics`** (Prometheus text format), on the REST port, no credential, outside the limit:

| Metric | Type | Labels |
| --- | --- | --- |
| `http_requests_total` | counter | `method` (`OTHER` for a non-standard one), `route` (the route template, `unmatched` for none), `status` |
| `http_request_duration_seconds` | histogram | `method`, `route` |
| `tasks_in_flight` | gauge | - the requests holding a slot of the concurrent task limit |
| `breaker_state` | gauge | `target="message-broker"`: 0 closed, 1 open, 2 half-open (only with a broker) |
| `outbox_pending`, `outbox_parked` | gauge | - counted in MongoDB at scrape time, left out of a scrape when it does not answer within 1 s |
| `go_*`, `process_*` | | the Go runtime's and the process's own |

Requests from the broker go through the same router, so they are counted like any other.
**No tracing**: there is no OpenTelemetry.
