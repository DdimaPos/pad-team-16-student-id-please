# Message Broker Service - Integration Reference

> **Status:** the base (#103), under review in vvtttvv/message-broker-service#1; no image published yet. It holds the data
> model, the in-memory core, `/health`, `/status`, `GET /api/v1/topics` and the registration with Service Discovery.
> The gRPC server runs with no RPC yet. Coming on top: the gRPC API (#106), request/reply, load balancing and breakers
> per instance (#107), durability and dead letters (#108), thread-per-request and rerouting (#109). The compose block is
> #113. The shared names below are a proposal until the contract of #105 merges; the contract wins where they differ.

## 1. What this service is

The tenth component, from Lab 4. Services publish their events to topics without knowing who listens; the Gateway and
the services send requests to a service's queue; the broker stores the messages, picks the instance and keeps the
circuit breakers. It owns topics, queues, subscriptions and delivery state. It owns no business data: an event's
envelope passes through byte for byte. Contract: CPR README "Communication Contract" (#105).

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn (HTTP), `grpcio` (gRPC), httpx |
| **Ports** | HTTP `8070`, gRPC `8071` (host `8070`, `8071`) |
| **Address in the stack** | `http://message-broker-service:8070`; `MESSAGE_BROKER_URL=message-broker-service:8071` (gRPC target, no scheme) |
| **Health** | `GET /health`, `GET /status` (no credential) |
| **Credential** | `X-Service-Token` on every `/api/v1` route, checked by the broker itself |
| **Storage** | in memory in the base; durable from #108 |
| **Calls out** | Service Discovery (registers as `message-broker`) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `d1vinexd/message-broker-service:<lab version>` and `:latest`, published by GitHub Actions on merge to `main` |
| **Instances** | one copy |

**Why Python.** The lab asks for the team's banned language or one not used in a service. Python reuses the logging,
status and breaker modules of Service Discovery, and `grpc.server` with a thread pool gives one thread per RPC. The
limit: the GIL runs one thread of Python at a time, so the threads give concurrency for waiting on streams and disk,
not parallel CPU.

## 3. Running it

```bash
docker run --rm --network student-id-net --name message-broker-service -p 8070:8070 -p 8071:8071 \
  -e SERVICE_TOKEN=... -e SERVICE_DISCOVERY_URL=http://service-discovery-service:8090 \
  d1vinexd/message-broker-service:4.0.0
curl http://localhost:8070/health
# {"status":"ok","service":"message-broker","version":"4.0.0"}
```

Building from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVICE_TOKEN` | none, required | The stack's one `X-Service-Token`. The broker does not start without it |
| `APP_PORT` | `8070` | HTTP port |
| `GRPC_PORT` | `8071` | gRPC port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout of the HTTP side: `408 REQUEST_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit of the HTTP side: `429 TOO_MANY_REQUESTS` + `Retry-After` |
| `RETRY_AFTER_SECONDS` | `1` | `Retry-After` of a `429` |
| `GRPC_MAX_WORKERS` | `64` | gRPC worker threads; a `Subscribe` stream holds one for its whole life |
| `MESSAGE_QUEUE_MAX_DEPTH` | `10000` | Most messages in one queue, or kept by one topic |
| `MESSAGE_MAX_TOPICS` | `1000` | Most topics |
| `SERVICE_DISCOVERY_URL` | empty | Empty: the broker does not register (one `sd.disabled` warning at startup) |
| `SERVICE_DISCOVERY_HEARTBEAT_SECONDS` | `5` | Heartbeat interval |
| `SERVICE_DISCOVERY_TIMEOUT_SECONDS` | `2` | Timeout of a call to Service Discovery |
| `INSTANCE_ID` | `message-broker-<hostname>` | Its own id, in its logs and `/status` |
| `INSTANCE_HOST` | empty | Sent as `host` at registration, for a run outside Docker |

## 5. Data model

| Name | Example | What |
| --- | --- | --- |
| Topic | `events.session.started` | `events.<event_type>`. Producers name a topic, never a consumer. Created by its first publish or subscribe |
| Topic queue | `events.session.started.discord-dms` | `<topic>.<service>`, one per subscribed service, shared by its instances |
| Request queue | `requests.player` | `requests.<service>`, one per service; an instance that subscribes gets it automatically (#107). Not a topic, so not listed under `/api/v1/topics` |

A topic name matches `events(\.[a-z][a-z0-9_]*)+`, a service `[a-z][a-z0-9-]*`, an instance id `[A-Za-z0-9._-]+`, each
at most 200 characters.

- **A message reaches each subscribed service once**, whatever the number of its instances, and one instance of it. Each
  queue's copy has its own `message_id`, which is what the consumer acks.
- **A subscription belongs to the service.** Its queue collects messages while none of its instances is connected.
- **A topic with no subscribed service keeps the message**, and every service that subscribes later gets a copy.
- **An instance holds at most `max_concurrent_tasks` unacked messages.** Beyond that, messages wait in the queue.

## 6. Endpoints

### `GET /health`

`200 {"status": "ok", "service": "message-broker", "version": "4.0.0"}`, no credential.

### `GET /status`

The shape of README "Status endpoint", `service` is `message-broker`, no credential, outside the concurrent task limit.

```json
{ "service": "message-broker", "instance_id": "message-broker-3f4e2a9b1c7d", "version": "4.0.0", "status": "up",
  "in_flight": 0, "max_concurrent_tasks": 64 }
```

### `GET /api/v1/topics`

Needs `X-Service-Token` (`403 SERVICE_TOKEN_REQUIRED` without it, `401 INVALID_SERVICE_TOKEN` when wrong). Every topic
with the queue of each subscribed service, the same shape as `ListTopics` of `broker.proto`. `depth` counts the messages
not acked yet, delivered ones included.

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

### gRPC on `8071`

`broker.proto` comes with #105 and the servicer with #106. Until then every call answers `UNIMPLEMENTED`.

## 7. Edge cases

- **A full queue, or too many topics:** a publish or subscribe is refused and changes nothing, so the producer's outbox
  retries. It never drops a message and never grows without a limit.
- **A store that fails:** the call is refused and nothing changes. The store is called before the broker's own state.
- **A reconnect with the same `instance_id`** replaces the old stream and ends it. The end of the old stream does not
  remove the new one.
- **A repeated or unknown ack** changes nothing and is not an error. An ack from an instance that does not serve the
  queue is refused and logged (`broker.ack_refused`). An instance can still ack after its stream ended.
- **A message never acked** stays held and counts in `depth`. Redelivery comes with #106 and #108.
- **Service Discovery unreachable:** `sd.heartbeat_failed` is logged, retried on the next tick; the broker keeps serving.
- **After a restart** the in-memory base has lost everything; durability is #108.

## 8. Logs

The fields of README "Logging", with `service: message-broker`. A service is named by `service_name` and an instance by
`instance`, because `service` is the shared field. **A message's body is never logged**, because it holds applicant
data; only its ids are. The service token is never logged.

| Event | Level | Fields |
| --- | --- | --- |
| `broker.topic_created` | `info` | `topic` |
| `broker.published` | `info` | `topic`, `message_id`, `event_id`, `event_type`, `producer`, `request_id`, `queues`, `kept` |
| `broker.subscribed` / `broker.unsubscribed` | `info` | `service_name`, `instance`; `topics`, `max_concurrent_tasks`, `reconnect` when subscribing |
| `broker.delivered` / `broker.acked` | `info` | `topic`, `queue`, `message_id`, `event_id`, `service_name`, `instance`; `attempt` when delivered |
| `broker.ack_refused` | `warn` | `queue`, `message_id`, `instance` |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` / `sd.disabled` | `info` / `warn` / `info` (`warn` when failed) / `warn` | `instance`, `error` when failed |

## 9. Postman

`postman/message-broker-service.postman_collection.json` covers the probes, the topics listing and its token errors.
`base_url` and `service_token` are collection variables; the token is the placeholder of `.env.example`.
