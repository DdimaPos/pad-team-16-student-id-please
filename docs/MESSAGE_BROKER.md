# Message Broker Service - Integration Reference

> **Status:** `4.0.0`, the first release (Lab 4): the base (#103), the gRPC API (#106), the log file and `GET /logs`
> (#112), request/reply, routing by load and a breaker per instance (#107), durable queues and the dead letter channel
> (#108), `GET /metrics` (#126), thread-per-request and rerouting (#109). Image `d1vinexd/message-broker-service:4.0.0`.
> The broker is not in `docker-compose.yml` yet: its block, with Prometheus and Grafana, is #113. The shared names
> below run ahead of the README contract until #105 merges; see [§15](#15-divergences-from-the-contract).

## 1. What this service is

The tenth component, from Lab 4. Services publish their events to topics without knowing who listens; the Gateway and
the services send requests to a service's queue; the broker stores the messages, picks the instance and keeps the
circuit breakers. It owns topics, queues, subscriptions and delivery state. It owns no business data (an event's
envelope passes through byte for byte) and not the instance registry (Service Discovery). Contract: CPR README
"Communication Contract" (its Lab 4 part is #105) and "Logs download".

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn (HTTP), `grpcio` (gRPC), httpx, pydantic-settings |
| **Ports** | HTTP `8070`, gRPC `8071` (plaintext HTTP/2), both in one process |
| **Address in the stack** | `http://message-broker-service:8070`; `MESSAGE_BROKER_URL=message-broker-service:8071` (gRPC target, no scheme) |
| **Health** | `GET /health`, `GET /status` (no credential); `GET /status` answers `503 degraded` while the store cannot write |
| **Credential** | `X-Service-Token` on `/api/v1/*` and `GET /logs`, the `x-service-token` metadata on every RPC; checked by the broker itself |
| **Storage** | SQLite in WAL mode at `MESSAGE_STORE_PATH` (`/data/broker.db`), a named volume on `/data` (#108) |
| **Calls out** | Service Discovery: registration as `message-broker`, the instance list, the mark-down, one alert per dead letter |
| **Logs / metrics** | `GET /logs` (#112), `GET /metrics` in the Prometheus text format (#126) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `d1vinexd/message-broker-service:4.0.0` and `:latest`, published by GitHub Actions on merge to `main` |
| **Instances** | one copy |

**Why Python.** The lab asks for the team's banned language or one not used in a service. Python reuses the logging,
status and breaker modules of Service Discovery, and `grpc.server` with a thread pool gives one thread per RPC. The
limit: the GIL runs one thread of Python at a time, so the threads give concurrency for waiting on streams and disk,
not parallel CPU. A broker mostly waits, so this is acceptable here.

## 3. Running it

```bash
docker run --rm --network student-id-net --name message-broker-service -p 8070:8070 -p 8071:8071 \
  -v broker-data:/data \
  -e SERVICE_TOKEN=... -e SERVICE_DISCOVERY_URL=http://service-discovery-service:8090 \
  d1vinexd/message-broker-service:4.0.0
curl http://localhost:8070/health
# {"status":"ok","service":"message-broker","version":"4.0.0"}
```

The named volume on `/data` keeps the messages across restarts and new containers; the image creates `/data` owned by
its non-root user, so a new named volume inherits it. Building from source and the test suite are in the service
repository README ("Build, test, run").

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVICE_TOKEN` | none, required | The stack's one `X-Service-Token`. The broker does not start without it |
| `APP_PORT` | `8070` | HTTP port (the image's `CMD` reads it) |
| `GRPC_PORT` | `8071` | gRPC port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout of the HTTP side: `408 REQUEST_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit of the HTTP side: `429 TOO_MANY_REQUESTS` + `Retry-After`; the HTTP handlers' thread pool is 8 more |
| `RETRY_AFTER_SECONDS` | `1` | `Retry-After` of a `429` |
| `GRPC_MAX_WORKERS` | `64` | gRPC worker threads and the most RPCs in progress (one more is `RESOURCE_EXHAUSTED`); a `Subscribe` stream holds one for its whole life, a `Request` until its reply |
| `GRPC_RESERVED_WORKERS` | `16` | Workers the streams and waiting requests never take, kept for `Reply`, `Ack`, `Publish`; fewer than `GRPC_MAX_WORKERS` |
| `MESSAGE_QUEUE_MAX_DEPTH` | `10000` | Most messages in one queue, or kept by one topic |
| `MESSAGE_MAX_TOPICS` | `1000` | Most topics |
| `MESSAGE_ACK_TIMEOUT_SECONDS` | `5` | An event not answered within this time goes out again (the services' task timeout) |
| `MESSAGE_RETRY_DELAY_SECONDS` | `5` | An event answered `RETRY` goes out again after this time |
| `MESSAGE_REDELIVERY_SWEEP_SECONDS` | `1` | How often the broker looks for both |
| `MESSAGE_REQUEST_TIMEOUT_SECONDS` | `10` | How long a request with no `timeout_ms` waits for its reply (the Gateway's task timeout) |
| `MESSAGE_REQUEST_MAX_TIMEOUT_SECONDS` | `60` | The most a request's `timeout_ms` may ask for |
| `REQUEST_BREAKER_WINDOW_SECONDS` | `35` | Window and cooldown of the breaker per instance: the Gateway's 10 s x 3.5 |
| `MESSAGE_STORE_PATH` | `/data/broker.db` | The SQLite file; its directory is created. Empty = in memory, a restart loses everything (one `store.in_memory` warning) |
| `MESSAGE_MAX_ATTEMPTS` | `3` | Failed deliveries of an event before it goes to the dead letter channel |
| `MESSAGE_RETENTION_HOURS` | `24` | An acked message is deleted from the disk after this time |
| `MESSAGE_RETENTION_SWEEP_SECONDS` | `60` | How often the retention sweep runs |
| `SERVICE_DISCOVERY_URL` | empty | Empty: the broker does not register, reads no instance list, marks nothing down and sends no dead letter alert (one warning line at startup) |
| `SERVICE_DISCOVERY_HEARTBEAT_SECONDS` | `5` | Heartbeat interval |
| `SERVICE_DISCOVERY_REFRESH_SECONDS` | `5` | How often the instance list and loads are read |
| `SERVICE_DISCOVERY_TIMEOUT_SECONDS` | `2` | Timeout of a call to Service Discovery, a dead letter alert included |
| `INSTANCE_ID` | `message-broker-<hostname>` | Its own id, in its logs and `/status` |
| `LOG_FILE` | `/var/log/message-broker/message-broker.jsonl` | The log file next to stdout, read by `GET /logs`; empty = stdout only |
| `LOG_FILE_MAX_MB` | `50` | The file rotates at this size |
| `LOG_FILE_KEEP` | `5` | Rotated files kept next to the current one |
| `INSTANCE_HOST` | empty | Sent as `host` at registration, for a run outside Docker |

## 5. Data model

| Name | Example | What |
| --- | --- | --- |
| Topic | `events.session.started` | `events.<event_type>`. Producers name a topic, never a consumer. Created by its first publish or subscribe |
| Topic queue | `events.session.started.discord-dms` | `<topic>.<service>`, one per subscribed service, shared by its instances |
| Request queue | `requests.player` | `requests.<service>`, one per service; an instance that subscribes gets it automatically. Not a topic, so not listed under `/api/v1/topics` |

A topic name matches `events(\.[a-z][a-z0-9_]*)+`, a service `[a-z][a-z0-9-]*`, an instance id `[A-Za-z0-9._-]+`, each
at most 200 characters; anything else is `INVALID_ARGUMENT`.

- **A message reaches each subscribed service once**, whatever the number of its instances, and one instance of it. Each
  queue's copy has its own `message_id`, which is what the consumer acks.
- **A subscription belongs to the service** and outlives its instances and a broker restart. Its queue collects
  messages while none of its instances is connected.
- **A topic with no subscribed service keeps the message**, and every service that subscribes later gets a copy.
- **An instance holds at most `max_concurrent_tasks` unanswered messages.** Beyond that, messages wait in the queue.
- **Bounds.** Above `MESSAGE_QUEUE_MAX_DEPTH` or `MESSAGE_MAX_TOPICS` a publish or subscribe is refused
  (`RESOURCE_EXHAUSTED`) and changes nothing, so the producer's outbox retries.

## 6. Delivery semantics (events)

At-least-once: consumers dedupe by `event_id` (README "Event delivery").

| The consumer's answer | What happens |
| --- | --- |
| `Ack` `OK` | The copy leaves the queue. A repeat or an unknown id changes nothing and answers OK; an instance that does not serve the queue is logged (`broker.ack_refused`) and also answered OK |
| `Ack` `RETRY` | Back to the queue after `MESSAGE_RETRY_DELAY_SECONDS`, to another instance when there is one; a failed attempt |
| `Ack` `PERMANENT` | It can never succeed (unknown type or version, a malformed payload): the dead letter channel at once |
| None within `MESSAGE_ACK_TIMEOUT_SECONDS` | Back to the front of its queue and out again, to another instance when one is connected, `attempt` one higher; a failed attempt. A late ack still settles it |
| The instance's breaker trips or its stream ends | Rerouted at once (see [§11](#11-rerouting-109)); a failed attempt |

- **Attempts.** Every delivery that ends without an ack is counted in one place and stored. Once `MESSAGE_MAX_ATTEMPTS`
  (3) deliveries have failed, the event goes to the dead letter channel instead of its queue. `Delivery.attempt` is the
  number of the delivery, so the consumer sees 1, 2, 3. A delivery cut by a broker restart does not count.
- **Dead letters.** One keeps the copy's `message_id`, its queue, the attempts, the reason (the consumer's for
  `PERMANENT`; `out of attempts (3): <last reason>` otherwise), `created_at`, `dead_at` and the last delivery with the
  envelope. The store writes it and drops the copy in one transaction, so it is neither lost nor delivered again. It
  stays until a person deals with it: the listing is read-only in `4.0.0`. Each one logs `broker.dead_lettered`.
- **The alert.** One `POST {SERVICE_DISCOVERY_URL}/api/v1/alerts` per dead letter, `{"kind": "dead_letter",
  "service_name": <the queue's service>, "instance_id": <the broker's>, "detail": <ids, queue, attempts, reason; at
  most 500 characters>}` with `X-Service-Token`, which reaches the Telegram group with Service Discovery's cooldown. A
  daemon thread fed by a bounded queue (1000) sends it, so it never blocks a gRPC thread or the event loop, and only
  after the dead letter is on disk: Service Discovery down costs that alert only (`broker.alert_failed`, no retry), a
  full queue drops it (`broker.alert_dropped`). `detail` never holds the envelope.

## 7. Durability (#108)

Events only: a request is never stored, because it lives only as long as its caller waits.

- **On disk before the answer.** One SQLite file in WAL mode, one transaction per change, committed before the call
  returns. A publish, a subscription and a dead letter are fsynced (`synchronous=FULL`), so `Publish` answers only once
  the message and its copies are on disk and the producer's outbox may mark the event delivered. An ack, an attempt
  count, the retention sweep and the status probe use `synchronous=NORMAL`: they survive a crash of the broker and a
  restart of its container; only a host crash or power loss can undo the last of them (an acked event is then
  delivered once more and dropped by its `event_id`).
- **Restart.** The broker loads the subscriptions, the kept messages and every copy not acked yet, and rebuilds its
  queues before it takes a call; the instances reconnect on their own. An acked copy is never delivered again; one that
  was delivered but not acked goes out again.
- **Retention.** An acked copy is deleted after `MESSAGE_RETENTION_HOURS`, with the published message once no copy
  refers to it. A kept message stays while its topic keeps it, a dead letter until it is dealt with.
- **The disk gone** (full, read-only, an I/O error): the transaction is rolled back and nothing changes. `Publish`,
  `Subscribe` and `Ack` answer `UNAVAILABLE` (the producer's relay retries; it does not park the event), and
  `GET /status` answers `503` with `"status": "degraded"` until a write succeeds again. One `store.unavailable` line
  per streak, one `store.recovered` when it ends. A store that cannot be opened stops the start.

## 8. HTTP API on `8070`

`/api/v1/*` and `GET /logs` need `X-Service-Token`: `403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN`
when wrong. The port is published on the host, and the listings name the system's queues and hold envelopes.

### `GET /health`

`200 {"status": "ok", "service": "message-broker", "version": "4.0.0"}`, no credential.

### `GET /status`

The shape of README "Status endpoint", `service` is `message-broker`, no credential, outside the concurrent task limit.
`in_flight` and `max_concurrent_tasks` are the HTTP side's (Service Discovery's load). `grpc_in_flight` is the gRPC
threads running an RPC now, streams included, out of `grpc_max_workers` (#109); it is not part of that load, since the
streams hold their threads for good.

```json
{ "service": "message-broker", "instance_id": "message-broker-3f4e2a9b1c7d", "version": "4.0.0", "status": "up",
  "in_flight": 0, "max_concurrent_tasks": 64, "grpc_in_flight": 10, "grpc_max_workers": 64 }
```

`503` with the same body and `"status": "degraded"` while the store cannot write (#108). It answers from the outcome of
the last write, or writes a small probe when that is older than 10 s or failed.

### `GET /api/v1/topics`

Every topic with the queue of each subscribed service, the same shape as `ListTopics`. `depth` counts the messages not
acked yet, delivered ones included.

```json
{
  "topics": [
    {
      "name": "events.session.started",
      "queues": [
        { "name": "events.session.started.discord-dms", "service": "discord-dms", "depth": 0, "subscribers": 2 },
        { "name": "events.session.started.university-record", "service": "university-record", "depth": 1, "subscribers": 2 }
      ]
    }
  ]
}
```

### `GET /api/v1/dead-letters?limit=&offset=`

The dead letter channel (#108), newest first, `{"items", "total"}` as README "API conventions". `limit` 1 to 100
(default 20), `offset` from 0; anything else is `400 VALIDATION_ERROR` with `details.errors: [{field, message}]`.
`503 STORE_UNAVAILABLE` when the store cannot be read. An item has the fields of `DeadLetter` in `broker.proto`; times
are ISO 8601 in UTC.

```json
{
  "items": [
    {
      "message_id": "6f1c...", "queue": "events.session.ended.player", "attempts": 3,
      "reason": "out of attempts (3): ack timeout",
      "created_at": "2026-11-07T10:00:00.000Z", "dead_at": "2026-11-07T10:00:16.004Z",
      "delivery": {
        "message_id": "6f1c...", "queue": "events.session.ended.player", "attempt": 3, "request_id": "req-1",
        "event": {"event_id": "e1", "event_type": "session.ended", "producer": "session", "version": 1,
                  "envelope_json": "{\"event_id\": \"e1\", ...}"}
      }
    }
  ],
  "total": 1
}
```

`envelope_json` is the envelope as the producer sent it, as a string; one whose bytes are not UTF-8 comes as
`envelope_base64` instead.

### `GET /logs?since=&until=&level=`

README "Logs download" (#112): this instance's lines across the rotated files and the current one, oldest first,
`application/x-ndjson`, `Content-Disposition: attachment; filename="<instance_id>-<since>.jsonl"`. The window is
`since <= time < until`, both optional, a time with its zone; `level` keeps that level and above.
`400 VALIDATION_ERROR` naming the field, `503 LOGS_UNAVAILABLE` without a log file. Outside the limiter; its access
line is at `debug`. Service Discovery's `GET /api/v1/logs` fetches it with every other component's.

### `GET /metrics`

The Prometheus text format (#126), no credential, outside the limiter, logged at `debug`. No series carries a message
body, a token or a raw path. Prometheus finds the broker through Service Discovery (#111, #113).

| Series | What |
| --- | --- |
| `http_requests_total{method,route,status}`, `http_request_duration_seconds{method,route}` | The HTTP side; `route` is the template (`unmatched` for an unknown path) |
| `tasks_in_flight` | The `in_flight` of `/status` |
| `breaker_state{target}` | 0 closed, 1 open, 2 half-open, one series per instance's breaker; `target` is the instance id. A breaker exists from the instance's first failure and is dropped when its stream ends, so an instance that has not failed has no series rather than a `0` |
| `broker_queue_depth{queue}` | Messages of a queue not acked yet: every topic queue and every `requests.<service>` queue |
| `broker_messages_total{queue,outcome}` | `published`, `delivered`, `acked`, `retried`, `redelivered`, `rejected` (`PERMANENT`), `dead_lettered` (out of attempts) |
| `broker_redeliveries_total` | `retried` and `redelivered` together |
| `broker_dead_letters_total` | Every message handed to the dead letter channel |
| `broker_request_duration_seconds{service}` | From a `Request` to its answer, for the requests an instance answered |

**The `service` label once scraped.** Service Discovery's `GET /api/v1/instances/prometheus` gives every target the
label `service`, `message-broker` for the broker. Prometheus scrapes without `honor_labels`, so a target cannot
override the labels it attaches, and renames the broker's own `service` label to `exported_service`. In Prometheus the
called service of `broker_request_duration_seconds` is therefore `exported_service`:
`broker_request_duration_seconds_count{exported_service="player"}`.

## 9. gRPC API on `8071`

`app/brokerpb/broker.proto` of the service repository, package `broker.v1`, plaintext HTTP/2 inside `student-id-net`.
The services build their clients from byte-identical copies of this file (see [§15](#15-divergences-from-the-contract)).
Every call carries the metadata `x-service-token: <SERVICE_TOKEN>`: missing is `UNAUTHENTICATED`, wrong is
`PERMISSION_DENIED`.

| RPC | What |
| --- | --- |
| `Publish(topic, event_id, event_type, producer, version, envelope_json, request_id)` | `topic` must be `events.<event_type>`. Returns `message_id` once the message is on disk and in every subscribed service's queue (or kept) |
| `Subscribe(service, instance_id, topics, max_concurrent_tasks)` | A stream of `Delivery` (an `event` or a `request`) for as long as the instance is connected: its service's request queue and its queue of each topic. At most `max_concurrent_tasks` unanswered at a time (at least 1). A second stream with the same `instance_id` ends the first |
| `Ack(message_id, instance_id, outcome, reason)` | `OK`, `RETRY` or `PERMANENT` (see [§6](#6-delivery-semantics-events)). Idempotent. `reason` is logged, at most 200 characters, never a body. Never settles a request |
| `ListTopics()` | The same listing as `GET /api/v1/topics` |
| `Request(service, correlation_id, method, path, headers, body, request_id, caller, timeout_ms)` | Blocks until one instance of `service` replies, the timeout passes or the instance is lost (see [§10](#10-requestreply-routing-and-breakers)). A broker-side outcome is a normal `ServiceReply` with the shared error envelope, never a gRPC error |
| `Reply(reply, message_id)` | The instance's answer (`status`, `headers`, `body`) to a request it received on its stream, passed to the caller unchanged. Always OK: a reply after the request was settled is dropped and logged |
| `ListDeadLetters(limit, offset)` | The same listing as `GET /api/v1/dead-letters`. `limit` 0 means 20; below 0 or above 100, or a negative `offset`, is `INVALID_ARGUMENT` |

| Status | When | The caller |
| --- | --- | --- |
| `INVALID_ARGUMENT` | A malformed name or message; a malformed request (unknown method, a path without `/`, a bad service name, no `correlation_id`, larger than 4 MiB minus 64 KiB) | Retrying cannot succeed |
| `RESOURCE_EXHAUSTED` | A full queue or too many topics; every gRPC worker busy; a `Subscribe` above the workers for long calls | Retry later: the outbox keeps the event pending, an instance subscribes again with backoff |
| `UNAVAILABLE` | The store cannot write (`Publish`, `Subscribe`, `Ack`) or be read (`ListDeadLetters`) | Retry later |

A stream ends when the client goes away (gRPC keepalive notices a dead one within about 4 s), when the instance
reconnects, or when the broker stops; the instance then reconnects with backoff.

## 10. Request/reply, routing and breakers

The Gateway (and a service calling another) sends `Request`; the broker puts it into `requests.<service>`, delivers it
on one instance's stream as `Delivery.request`, and waits on the caller's worker thread for that instance's `Reply`
(#107). A request is never stored, never acked and never sent twice blindly: a non-`GET` may already have run.

| What happened | `ServiceReply` |
| --- | --- |
| The instance replied | its `status`, `headers` and `body`, unchanged; `instance_id` names it |
| No instance of the service is subscribed, or every one is skipped by its open breaker | `503 SERVICE_UNAVAILABLE`, `details.service`, at once |
| The workers for long calls are taken | `429 TOO_MANY_REQUESTS`, `Retry-After`, at once |
| No reply within the timeout | `408 REQUEST_TIMEOUT` |
| The holding instance's stream ended or its breaker tripped | a `GET` rerouted (see [§11](#11-rerouting-109)), any other method `503` at once |
| A reconnect of the same `instance_id` replaced the holding stream | a `GET` rerouted, any other method `503` at once |
| The last instance of the service left while it waited, or the broker is stopping | `503`, `details.service`, at once |

- **Timeout.** The request's `timeout_ms` (the Gateway sends 10 000, Session 3 000, Moderation 4 000),
  `MESSAGE_REQUEST_TIMEOUT_SECONDS` when it is 0, at most `MESSAGE_REQUEST_MAX_TIMEOUT_SECONDS`, never past the call's
  gRPC deadline. The instance gets that timeout less a margin (a tenth, at most 250 ms), so its own `408` arrives first.
- **Headers** pass through, except `X-Service-Token` and `Authorization`, which never leave the broker. A service tells
  a service call from a player's by the absence of `X-Player-Id`.
- **A caller that goes away** takes its request out of the queue or frees the instance's slot, with nothing recorded
  against the instance.
- **Routing by load.** Every message, events included, goes to a connected instance below its `max_concurrent_tasks`
  with the lowest load: the higher of the broker's `unsettled / max_concurrent_tasks` and Service Discovery's `load`
  (read every `SERVICE_DISCOVERY_REFRESH_SECONDS`), round-robin among ties. Service Discovery's list is a preference:
  an instance it no longer lists is avoided while another is available. A request never goes to an instance whose
  breaker is open; an event falls back to any connected instance.
- **A breaker per instance**, ported from the Gateway (README "Circuit breaker"). A failure is no reply in time, the
  loss of the stream while it held the request, or a `5xx` except `500 DEPENDENCY_UNAVAILABLE`. The 3rd failure within
  `REQUEST_BREAKER_WINDOW_SECONDS` (35) opens it; after the same time one trial request goes through. Every trip marks
  the instance down in Service Discovery once: `PUT /api/v1/instances/{instance_id}/status`
  `{"status": "down", "reason": "breaker_open: 3 failures in 35s"}` (`marked_down_by: broker`); the trip after a
  failed trial sends `"reason": "breaker_open: trial request failed"`. An instance Service Discovery lists again after
  the trip has its breaker closed at once.
- **Workers.** Streams and waiting requests together never hold more than `GRPC_MAX_WORKERS - GRPC_RESERVED_WORKERS`
  (48 of 64), so `Reply`, `Ack` and `Publish` always find a thread and a burst cannot get healthy instances blamed.

## 11. Rerouting (#109)

When an instance's breaker trips or its stream ends, what it holds goes elsewhere at once instead of at a timeout:

| What it held | Another instance can take it | None can |
| --- | --- | --- |
| An event | back to the front of its queue as a failed attempt and delivered to the other instance | it waits for the next instance; after a trip with no other instance connected it goes back to the same one |
| An event out of attempts | the dead letter channel | the same |
| A `GET` | sent again under a new `message_id`, `attempt + 1`, within the caller's remaining timeout | `503 SERVICE_UNAVAILABLE` |
| Any other method | `503`: it may have run already | `503` |

A late `Ack` from the failed instance still settles its event; a late `Reply` is dropped. No event is rerouted after a
reconnect of the same instance (the old stream's events go out after the ack timeout); a request the old stream held is
rerouted when it is a `GET` and answered `503` otherwise, as in [§10](#10-requestreply-routing-and-breakers). Nothing
is rerouted while the broker stops. Every message taken back is logged `broker.rerouted`.

## 12. Threading model (#109)

Every request, gRPC or HTTP, runs on a thread of its own from a bounded pool, and a full pool refuses a new call at
once instead of queueing it: gRPC on `grpc.server`'s pool of `GRPC_MAX_WORKERS` (one more RPC is `RESOURCE_EXHAUSTED`),
HTTP handlers on AnyIO's pool of `MAX_CONCURRENT_TASKS` + 8, with the `/api/v1` limit applied on the event loop before
a thread is taken. A stalled subscriber blocks only its own stream's thread. The pool arithmetic, the locks and the
GIL limit are in the service README, "Threading model".

## 13. Edge cases

- **A reconnect with the same `instance_id`** replaces the old stream and ends it; the events the old stream held go
  out again after the ack timeout.
- **Service Discovery unreachable:** heartbeats are retried on the next tick, the last instance list and loads are
  kept, an empty list is believed only the third time in a row, and a failed mark-down leaves the open breaker alone to
  skip the instance. The broker keeps serving.
- **Service Discovery polls the broker's `/status`** like any instance's, so a `503 degraded` counts as a failed check
  (README "Service Discovery").
- **No `SERVICE_DISCOVERY_URL`:** no registration, no instance filter (the load is the broker's own count), no
  mark-down, no dead letter alert, only the log lines.
- **No `MESSAGE_STORE_PATH`:** the in-memory store; a restart loses every message.

## 14. Logs

The fields of README "Logging", with `service: message-broker`. A service is named by `service_name` and an instance by
`instance`, because `service` is the shared field. **A message's body is never logged**, because it holds applicant
data; only its ids are. The service token and a request's query string are never logged. The full table is in the
service README, "Logs"; the events an integrator meets most:

| Event | Level | Fields |
| --- | --- | --- |
| `broker.published` | `info` | `topic`, `message_id`, `event_id`, `event_type`, `producer`, `request_id`, `queues`, `kept` |
| `broker.subscribed` / `broker.unsubscribed` | `info` | `service_name`, `instance`; `topics`, `max_concurrent_tasks`, `reconnect` when subscribing |
| `broker.delivered` / `broker.acked` | `info` | `topic`, `queue`, `message_id`, `event_id`, `service_name`, `instance`; `attempt` when delivered |
| `broker.ack_refused` | `warn` | `queue`, `message_id`, `instance` |
| `broker.redelivered` | `info` | `queue`, `message_id`, `event_id`, `instance`, `attempt`, `reason` |
| `broker.dead_lettered` | `warn` | `topic`, `queue`, `message_id`, `event_id`, `event_type`, `attempt`, `reason` |
| `broker.rerouted` | `warn` | `kind`, `queue`, `message_id`, `from_instance`, `to_instance`, `attempt`, `reason`, `outcome` |
| `broker.alert_sent` / `broker.alert_failed` / `broker.alert_dropped` | `info` / `warn` / `warn` | `message_id`, `service_name` when sent, `error` when failed |
| `request.sent` / `request.replied` / `request.timeout` / `request.lost` | `info` / `info` (`warn` when late) / `warn` / `warn` | the request's fields (`service_name`, `correlation_id`, `request_id`, `method`, `path`, `caller`), `instance`, and `status`, `timeout_s` or `reason` |
| `request.no_instance` / `request.refused` / `request.cancelled` | `warn` / `warn` / `info` | the request's fields; `reason` / `held`, `capacity` / `instance`, `delivered` |
| `breaker.opened` / `breaker.half_open` / `breaker.closed` | `warn` / `info` / `info` | `target`, `target_instance`, `failures`, `window_s` |
| `sd.mark_down` | `info`; `warn` when it failed | `target`, `target_instance`, `reason`, `status` |
| `store.unavailable` / `store.recovered` / `store.expired` / `store.in_memory` | `error` / `info` / `info` / `warn` | `operation`, `error`, `error_type` when unavailable; `count` when expired |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` / `sd.disabled` | `info` / `warn` / `info` (`warn` when failed) / `warn` | `instance`, `error` when failed |

## 15. Divergences from the contract

`4.0.0` runs ahead of the README contract, because the Lab 4 contract (#105) is not merged. Until it is, the decisions
posted on #105 and the service README are the reference for the broker's shapes; once it merges, the contract wins
where they differ.

1. **`broker.proto` is not in the CPR.** Its place is `shared/broker.proto`, which #105 adds; until then the services
   build from byte-identical copies of the broker's `app/brokerpb/broker.proto`.
2. **The README still describes Lab 3 delivery:** events pushed through the Gateway to each consumer's
   `POST /api/v1/events`, and requests forwarded by the Gateway to an instance. The topics, queues, `Subscribe`, the
   `Ack` outcomes, the attempt cap, the dead letter channel and request/reply above are not in the README's
   "Communication Contract", "Event delivery" or "Every arrow in the diagram" yet.
3. **The dead letter alert** uses Service Discovery's `POST /api/v1/alerts` (`kind: dead_letter`, Service Discovery
   #111), which the README "Service Discovery" section does not list yet.
4. **Requeue and discard** of a dead letter (#108's optional `POST .../requeue` and `DELETE`) are not in `4.0.0`; the
   listing is read-only until #105 decides whether they come.
5. **Not in the compose.** The broker's block, its volume and `MESSAGE_BROKER_URL` for the services come with #113.

## 16. Postman

`postman/message-broker-service.postman_collection.json` covers the HTTP side: the probes, the topics and dead letter
listings with their token and paging errors, `GET /logs` and `GET /metrics`. `base_url` and `service_token` are
collection variables; the token is the placeholder of `.env.example`. The collection holds no gRPC call; those are
made with the broker's `scripts/smoke.py`, from the service repository's root (`--broker`, default `127.0.0.1:8071`,
sets the target):

```bash
export SERVICE_TOKEN=...   # the stack's token
python -m scripts.smoke subscribe --service player --instance player-1 --topic events.session.ended
python -m scripts.smoke publish --topic events.session.ended --event-id e1
python -m scripts.smoke topics
python -m scripts.smoke request --service player --method GET --path /api/v1/players   # answered by player-1
```

`publish` sends the whole envelope of README "Event catalog", `occurred_at` included, with `--producer` (default
`smoke`) and `--payload` (default `{}`). To fill the dead letter listing, run the subscriber alone with
`--outcome permanent` and publish again: the event is rejected and appears in `GET /api/v1/dead-letters`.
