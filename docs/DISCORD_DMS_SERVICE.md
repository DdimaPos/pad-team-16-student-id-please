# Discord DMs Service - Integration Reference

Integration reference of the **Discord DMs Service**, one of the eight microservices of the FAF Discord
Moderation game **"Student ID, please"**. This service provides the real-time communication between
the Moderator and the Junior Moderators of a session: it creates the four moderator channels when a
shift starts (step 3 of the saga `shift.start` since Lab 5), moves messages over WebSockets, keeps the
history and archives the channels when the shift ends. It never checks whether what players write is true.

Owner: Racovita Dumitru. Source: the private `discord-DMs-service` repository, linked as a submodule of this CPR.

> **Audience:** developers of the other services of *"Student ID, please"* (Team 16, FAF.PAD21.1), or the Gateway.
> Copied from the service's own README at `v5.0.0`; relative paths below refer to the `discord-DMs-service/` submodule.
> Where the implementation diverges from the CPR contract, the divergence is called out in the last section.

## Integration card

| | |
| --- | --- |
| Language / framework | Go 1.25, Gin, gorilla/websocket |
| Container ports | `8086` WebSocket (`WS_PORT`): the WebSocket is connected directly, in the team stack through the `dms-ws-proxy` that publishes host `8086` in front of the copies; `8096` REST (`APP_PORT`), reached only through the Gateway inside the network, never published, the port every copy registers with Service Discovery |
| Base path | `/api/v1`; a client reaches REST through the Gateway as `{gateway}/api/v1/discord-dms/...`, which the Gateway sends through the Message Broker to `requests.discord-dms` (Lab 4); `GET /api/v1/ws` reached **directly** on port `8086` |
| Message Broker | `MESSAGE_BROKER_URL` (`message-broker-service:8071`, gRPC): every copy keeps a `Subscribe` stream for `requests.discord-dms` (the Gateway's player routes and, from Lab 5, the saga steps of the coordinator) and the topic `events.session.ended`. It publishes nothing and calls no peer. See [Message Broker](#message-broker) |
| Health | `GET /health` (liveness), `GET /health/ready` (readiness: mongodb, pubsub, open connections, the broker connection's state) |
| Logs | `GET /logs?since=&until=&level=` with `X-Service-Token`: this copy's lines from its rotating log file, as ndjson. See [Logs download](#logs-download) |
| Metrics | `GET /metrics`, the Prometheus text format, no credential: requests, latency, `tasks_in_flight`, `websocket_connections`. See [Metrics](#metrics) |
| Status | `GET /status` on the REST port, polled by Service Discovery directly every 10 s: `{ service, instance_id, version, status, in_flight, max_concurrent_tasks, ws_connections }`, `503` with `status: degraded` when MongoDB does not answer. No credential, outside the task limit. See [Status endpoint](#status-endpoint) |
| Service Discovery | Every copy registers itself at startup with `PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/discord-dms-<hostname>` (`service_name: discord-dms`, `port: 8096`, `version`, `topics: { publishes: [], subscribes: [events.session.ended] }`), repeats it every 5 s as the heartbeat and `DELETE`s it on graceful shutdown. Directly, not through the Gateway. See [Service Discovery registration](#service-discovery-registration) |
| Logging | One JSON object per line on stdout and in `LOG_FILE`: `time`, `level`, `service: discord-dms`, `instance_id`, `version`, `event`, `msg`, plus the event's fields; `request_id` on every line of a request. See [Logging](#logging) |
| Circuit breaker | None needed: the service makes no outbound HTTP call (MongoDB and Redis only). The breakers of the contract live in the services that call others and in the Gateway |
| Database | MongoDB 7, `dms_db`. In the team stack the replica set `rs0` of `dms-mongo-1`, `dms-mongo-2`, `dms-mongo-3` (Lab 5), reached with the `replicaSet=rs0` URI; this repository's local compose runs one standalone `mongod` (host port `27019`). While no primary answers: `500 DEPENDENCY_UNAVAILABLE`. See [Database replication and failover](#database-replication-and-failover) |
| Fan-out | Redis Pub/Sub, `dms_pubsub` (own container, host port `6380`); optional, empty `REDIS_URL` = one instance only |
| Events | `session.ended` arrives on the broker stream from its topic, deduplicated on `event_id`, acked `OK` / `PERMANENT` / `RETRY`. `session.started` is retired (Lab 5): the saga step brings its data. `POST /api/v1/events` is gone |
| Saga | Participant of `shift.start` (coordinator: the Message Broker): step 3 `POST /api/v1/saga-steps/create-channels` and its `/compensate`, idempotent by `saga_id`; the demo failure switch `POST /api/v1/dev/saga-steps/fail-next`. See [Saga step create-channels](#saga-step-create-channels) |
| Produces | nothing |
| Receives | `session.ended`; the saga step requests |
| Calls | nothing. No peer, so no circuit breaker; the only outbound calls are the registration with Service Discovery and the broker stream, which is reopened with a backoff |
| Authentication | REST endpoints read the calling player from `X-Player-Id`, set by the Gateway after validating the player's JWT (through the broker from Lab 4). `/logs`, `/api/v1/admin/*` and `/api/v1/dev/*` are not Gateway routes any more (#110): they are called directly inside the network, and this service checks their `X-Service-Token` itself (`403 SERVICE_TOKEN_REQUIRED`, `401 INVALID_SERVICE_TOKEN`). The saga steps `/api/v1/saga-steps/*` are service calls through the broker, which strips the token: they refuse a request that carries `X-Player-Id` (`403 SERVICE_TOKEN_REQUIRED`) and the Gateway does not route them. The WebSocket, which bypasses the Gateway, takes a one-time ticket from `POST /api/v1/ws-tickets` |
| Task limits | `HTTP_REQUEST_TIMEOUT` (5 s) stops a task with `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (64) refuses the next one with `429 TOO_MANY_REQUESTS`; health endpoints exempt; a WebSocket upgrade is a task until the protocol switch, the open connection is not. See [Task timeout and concurrent task limit](#task-timeout-and-concurrent-task-limit) |
| Docker image | `dmracovit/discord-dms-service:5.0.0` and `:latest`, public on Docker Hub, linux/amd64 and linux/arm64; published by GitHub Actions on merge to `main` from the `VERSION` file (Lab 5 = `5.x.y`), with the tag `v<VERSION>` and its GitHub Release |

## Running it

Requirements: Docker with Compose v2. For development and tests: Go 1.25.

```bash
./scripts/run.sh            # build the image, start mongo + redis + service, wait until /health/ready answers
./scripts/run.sh --local    # run from source against the containerised mongo and redis
./scripts/run.sh --test     # unit tests with coverage
./scripts/run.sh --logs     # follow the logs
./scripts/run.sh --down     # stop (add --volumes to drop the data)
```

On the first run the script creates `.env` from `.env.example` with generated secrets. `.env` is
gitignored and must never be committed.

Without Docker: `MONGODB_URI=... go run ./cmd/dmsd`.

With `SEED_ON_START=true` (the default in compose) an empty database gets the demo session
`3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e` with its four channels and a short conversation. Its
Moderator and juniors are the same players as in Moderation Service's mock, so one demo works
across both services. Several instances starting together on an empty database seed it once: the
session and its channels are written by fixed ids (a second write changes nothing), the first
instance to store the demo messages is the one that seeded, and the others step aside without an
error.

### From the published image only

```bash
docker network create student-id-net   # once
docker run -d --name discord-dms-service --network student-id-net -p 8086:8086 \
  -e MONGODB_URI="mongodb://dms_user:<password>@<mongo-host>:27017/dms_db?authSource=admin" \
  -e REDIS_URL="redis://<redis-host>:6379/0" \
  -e WS_PUBLIC_URL="ws://localhost:8086" -e DEV_ENDPOINTS=true -e SEED_ON_START=true \
  dmracovit/discord-dms-service:latest
```

Against the replica set of the team stack (Lab 5), `MONGODB_URI` lists the three members:

```bash
-e MONGODB_URI="mongodb://dms_user:<password>@dms-mongo-1:27017,dms-mongo-2:27017,dms-mongo-3:27017/dms_db?authSource=admin&replicaSet=rs0&retryWrites=true"
```

`discord-DMs-service/deployments/docker-compose.team.yml` is the same stack without `build:`, the fragment merged into
the team-wide compose in the CPR. Both compose files of this repository keep one standalone `mongod`;
the three-member replica set lives in the CPR compose (#164, #170).

## Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `MONGODB_URI` | - | yes | MongoDB connection string. Team stack (Lab 5): `mongodb://<user>:<pw>@dms-mongo-1:27017,dms-mongo-2:27017,dms-mongo-3:27017/dms_db?authSource=admin&replicaSet=rs0&retryWrites=true`, so the driver finds the primary itself and follows an election (never one host). Local compose: `mongodb://<user>:<pw>@dms-mongo:27017/dms_db?authSource=admin`. `serverSelectionTimeoutMS` in the URI sets how long an operation waits for a primary (5 s when absent) |
| `MONGODB_DATABASE` | `dms_db` | no | Database name |
| `WS_PUBLIC_URL` | `ws://localhost:8086` | no | The address clients reach this service at **directly**: the base of the `ws_url` a ticket comes with. Not the Gateway |
| `WS_TICKET_TTL` | `30s` | no | How long a WebSocket ticket stays valid |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Task timeout: a request running longer is stopped and answers `408 REQUEST_TIMEOUT`. `5s` or `5`, like the other services. The Gateway allows 10 s, so the outer layer never gives up first |
| `MAX_CONCURRENT_TASKS` | `64` | no | Concurrent task limit: the request above it is refused at once with `429 TOO_MANY_REQUESTS` |
| `APP_PORT` | `8096` | no | Port of the REST API, never published: Service Discovery and Prometheus poll it, and `/logs`, `/admin` and `/dev` are called on it inside the network; the player routes reach it through the broker |
| `MESSAGE_BROKER_URL` | empty | with `SERVICE_TOKEN` | The broker's gRPC address, `message-broker-service:8071` in the team stack: the stream that brings the REST requests and the session events. Empty = no stream (local runs, tests), logged once as `broker.disabled` |
| `LOG_FILE` | `/var/log/discord-dms/discord-dms.jsonl` | no | The log file next to stdout, read by `GET /logs`. Set but empty = stdout only. Outside Docker, a writable path such as `./logs/discord-dms.jsonl` |
| `LOG_FILE_MAX_MB`, `LOG_FILE_KEEP` | `50`, `5` | no | The file rotates at this size; rotated files kept next to the current one |
| `WS_PORT` | `8086` | no | Port of the WebSocket listener: only `GET /api/v1/ws` and `GET /health` answer there. The one port published to clients; must differ from `APP_PORT` |
| `APP_ENV` | `local` | no | `local` / `test` / `development` = text logs; anything else (the image sets `docker`) = the JSON log lines of the contract, release mode |
| `INSTANCE_ID` | `discord-dms-<hostname>` | no | This copy's id (the hostname is the container id in Docker): its name in Service Discovery and on every log line. Set it when running several copies outside Docker |
| `SERVICE_DISCOVERY_URL` | empty | no | Service Discovery, e.g. `http://service-discovery-service:8090`. The copy registers its REST port there at startup and every 5 s; empty = not registered (local runs, tests), logged once as a warning |
| `SERVICE_TOKEN` | empty | with `SERVICE_DISCOVERY_URL` or `MESSAGE_BROKER_URL` | The stack's one `X-Service-Token`: sent to Service Discovery, the `x-service-token` metadata of the broker stream, and checked here on `/logs`, `/api/v1/admin/*` and `/api/v1/dev/*` |
| `INSTANCE_HOST` | empty | no | Sent as `host` at registration, for a copy running outside Docker; otherwise Service Discovery stores the source address of the registration |
| `SERVICE_DISCOVERY_HEARTBEAT`, `SERVICE_DISCOVERY_TIMEOUT` | `5s`, `2s` | no | How often the registration is repeated (the registry forgets an instance after 15 s), and the timeout of one call to Service Discovery |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `/api/v1/dev/*` (the slow route for the timeout demo, `POST /dev/events`, which applies an envelope as a broker delivery would, and `POST /dev/saga-steps/fail-next`, the failure switch of the saga step) and makes `create-channels` consult that switch. Keep `false` in shared deployments; the team stack sets it for the demo |
| `SEED_ON_START` | `false` | no | Seed the demo session when there are no sessions |
| `ENSURE_INDEXES_ON_START` | `true` | no | Create the indexes at startup (idempotent), the ticket TTL index included |
| `REDIS_URL` | empty | no | Redis for fan-out between instances; required when several copies run (the team stack). Empty = messages are delivered to this instance's connections only, logged as a warning at startup |
| `MAX_MESSAGE_LENGTH` | `2000` | no | Characters per message |
| `HISTORY_DEFAULT_LIMIT` | `50` | no | Page size of the history endpoint |
| `WS_PING_INTERVAL`, `WS_PONG_WAIT`, `WS_WRITE_WAIT` | `30s`, `60s`, `10s` | no | WebSocket keep-alive |
| `DB_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT`, `HTTP_WRITE_TIMEOUT`, `SHUTDOWN_TIMEOUT` | `30s`, `10s`, `0` (none, connections live for the whole shift), `10s` | no | Tuning; a non-zero `HTTP_WRITE_TIMEOUT` must stay above `HTTP_REQUEST_TIMEOUT` |

## HTTP and WebSocket API

Operational endpoints, at the root, without a credential and outside the task limit:

| Method | Path | Listener | Who calls it | Answer |
| --- | --- | --- | --- | --- |
| `GET` | `/health` | both | Docker, the orchestrator | `200 { "status": "ok", "service", "version", "time" }` |
| `GET` | `/health/ready` | REST | the orchestrator (the Gateway only forwards `/api/v1/discord-dms/health/ready` on request; it reads Service Discovery, not readiness) | `200` or `503` with `checks` (mongodb, pubsub, open connections) |
| `GET` | `/status` | REST | Service Discovery, every 10 s, directly | `200 { "service": "discord-dms", "instance_id", "version", "status": "up", "in_flight", "max_concurrent_tasks", "ws_connections" }`, `503` with `"status": "degraded"` when MongoDB does not answer |
| `GET` | `/metrics` | REST | Prometheus, directly | the Prometheus text format, see [Metrics](#metrics) |
| `GET` | `/logs?since=&until=&level=` | REST | Service Discovery's aggregate, a developer, directly | `X-Service-Token`; `200 application/x-ndjson`, see [Logs download](#logs-download) |

Contract endpoints (payloads in the contract section below). "Player" means the Gateway validated
the player's JWT and sent the request, with `X-Player-Id`, through the broker to this service; a request
without that header answers `401 UNAUTHENTICATED`. "Service" means a direct call inside the network with
`X-Service-Token`, which this service checks.

| Method | Path | Consumed by | Who may call |
| --- | --- | --- | --- |
| `POST` | `/api/v1/ws-tickets` | Client, through the Gateway | player. `{ "session_id" }` -> `201 { ws_url, expires_at }`, a one-time ticket valid `WS_TICKET_TTL` |
| `GET` | `/api/v1/ws?ticket=` | Client, **directly** on port `8086`, upgraded to a WebSocket | the ticket only; `401 INVALID_TICKET` if unknown, expired or already used |
| `GET` | `/api/v1/sessions/{session_id}/channels` | Client, through the Gateway | player |
| `GET` | `/api/v1/channels/{channel_id}/messages?limit=&offset=` | Client, through the Gateway | player |

Service calls of the saga `shift.start` (Lab 5), sent by the coordinator, the Message Broker, through
`requests.discord-dms` with no `X-Player-Id` and no token (see [Saga step create-channels](#saga-step-create-channels)).
The Gateway does not route them (`404`); a request that carries `X-Player-Id` answers `403 SERVICE_TOKEN_REQUIRED`.

| Method | Path | Answer |
| --- | --- | --- |
| `POST` | `/api/v1/saga-steps/create-channels` | `200 { saga_id, step: "create-channels", state: "done" }`; `400 VALIDATION_ERROR`; `409 SAGA_STEP_COMPENSATED`; `500 DEPENDENCY_UNAVAILABLE` (retried) |
| `POST` | `/api/v1/saga-steps/create-channels/compensate` | `200 { saga_id, step: "create-channels", state: "compensated" }`, also when the step never ran; `400 VALIDATION_ERROR`; `500 DEPENDENCY_UNAVAILABLE` (retried) |

Extensions beyond the contract (the CRUD surface of Lab 1 and the demo tooling):

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/api/v1/channels/{channel_id}/messages` | `{ "content": "..." }` sends a message without a WebSocket (player). It is delivered to the open connections like any other |
| `PATCH` | `/api/v1/channels/{channel_id}/messages/{message_id}` | `{ "content": "..." }` edits the caller's own message while the channel is not archived (player); the message gets `edited_at` and open connections receive `message.updated`. `403 NOT_MESSAGE_AUTHOR` for anyone else |
| `DELETE` | `/api/v1/admin/messages/{message_id}` | Removes a message (service) |
| `GET` | `/api/v1/dev/slow?ms=` | Answers after `ms` milliseconds (at most 60 000), to demonstrate `408` and `429` (`DEV_ENDPOINTS=true`, service) |
| `POST` | `/api/v1/dev/events` | Applies one envelope through the same handler as a broker delivery and answers the ack it would send: `200 { event_id, outcome: "OK", duplicate }`, `422 INVALID_EVENT` for `PERMANENT`, `503 EVENT_NOT_APPLIED` for `RETRY`. Still accepts a `session.started`, which no topic carries any more, for manual tests (`DEV_ENDPOINTS=true`, service) |
| `POST` | `/api/v1/dev/saga-steps/fail-next` | No body; `204`. The next `create-channels`, on whichever copy gets it, answers `500 INTERNAL_ERROR` once and changes nothing, so the saga compensates; each call arms one more failure. Called on a copy's REST port (`discord-dms-service:8096`) inside the network (`DEV_ENDPOINTS=true`, service) |

WebSocket protocol, JSON text frames both ways:

| Direction | Frame |
| --- | --- |
| client to server | `{ "type": "message.send", "channel_id": "...", "content": "..." }` |
| client to server | `{ "type": "ping" }` |
| server to client | `{ "type": "message.new", "message": { message_id, channel_id, author_id, content, sent_at } }` |
| server to client | `{ "type": "message.updated", "message": { ..., edited_at } }` |
| server to client | `{ "type": "error", "error": { "code": "CHANNEL_ACCESS_DENIED", "message": "..." } }`; while MongoDB has no primary the code is `DEPENDENCY_UNAVAILABLE`, with the generic message of the REST answer |
| server to client | `{ "type": "pong" }` |
| server to client | `{ "type": "session.ended", "session_id": "..." }`, followed by a normal close |

The server pings every `WS_PING_INTERVAL` and drops a connection that stays silent for `WS_PONG_WAIT`.

Error codes: `VALIDATION_ERROR` (400; also for an empty message or one longer than `MAX_MESSAGE_LENGTH`),
`UNAUTHENTICATED`, `INVALID_TICKET` (401), `NOT_IN_SESSION`, `CHANNEL_ACCESS_DENIED`, `NOT_MESSAGE_AUTHOR`
(403, the last one on the beyond-contract `PATCH` only), `SERVICE_TOKEN_REQUIRED` (403, `/logs`, `/admin`, `/dev`
without the token, a saga step with `X-Player-Id`), `INVALID_SERVICE_TOKEN` (401), `CHANNEL_NOT_FOUND`,
`MESSAGE_NOT_FOUND`, `NOT_FOUND` (404), `METHOD_NOT_ALLOWED` (405), `REQUEST_TIMEOUT` (408), `SESSION_NOT_ACTIVE`
(409; also when writing after the shift ended), `SAGA_STEP_COMPENSATED` (409), `INVALID_EVENT` (422),
`TOO_MANY_REQUESTS` (429), `INTERNAL_ERROR` (500, generic message), `DEPENDENCY_UNAVAILABLE` (500,
`details.dependency: "mongodb"`, while the database has no primary or cannot be reached). Shared envelope
`{ "error": { "code", "message", "details" } }`. A 500 never carries the driver's text; it is in the `http.error`
log line.

## Negotiating a connection

The chat is the one connection in the system that does not pass through the Gateway, so the Gateway
only negotiates it (Lab 2, grade 7):

1. The client calls `POST {gateway}/api/v1/discord-dms/ws-tickets` with its JWT and `{ "session_id" }`. The Gateway validates the player and forwards the request with `X-Player-Id`.
2. This service checks that the player is a member of an active session (`403 NOT_IN_SESSION`, `409 SESSION_NOT_ACTIVE`), stores a random 32-character ticket bound to the player and the session, and answers `201 { "ws_url": "ws://<WS_PUBLIC_URL>/api/v1/ws?ticket=...", "expires_at": "..." }`.
3. The client opens `ws_url` **directly** within `WS_TICKET_TTL` (30 s); it lands on the WebSocket listener (`WS_PORT`, `8086`), which serves nothing else. The ticket is consumed by the first upgrade that presents it: a second use, an unknown or an expired ticket is `401 INVALID_TICKET`, and a shift that ended in between is `409 SESSION_NOT_ACTIVE`. Nothing about the player is accepted on this route except the ticket.
4. From then on the connection carries the chat; the Gateway holds nothing. A client that reconnects asks for a new ticket and catches up through the REST history.

To try it by hand: run the Postman folder "WebSocket negotiation", which prints the `ws_url`, then
`wscat -c "<ws_url>"` (or any WebSocket client) and send
`{ "type": "message.send", "channel_id": "<general_channel_id>", "content": "hello" }`.

## Who sees which channel

Computed from the saga input (the payload `session.started` used to carry) when the channels are created:

| Channel | Who can see it |
| --- | --- |
| `general-mod-chat` | everyone in the session |
| `enrollment-check` | the Moderator and juniors with the `enrollment` scope |
| `course-registration` | the Moderator and juniors with the `courses` scope |
| `faculty-check` | the Moderator and juniors with the `email-groups` or `fcim-logs` scope |

## Message Broker

Lab 4 (CPR README "Message Broker", #105, #106, #107): the services no longer reach each other through
the Gateway. Every copy has one gRPC connection to `MESSAGE_BROKER_URL` (`internal/broker`, the generated
client of `internal/broker/brokerpb/broker.proto`, a copy of the CPR's `shared/broker.proto`), and every
call on it carries the metadata `x-service-token`.

- **One stream per copy.** `Subscribe(service: discord-dms, topics: [events.session.ended], max_concurrent_tasks: MAX_CONCURRENT_TASKS)`. The broker sends it the requests of `requests.discord-dms` (the Gateway's player routes: tickets, channels, history, messages; from Lab 5 also the saga steps of the coordinator, `caller: "message-broker"`) and a copy of every `session.ended`. `events.session.started` is retired (Lab 5, #163 decision 5).
- **Requests** are dispatched in-process to the REST engine, the same one the REST port serves, so the routes, `X-Player-Id`, the task limits, the access log and `in_flight` are the same. The answer goes back with `Reply`, status, headers and body unchanged. `request.received` / `request.replied` carry the `correlation_id`. `X-Service-Token` is never taken from the headers. The WebSocket upgrade lives on the public listener, which the broker never reaches: the chat path is unchanged by this lab.
- **Events** go through `events.Handler`, the Lab 3 dispatch: applied or a duplicate `event_id` is acked `OK`, an envelope that can never be applied (unparseable, unknown `event_type` or `version`, an invalid payload: the old `422 INVALID_EVENT`) `PERMANENT`, so the broker dead-letters it, and a MongoDB failure `RETRY`, so the broker sends it again. The envelope is the producer's byte for byte. The ack goes after the event is applied; a lost ack is redelivered by the broker and deduplicated here.
- **The broker down.** gRPC reconnects by itself. The stream is reopened with a backoff of 1 s doubling to 30 s, logging every failure as `broker.subscribe_failed`; `/health`, `/status`, `/logs`, `/metrics` and the WebSocket answer all along. This service only subscribes, so it needs the reconnect loop and no circuit breaker.
- **Shutdown.** The stream is closed first, so the broker routes nothing more to this copy; the requests already running finish and reply; then the REST and WebSocket listeners stop and every open connection gets its `1001`.
- **No broker** (`MESSAGE_BROKER_URL` empty): no stream, nothing reaches the REST API through it and no event arrives; `broker.disabled` is logged once. For a local run `POST /api/v1/dev/events` applies an envelope as a delivery would, and the saga steps can be called on the REST port directly (without `X-Player-Id`).

## Events

`session.ended` arrives on the broker stream (see above), from Server Moderation Session Service's relay,
which publishes it once to `events.session.ended`. `session.started` is retired in Lab 5 (#163 decision 5):
Session Service no longer publishes it, this service no longer subscribes to `events.session.started` nor lists
it in its registration, and the channels of a shift come from the saga step (next section).
`POST /api/v1/dev/events` still applies a `session.started` envelope, for manual tests.

- **Ack.** `OK` once the event is applied. A repeat of an `event_id` already applied is also `OK` and changes nothing: delivery is at-least-once, so a repeat is the deduplication working, not an error.
- **`PERMANENT`** when the envelope cannot be parsed, its `event_type` is not one this service consumes, its `version` is not `1`, or its payload fails validation (for example no `session_id`). The broker dead-letters such an event; a retry cannot succeed.
- **`RETRY`** for a failure that may succeed later (MongoDB down). The change is stored first and the `event_id` recorded last - a standalone MongoDB has no multi-document transaction - and applying an event is idempotent, so a failure or a crash in between makes the broker's redelivery apply it again instead of losing it, and a replay never duplicates channels.
- `session.started` (only through `POST /api/v1/dev/events` now): records the session and creates the four channels with their access lists. A replay never duplicates channels.
- `session.ended`: marks the session ended, archives the channels (read-only, history stays readable), pushes `session.ended` to every open connection of the session and closes them.

There is no ordering guarantee: if `session.ended` arrives before the channels were created (by the saga step,
or a `session.started` through `/dev/events`), the session is remembered as ended and the late step creates its
channels already archived.

## Saga step create-channels

Lab 5 (#163 decision 5, #168): starting a shift is the saga `shift.start`, coordinated by the Message Broker.
Its steps are `shift-begin` (Session), `grant-scopes` (University Record), **`create-channels` (this service)** and
`shift-confirm` (Session). A step is a `Request` through the broker to `requests.discord-dms` with
`caller: "message-broker"`, no `X-Player-Id` and no token (the consumer strips it), and a `timeout_ms` of 2000.
`2xx` is done; `408`, `429`, `503` and `500 DEPENDENCY_UNAVAILABLE` mean "nothing was changed" and are retried 3
times 2 s apart; anything else fails the step and the coordinator compensates the steps before it. A compensation
is retried until it succeeds.

**`POST /api/v1/saga-steps/create-channels`**

```json
{
  "saga_id": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
  "saga_type": "shift.start",
  "step": "create-channels",
  "payload": {
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
    "junior_moderators": [
      { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] }
    ],
    "ruleset_version": 7,
    "started_at": "2026-11-17T18:05:00Z"
  }
}
```

`payload` is exactly what `session.started` carried. `saga_id` must be a UUID, `payload.session_id` a UUID and
`payload.moderator_id` present; `saga_type` and `step` may be left out (the route names the step) but, when given,
must be `shift.start` and `create-channels`. Otherwise `400 VALIDATION_ERROR` with
`details.errors: [{ field, message }]`, which makes the coordinator compensate.

| Answer | When |
| --- | --- |
| `200 { "saga_id", "step": "create-channels", "state": "done" }` | the session and its four channels with their access lists were created, as `session.started` did, and the step is recorded; also for a repeat of a step already done, which changes nothing |
| `409 SAGA_STEP_COMPENSATED` | the step arrives after its own compensation (a late retry); nothing changes, `details: { saga_id, step }` |
| `500 INTERNAL_ERROR` | the failure switch was armed (`details.failure_switch: true`), or an unexpected error; nothing changed by the switch |
| `500 DEPENDENCY_UNAVAILABLE` | the database has no primary or cannot be reached (an election); the coordinator retries instead of compensating |
| `408 REQUEST_TIMEOUT` | the task ran out of time (the broker's 2 s); retried; a step that committed just before is answered `200` by the retry |

**`POST /api/v1/saga-steps/create-channels/compensate`**, same body (only `saga_id` is required): deletes the four
channels the saga created and the session document, then marks the step `compensated`, and answers
`200 { "saga_id", "step": "create-channels", "state": "compensated" }`. It succeeds also when the step never ran
(it writes a `compensated` tombstone, so the step arriving later answers `409`) and when it is repeated. The session
is the one in the step's record, else `payload.session_id`. Only what this saga created is deleted: the session and
channels written by a step carry its `saga_id`, so a late compensation of an older saga never deletes a newer one's
channels. If a channel already holds a message (impossible before the shift starts), the channels are archived and
the session ended instead, open connections get `session.ended`, and `saga.compensation_archived` is logged.

**Idempotency and atomicity.** The collection `saga_steps` holds one record per step,
`{ _id: "<saga_id>:create-channels", saga_id, saga_type, step, session_id, state: "done" | "compensated", created_at, updated_at }`.

- On a replica set (the team stack, `rs0`) the step's writes and its record are one multi-document transaction, and so
  are the compensation's deletes and its tombstone. Two copies running the same step at once conflict, one transaction
  starts again and finds the record. A transient error (a write conflict, an election) starts the transaction again
  while the task has time; the commit is bounded by the task timeout too.
- On a standalone `mongod` (this repository's compose, CI) there are no transactions, so the writes are ordered: the
  step's effect first and its record last (a failure in between is completed by the retry, every write being an
  idempotent upsert, or removed by the compensation, which finds the channels by session and saga); the
  compensation's tombstone first and its deletes after (the step can no longer run, and the retry deletes what is
  left). A step that finds the tombstone when it records itself removes what it wrote and answers `409`.
- The mode is found once at startup from `hello` (`setName`, or a `mongos`) and logged as `mongodb.mode`.

**Failure switch** (the demonstration of a compensated saga, #168, #170): `POST /api/v1/dev/saga-steps/fail-next`
with `X-Service-Token`, on a copy's REST port inside the network (`discord-dms-service:8096`), only with
`DEV_ENDPOINTS=true`, answers `204` and increments a counter in MongoDB (`dev_switches`, `_id: "saga-fail-next"`).
At the start of `create-channels` (after validation) a `findOneAndUpdate({ _id: "saga-fail-next", n: { $gt: 0 } },
{ $inc: { n: -1 } })` takes it atomically: the step answers `500 INTERNAL_ERROR` once with no change, on whichever
copy gets it, and the saga compensates `grant-scopes` and `shift-begin`. Without `DEV_ENDPOINTS` the route does not
exist and the step never reads the counter.

**Postman.** Folder 9 of `postman/discord-dms-service.postman_collection.json` (the same file as the CPR's) runs the
step, its repeat, the channels it created (through the Gateway), the refusals (`403` with `X-Player-Id`, `400` without
a payload), the compensation, the late step (`409 SAGA_STEP_COMPENSATED`), a compensation of a step that never ran,
the failure switch (`403` without the token, `204`, then one `500` and the next step `200`) and the Gateway's `404`.
It calls one instance directly at `service_url`, inside `student-id-net`, as the broker's request would arrive.

## Database replication and failover

Lab 5 (#163 decision 3, #164): in the team stack the database is the MongoDB replica set `rs0` of `dms-mongo-1`,
`dms-mongo-2` and `dms-mongo-3`, created by the CPR's pattern (`deployments/mongo-rs/`), which also creates the
ETL's `etl_reader` user with `read` on `dms_db` only. `dms-redis` stays one Pub/Sub node: it holds nothing.

- **Connection.** `MONGODB_URI=mongodb://<user>:<pw>@dms-mongo-1:27017,dms-mongo-2:27017,dms-mongo-3:27017/dms_db?authSource=admin&replicaSet=rs0&retryWrites=true`.
  The driver (mongo-driver 1.17) discovers the members, sends writes to the primary and follows an election by
  itself; retryable writes (the default, written out) retry a write once on the new primary. No code change was
  needed for the replica set itself.
- **During an election** an operation waits for a primary up to the server selection timeout (5 s, or
  `serverSelectionTimeoutMS` in the URI), bounded by the task timeout. A request that cannot be served answers
  `500 DEPENDENCY_UNAVAILABLE` with `details.dependency: "mongodb"` and a generic message (REST, the WebSocket error
  frame), or `408 REQUEST_TIMEOUT` when its task ran out first; an event is acked `RETRY`. What counts as unavailable
  (`internal/dberr`): a server selection error, the not-primary codes (`NotWritablePrimary`,
  `NotPrimaryNoSecondaryOk`, `NotPrimaryOrSecondary`, `LegacyNotPrimary`), `PrimarySteppedDown`,
  `InterruptedDueToReplStateChange`, `InterruptedAtShutdown`, `ShutdownInProgress`, network and connection errors,
  timeouts, and the `RetryableWriteError` / `NetworkError` / `TransientTransactionError` /
  `UnknownTransactionCommitResult` labels. Not `INTERNAL_ERROR`: the broker's breakers count every `5xx` except
  `DEPENDENCY_UNAVAILABLE`, so an election does not shut the copies out after the database is back.
- **Health.** `GET /status` answers `503 degraded` and `/health/ready` is not ready while the ping finds no primary;
  Service Discovery may list both copies down for 20 to 40 s around a failover, and the broker still routes to them.
- **After the election** the next operation goes to the new primary, without a restart; the old primary rejoins as a
  secondary.
- **ETL (#165).** The ETL reads `channels` and `messages` incrementally from a secondary as `etl_reader`. Every id is a
  UUID string (no `ObjectId` time), so the watermarks are `channels.created_at` and `messages.sent_at`, indexed by
  `{ created_at: 1 }` and `{ sent_at: 1 }`. Both are set by the service with one-second precision; messages can be
  edited (`edited_at`) and deleted by an admin, which an incremental read on `sent_at` does not see. The same goes
  for a compensation of `create-channels`: it deletes the saga's channels (they hold no message, the shift never
  started), and a channel the ETL had already copied stays in the warehouse.
- **This repository's compose files stay one standalone `mongod`**: a local run and CI need no replica set, and the
  saga steps then use ordered writes (see above).

## Task timeout and concurrent task limit

Every inbound HTTP request under `/api/v1` is one task, as the CPR contract defines it - the saga steps
and the WebSocket upgrade included. `GET /health`, `GET /health/ready` and `GET /status` are not, so a
busy service is neither restarted by its orchestrator nor marked unhealthy by Service Discovery: a copy
at full load reports its load instead.

The upgrade request is a task until the protocol switch: the ticket check and the `101 Switching
Protocols` run under the timeout, and an upgrade above the limit is refused with `429` like any
request (the ticket stays usable). Once the protocol switched there is no HTTP request any more, only a
connection that lives for the whole shift: it holds no task slot and no timeout applies to it. Open
connections are reported by `/health/ready`.

- **Timeout.** The request's context expires after `HTTP_REQUEST_TIMEOUT` (5 s). Every MongoDB operation runs under that context, so the task is cancelled where it is and the answer is `408 REQUEST_TIMEOUT` with `details.timeout_ms`. Nothing was changed. The Gateway's own timeout is 10 s, so the outer layer never gives up first.
- **Concurrent limit.** At most `MAX_CONCURRENT_TASKS` (64) requests are in progress; the next one is refused before any work with `429 TOO_MANY_REQUESTS`, `Retry-After: 1` and `details.limit`. Nothing was changed.
- **Demonstration.** With `DEV_ENDPOINTS=true`, `GET /api/v1/dev/slow?ms=7000` answers `408` after 5 s, and 64 parallel `GET /api/v1/dev/slow?ms=3000` make the 65th request answer `429`. The Postman collection's last folder does exactly this.

## Status endpoint

`GET /status` on the REST port is what Service Discovery polls every 10 s, directly (not through the
Gateway), as the CPR "Status endpoint" rules define it:

```json
{ "service": "discord-dms", "instance_id": "discord-dms-3f4e2a9b1c7d", "version": "3.0.0", "status": "up", "in_flight": 2, "max_concurrent_tasks": 64, "ws_connections": 17 }
```

`in_flight` is the number of requests holding a task slot at that moment (a WebSocket upgrade until
its protocol switch) and `max_concurrent_tasks` the limit, so the load is `in_flight /
max_concurrent_tasks`; at 80 % Service Discovery raises a critical-load alert. `ws_connections` is
this service's extra field, agreed by the team: the WebSocket connections open on this copy, which
are not tasks and do not count towards the load. When MongoDB does not answer a 2 s ping the answer
is `503` with `"status": "degraded"` and the same fields; three such answers in a row mark the copy
`down` in the registry. The endpoint takes no credential and is exempt from the concurrent task
limit. Its access log line is `debug`. The public WebSocket listener does not serve it.

## Logging

Every line is one JSON object on stdout (`APP_ENV` other than `local` / `test` / `development`; the
image sets `docker`), snake_case, with the level from `LOG_LEVEL`. Every line carries `time` (ISO 8601
UTC with milliseconds), `level` (`debug` / `info` / `warn` / `error`), `service` (`discord-dms`),
`instance_id`, `version`, `event` (a stable name) and `msg`; a line written while handling a request
also carries its `request_id`, and `duration_ms` is always an integer. The events, as the CPR
"Logging" rules name them:

| Event | When | Fields |
| --- | --- | --- |
| `http.request` | every request, the ones from the broker included, after the answer (`debug` for `/health*`, `/status`, `/metrics` and `/logs`); for the WebSocket upgrade when the connection closes, with the connection's duration | `request_id`, `method`, `path`, `status`, `duration_ms`, `client_ip`, `player_id` when known |
| `http.error` | every `4xx` (`warn`) or `5xx` (`error`) answer; a panic adds its `stack` | `request_id`, `method`, `path`, `status`, `code`, `error` |
| `event.received` | an event from the broker was applied, or found already applied (`duplicate: true`) | `request_id`, `event_id`, `event_type`, `producer`, `duplicate` |
| `event.rejected` / `event.failed` | the event is refused for good (`PERMANENT`, `warn`) or could not be applied now (`RETRY`, `error`) | the same, plus `reason` or `error` |
| `broker.received` / `broker.acked` | a delivery arrived from the broker / its ack was sent (`warn` for `RETRY`, `PERMANENT` or an ack that did not reach the broker) | `message_id`, `queue`, `event_id`, `event_type`, `producer`, `attempt`, `outcome`, `reason` |
| `broker.subscribed` / `broker.subscribe_failed` / `broker.disabled` | the stream opened, failed (`warn`, with `attempt`, `error`, `retry_in`), or there is no broker (`warn`) | `topics`, `max_concurrent_tasks` |
| `request.received` / `request.replied` | a request from the broker was dispatched / answered (`warn` when the reply did not reach the broker) | `correlation_id`, `message_id`, `method`, `path`, `caller`, `attempt` / `status`, `duration_ms`, `request_id` |
| `logs.file_unavailable` | `LOG_FILE` cannot be opened at startup: stdout only (`warn`) | `path`, `error` |
| `ws.connected` / `ws.disconnected` / `ws.upgrade_failed` / `ws.message_dropped` | a player's connection opened or closed (with `duration_ms`), the upgrade failed, a slow client lost a frame | `player_id`, `session_id`, `connections` |
| `sd.registered` / `sd.heartbeat_failed` / `sd.deregistered` | the registration with Service Discovery succeeded for the first time (once per process), a `PUT` failed (`warn`, one line per failed heartbeat), or the instance was removed at shutdown | `instance_id`, `service_name`, `port`, `error` |
| `startup` / `listening` / `fanout` / `shutdown` | the process starts (with its configuration, secrets left out), listens, chooses its fan-out, stops | the configuration values |
| `session.started`, `session.ended`, `message.sent`, `message.edited`, `message.deleted`, `seed.applied`, `bus.publish_failed` | the business actions and the one failure that matters for live delivery | the ids involved |
| `saga.step_done` / `saga.step_refused` / `saga.step_compensated` | `create-channels` done (`repeat: true` for a repeat), refused with `409` after its compensation (`warn`), compensated | `saga_id`, `step`, `session_id`, `transactional`, `members`; `previous_state`, `step_ran`, `channels_deleted`, `session_deleted`, `archived` |
| `saga.compensation_archived` / `saga.fail_switch` / `saga.fail_switch_armed` | a compensation found messages and archived instead of deleting (`warn`); the failure switch failed a step (`warn`); the switch was armed | `saga_id`, `session_id`, `channels`, `messages`; `armed` |
| `mongodb.mode` | once at startup: transactions (a replica set) or ordered writes (a standalone server) | `transactions`, `replica_set` |
| `ws.send_failed` | a WebSocket message could not be stored (`error`; the client gets an error frame with the generic message) | `player_id`, `session_id`, `code`, `error` |
| `event.duplicate`, `seed.skipped`, `sd.disabled` | an event was already applied (`debug`, the request still answers as the contract says and `event.received` carries `duplicate: true`); the demo data was already there (`debug`); registration is off because `SERVICE_DISCOVERY_URL` is empty (`warn`) | `event_id`, `instance_id` |

Never logged: `MONGODB_URI` and `REDIS_URL` (they carry credentials), `SERVICE_TOKEN`, tickets, message
contents, request or response bodies. One line:

```json
{"time":"2026-10-27T12:00:00.123Z","level":"info","service":"discord-dms","instance_id":"discord-dms-3f4e2a9b1c7d","version":"3.0.0","event":"http.request","msg":"request","method":"POST","path":"/api/v1/channels/1b2c.../messages","status":201,"duration_ms":4,"client_ip":"172.18.0.9","player_id":"8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11","request_id":"9d2d6c1e-0f3a-4b7c-8e1d-5a6b7c8d9e0f"}
```

`X-Request-ID` is read from the request (or generated), echoed in the answer and printed on every
line of the request; a request from the broker brings the Gateway's. The service makes no outbound call
that could forward it, except the registration with Service Discovery, which carries its own.

## Logs download

Lab 4 (#112, CPR README "Logs download"). Every line also goes, unchanged, to `LOG_FILE`
(`/var/log/discord-dms/discord-dms.jsonl` in the image, a directory the non-root user owns). The file
rotates at `LOG_FILE_MAX_MB` (50) and keeps `LOG_FILE_KEEP` (5) rotated files, `.1` the newest. The code
is `internal/logfile`, the same as Moderation Service's.

`GET /logs?since=<RFC 3339>&until=<RFC 3339>&level=<debug|info|warn|error>` with `X-Service-Token`, on the
REST port, streams this copy's lines across the rotated files and the current one, oldest first, as
`application/x-ndjson` with `Content-Disposition: attachment; filename="<instance_id>-<since>.jsonl"`.

- The window is `since <= time < until`, both optional, a time with its zone; `level` keeps that level
  and above. Anything else is `400 VALIDATION_ERROR` naming the field.
- The files are opened under the writer's lock, and the current one is read up to its size at that
  moment. A rotation or a line written while the answer streams never gives a broken line, and a line that
  is not one whole JSON object is never served.
- Outside the task limits; its access line is at `debug`. Without a file (`LOG_FILE=` or a path that
  cannot be opened, logged as `logs.file_unavailable`) the answer is `503 LOGS_UNAVAILABLE`.
- Service Discovery's `GET /api/v1/logs` fetches it from every copy into one zip. Never in the file: tickets,
  message contents, the token (the WebSocket listener logs no query string).

## Metrics

`GET /metrics` (`internal/metrics`), the Prometheus text format, no credential, outside the task limits, on
the REST port, scraped by Prometheus through Service Discovery's `http_sd` (#113):

| Series | What |
| --- | --- |
| `http_requests_total{method,route,status}` | every REST request, the broker's included; `route` is the template (`/api/v1/channels/:channel_id/messages`), `unmatched` for an unknown path, a non-standard method is `OTHER` |
| `http_request_duration_seconds{method,route}` | histogram of the same |
| `tasks_in_flight` | the `in_flight` of `GET /status` |
| `websocket_connections` | the open chat connections of this copy, the `ws_connections` of `GET /status` |

No `breaker_state` (no peer) and no `outbox_*` (no outbox): this service produces no event and calls no service.

## Service Discovery registration

With `SERVICE_DISCOVERY_URL` set, every copy registers itself the way the CPR "Service Discovery"
section defines it, directly against Service Discovery (not through the Gateway), with the stack's
`X-Service-Token` (`SERVICE_TOKEN`):

- `PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}` with `{ "service_name": "discord-dms", "port": <APP_PORT>, "version": "<VERSION>", "topics": { "publishes": [], "subscribes": ["events.session.ended"] } }` (plus `"host"` when `INSTANCE_HOST` is set; `topics` on every heartbeat too, so a record Service Discovery recreated has it again), sent right after both listeners are up and then every 5 s as the heartbeat (`SERVICE_DISCOVERY_HEARTBEAT`); the registry forgets an instance without heartbeats for 15 s. The REST port is registered, the one Service Discovery and Prometheus poll; the WebSocket port is reached through the proxy, not through the registry.
- `instance_id` = `discord-dms-<hostname>`, in Docker the container id prefix; a restarted container keeps it.
- `DELETE {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}` on graceful shutdown; a `404` counts as removed.
- A failure never affects request handling: every failed `PUT` is logged (`sd.heartbeat_failed`, `warn`) and the heartbeat retries on the next tick; `sd.registered` is logged on the first success only, a later successful heartbeat is silent. Every call has a 2 s timeout.
- An empty `SERVICE_DISCOVERY_URL` disables registration with one warning (`sd.disabled`): the development stack and the tests run without a registry.

## Several instances

The service runs as several identical copies (Lab 3), each with its own stream to the broker, which shares
`requests.discord-dms` between them and gives each its copy of every event (Lab 4): nothing an answer
depends on lives in a process, and the concurrent task limit is per copy by design. What copies starting and
running together need is handled here:

- **One chat port.** Players connect to `ws://localhost:8086`, as the contract says. In the team stack that port belongs to `dms-ws-proxy` (nginx, `deployments/dms-ws-proxy/nginx.conf` of this CPR, a copy of the submodule's), which forwards each connection to whichever copy Docker's DNS returns and re-resolves the name every 5 s, so a copy added with `docker compose up -d --scale discord-dms-service=3` joins the rotation and a stopped one leaves it. The copies publish no port; `WS_PUBLIC_URL` stays `ws://localhost:8086`. A connection lives for the whole shift, so the proxy never cuts an idle one (`proxy_read_timeout 1h`).
- **Fan-out.** Every stored message, every edit and every `session.ended` is published on the bus (`dms:events` in Redis) and delivered from the subscription, so players connected to different copies see the same messages; `REDIS_URL` is required with several copies. With one copy and no Redis the bus is in-process and behaves the same.
- **Tickets.** A ticket issued by one copy (through the Gateway) is redeemed on whichever copy the proxy picks: tickets live in MongoDB and the first upgrade that presents one removes it atomically (`FindOneAndDelete`), so a second use anywhere is `401 INVALID_TICKET`.
- **Events.** The broker gives every copy its own delivery of `session.ended` (each copy must close its own connections), and it is applied once: the `event_id` is recorded in MongoDB and applying is idempotent, so the second copy acks a duplicate.
- **Saga steps.** A step or its retry may land on either copy: the record in `saga_steps` (in the same transaction as the step on the replica set) makes the second run answer `200` without redoing it, and the failure switch is a counter in MongoDB taken atomically, so it fails exactly one step whichever copy runs it.
- **Seed** (`SEED_ON_START`) runs once: the demo session and its channels are written by fixed ids, and a copy that finds the demo messages already stored steps aside without an error.
- **Indexes** are created at every start, idempotently.
- **Instance id**: `discord-dms-<hostname>` (in Docker the container id), the copy's name in Service Discovery and on every log line. Each copy registers itself and answers its own `GET /status`, with its own `ws_connections`.
- **Shutdown.** A copy that stops (SIGTERM) closes its broker stream first, so no request is routed to it while its players are told to go, then stops accepting requests and upgrades, deregisters itself from Service Discovery and sends every open connection a close frame `1001 Going Away` ("server shutting down"); the client reconnects through the proxy to another copy with a new ticket.

## Storage

MongoDB `dms_db`: `sessions` (members and scopes), `channels` (unique per session and name, with
`visible_to`; indexed by `created_at` for the ETL), `messages` (indexed by channel and time, newest first, by
session, and by `sent_at` for the ETL), `consumed_events` (dedup), `ws_tickets` (one-time tickets, removed on use
and by a TTL index when they expire), `saga_steps` (the record of each saga step, see
[Saga step create-channels](#saga-step-create-channels)) and `dev_switches` (the failure switch). A session or a
channel written by a saga step carries that step's `saga_id`. Indexes and `saga_steps` are created at startup
(`ENSURE_INDEXES_ON_START`), idempotently.

**Replica set (Lab 5, #164, #178).** `dms_db` lives on the replica set `rs0` of `dms-mongo-1`, `dms-mongo-2` and
`dms-mongo-3`, initiated once by `dms-mongo-init` (see [Database replication and failover](#database-replication-and-failover)).
The compose block of the service sets `dns_opt: ["timeout:1", "attempts:1"]`, so the lookup of a stopped member fails
at once instead of after the 5 to 16 s of Docker Desktop for Windows, and the members get `stop_grace_period: 30s`,
longer than mongod's 15 s quiesce on `SIGTERM`. Measured on the team stack (#193): a new primary 2 s after
`docker stop` of the old one, the Postman collection green before, after the election and after the old primary
rejoined as a secondary.

## Docker image, versioning and CI

The image tag is the single line of the `VERSION` file; its MAJOR is the laboratory number, so every
Lab 5 release is `5.x.y` (`5.0.0` now). Images are never pushed by hand:

- `discord-DMs-service/.github/workflows/ci.yml`: on every pull request into `dev` or `main`, and on every push to a work branch, checks that the checked-in gRPC stubs match `broker.proto` (`scripts/gen-proto.sh`), runs `go vet` and the tests against MongoDB and Redis services and builds the image without pushing it.
- `discord-DMs-service/.github/workflows/release.yml`: on every push to `main` (a merge of `dev`), runs the tests and, only if they pass, builds `linux/amd64` and `linux/arm64` and pushes `dmracovit/discord-dms-service:<VERSION>` and `:latest`, then tags the commit `v<VERSION>` and creates its GitHub Release from the CHANGELOG section of that version. It stops when `VERSION` is not `MAJOR.MINOR.PATCH` or its MAJOR is not the workflow's `LAB_MAJOR` (`5`).
- `discord-DMs-service/scripts/gen-proto.sh` regenerates `internal/broker/brokerpb` after a change of the CPR's `shared/broker.proto` (copy it to `internal/broker/brokerpb/broker.proto` first). The image needs no `protoc`.

Repository secrets required, never committed: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker
Hub access token with write access). Release flow: bump `VERSION` and the CHANGELOG in a PR into
`dev`, then merge `dev` into `main`.

## Tests

```bash
go test ./... -cover
TEST_MONGODB_URI=mongodb://dms_user:<pw>@localhost:27019/?authSource=admin go test ./internal/store/
TEST_REDIS_URL=redis://localhost:6380/0 go test ./internal/pubsub/
# the saga step against a single-node replica set (transactions); TEST_MONGODB_URI covers the standalone mode
docker run --rm -d --name dms-test-mongo -p 57017:27017 mongo:7 --replSet rs0
docker exec dms-test-mongo mongosh --quiet --eval 'rs.initiate()'
TEST_MONGODB_RS_URI='mongodb://localhost:57017/?replicaSet=rs0&directConnection=true' go test ./internal/store/
docker stop dms-test-mongo
```

Domain, chat, WebSocket and HTTP layers are unit-tested with an in-memory repository and a real
WebSocket client, the ticket negotiation, the broker event handler and its acks, the status endpoint and the
log format included; the broker stream (requests dispatched and replied, events acked, the reconnect,
shutdown with a request running) against an in-process gRPC broker; the log file and `GET /logs`; the
Service Discovery client against a fake registry; the saga step and its compensation (repeats, the late step, the
tombstone, the race with the compensation, the failure switch, the database unavailable) with the in-memory
repository and over HTTP; the classifier of database errors (`internal/dberr`) against the driver's error types.
The store, saga and Redis tests run against real containers when the variables are set and are skipped otherwise:
the saga test runs the whole scenario, concurrent deliveries and a step racing its compensation included, on a
standalone server (`TEST_MONGODB_URI`, CI) and on a replica set (`TEST_MONGODB_RS_URI`).

## Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | `POST /channels/{id}/messages`, `PATCH /channels/{id}/messages/{message_id}` (the Lab 1 CRUD requirement), `/admin/*` and `/dev/*` exist beyond the contract; nothing in the contract depends on them | nobody: from Lab 4 `/admin/*` and `/dev/*` are called directly with the service token, which this service checks |
| 3 | Requests through the broker (`Request`, `Reply`) need #107 in the broker. Until it ships nothing reaches the player routes through the broker; the events already flow | the Gateway's player routes to this service (#110) |
| 2 | The WebSocket protocol adds frames the contract does not list, all optional for a client: `ping` / `pong`, `message.updated` (after the beyond-contract `PATCH`) and a `session.ended` frame right before the close the contract requires | the game client may ignore them |
| 4 | Saga steps (Lab 5): a request that carries `X-Player-Id` answers `403 SERVICE_TOKEN_REQUIRED` (the Gateway answers `404` before that); `saga_type` and `step` may be left out of the body, a wrong value is `400`; a compensation needs only `saga_id`. Under a step that runs out of the broker's 2 s the answer is `408`, also retried | the saga coordinator (#168) |
| 5 | A compensation that finds messages in the saga's channels archives them and ends the session instead of deleting (cannot happen before the shift starts) | nobody in a correct saga |

Port `8086` is published because the contract says so (the direct WebSocket). Since `2.1.0` it is the WebSocket listener only (`WS_PORT`): the REST routes, which trust `X-Player-Id` like every service, live on `APP_PORT` (`8096`) inside the network and are reached only through the Gateway, so nothing that reads a header is reachable directly. Since `3.0.0` the published `8086` belongs to the `dms-ws-proxy` in front of the copies (see [Several instances](#several-instances)); `GET /status` carries the extra field `ws_connections`, agreed by the team.

---

*Discord DMs Service is owned by Racovita Dumitru. See the service's own repository README for the full contract copy and the CHANGELOG.*
