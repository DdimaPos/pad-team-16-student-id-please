# Discord DMs Service - Integration Reference

Integration reference of the **Discord DMs Service**, one of the eight microservices of the FAF Discord
Moderation game **"Student ID, please"**. This service provides the real-time communication between
the Moderator and the Junior Moderators of a session: it creates the four moderator channels when a
shift starts, moves messages over WebSockets, keeps the history and archives the channels when the
shift ends. It never checks whether what players write is true.

Owner: Racovita Dumitru. Source: the private `discord-DMs-service` repository, linked as a submodule of this CPR.

> **Audience:** developers of the other services of *"Student ID, please"* (Team 16, FAF.PAD21.1), or the gateway.
> Copied from the service's own README at `v0.1.0`; relative paths below refer to the `discord-DMs-service/` submodule.
> Where the implementation diverges from the CPR contract, the divergence is called out in the last section.

## Integration card

| | |
| --- | --- |
| Language / framework | Go 1.25, Gin, gorilla/websocket |
| Container port | `8086` (host `8086`) |
| Base path | `/api/v1` |
| Health | `GET /health` (liveness), `GET /health/ready` (readiness: mongodb, pubsub, rabbitmq, open connections) |
| Database | MongoDB 7, `dms_db` (own container, host port `27019`) |
| Fan-out | Redis Pub/Sub, `dms_pubsub` (own container, host port `6380`); optional, empty `REDIS_URL` = one instance only |
| Broker | RabbitMQ, exchange `student-id.events`, queue `discord-dms-service.session-events`; optional |
| Publishes | nothing |
| Consumes | `session.started`, `session.ended` |
| Calls | nothing. Zero outbound HTTP dependencies |
| Authentication | `Authorization: Bearer <jwt>` or `?access_token=` for players (signature not verified, `sub` is the player id); `X-Service-Token` for `/admin/*` and `/dev/*` |
| Docker image | `dmracovit/discord-dms-service:0.1.0` |

## Running it

Requirements: Docker with Compose v2. For development and tests: Go 1.25.

```bash
./scripts/run.sh            # build the image, start mongo + redis + service, wait until /health/ready answers
./scripts/run.sh --broker   # same, plus a local RabbitMQ (only when the team broker is not running)
./scripts/run.sh --local    # run from source against the containerised mongo and redis
./scripts/run.sh --test     # unit tests with coverage
./scripts/run.sh --logs     # follow the logs
./scripts/run.sh --down     # stop (add --volumes to drop the data)
```

On the first run the script creates `.env` from `.env.example` with generated secrets. `.env` is
gitignored and must never be committed.

Without Docker: `MONGODB_URI=... SERVICE_TOKEN=... go run ./cmd/dmsd`.

With `SEED_ON_START=true` (the default in compose) an empty database gets the demo session
`3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e` with its four channels and a short conversation. Its
Moderator and juniors are the same players as in Moderation Service's mock, so one demo works
across both services.

### From the published image only

```bash
docker network create student-id-net   # once
docker run -d --name discord-dms-service --network student-id-net -p 8086:8086 \
  -e MONGODB_URI="mongodb://dms_user:<password>@<mongo-host>:27017/dms_db?authSource=admin" \
  -e REDIS_URL="redis://<redis-host>:6379/0" \
  -e SERVICE_TOKEN="<shared-secret>" -e DEV_ENDPOINTS=true -e SEED_ON_START=true \
  dmracovit/discord-dms-service:0.1.0
```

`discord-DMs-service/deployments/docker-compose.team.yml` is the same stack without `build:`, the fragment merged into
the team-wide compose in the CPR.

## Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `MONGODB_URI` | - | yes | MongoDB connection string |
| `SERVICE_TOKEN` | - | yes | Shared secret required as `X-Service-Token` on `/api/v1/admin/*` and `/api/v1/dev/*` |
| `MONGODB_DATABASE` | `dms_db` | no | Database name |
| `APP_PORT` | `8086` | no | HTTP port |
| `APP_ENV` | `local` | no | `local` / `test` / `development` = text logs; anything else = JSON logs, release mode |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `/api/v1/dev/*` (token mint, event replay). Keep `false` in shared deployments |
| `SEED_ON_START` | `false` | no | Seed the demo session when there are no sessions |
| `ENSURE_INDEXES_ON_START` | `true` | no | Create the indexes at startup (idempotent) |
| `REDIS_URL` | empty | no | Redis for fan-out between instances. Empty = messages are delivered to this instance's connections only |
| `RABBITMQ_URL` | empty | no | Empty disables the consumer; replay events through the dev endpoints instead |
| `RABBITMQ_EXCHANGE`, `RABBITMQ_QUEUE`, `RABBITMQ_DLX`, `RABBITMQ_DLQ`, `RABBITMQ_PREFETCH` | `student-id.events`, `discord-dms-service.session-events`, `student-id.dlx`, `discord-dms-service.dlq`, `10` | no | Broker wiring |
| `MAX_MESSAGE_LENGTH` | `2000` | no | Characters per message |
| `HISTORY_DEFAULT_LIMIT` | `50` | no | Page size of the history endpoint |
| `WS_PING_INTERVAL`, `WS_PONG_WAIT`, `WS_WRITE_WAIT` | `30s`, `60s`, `10s` | no | WebSocket keep-alive |
| `DB_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT`, `SHUTDOWN_TIMEOUT` | `30s`, `10s`, `10s` | no | Tuning |

## HTTP and WebSocket API

Contract endpoints (payloads in the contract section below):

| Method | Path | Consumed by | Auth |
| --- | --- | --- | --- |
| `GET` | `/api/v1/ws?session_id=` | Client, upgraded to a WebSocket | player JWT (header or `access_token` query) |
| `GET` | `/api/v1/sessions/{session_id}/channels` | Client | player JWT |
| `GET` | `/api/v1/channels/{channel_id}/messages?limit=&offset=` | Client | player JWT |

Extensions beyond the contract (the CRUD surface of Lab 1):

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/api/v1/channels/{channel_id}/messages` | `{ "content": "..." }` sends a message without a WebSocket. It is delivered to the open connections like any other |
| `DELETE` | `/api/v1/admin/messages/{message_id}` | Removes a message. Service token only |
| `GET` | `/api/v1/dev/tokens?player_id=` | Mints an unsigned player JWT for Postman (`DEV_ENDPOINTS=true`) |
| `POST` | `/api/v1/dev/events/session-started`, `/session-ended` | Accept a full event envelope and run it through the exact same code path as the RabbitMQ consumer, so the whole flow is demoable with no broker |

WebSocket protocol, JSON text frames both ways:

| Direction | Frame |
| --- | --- |
| client to server | `{ "type": "message.send", "channel_id": "...", "content": "..." }` |
| client to server | `{ "type": "ping" }` |
| server to client | `{ "type": "message.new", "message": { message_id, channel_id, author_id, content, sent_at } }` |
| server to client | `{ "type": "error", "error": { "code": "CHANNEL_ACCESS_DENIED", "message": "..." } }` |
| server to client | `{ "type": "pong" }` |
| server to client | `{ "type": "session.ended", "session_id": "..." }`, followed by a normal close |

The server pings every `WS_PING_INTERVAL` and drops a connection that stays silent for `WS_PONG_WAIT`.

Error codes: `VALIDATION_ERROR` (400), `UNAUTHENTICATED`, `INVALID_SERVICE_TOKEN` (401),
`NOT_IN_SESSION`, `CHANNEL_ACCESS_DENIED`, `SERVICE_TOKEN_REQUIRED` (403), `CHANNEL_NOT_FOUND`,
`MESSAGE_NOT_FOUND`, `NOT_FOUND` (404), `SESSION_NOT_ACTIVE`, `CHANNEL_ARCHIVED` (409),
`INVALID_CONTENT`, `INVALID_EVENT` (422), `INTERNAL_ERROR` (500). Shared envelope
`{ "error": { "code", "message", "details" } }`.

## Who sees which channel

Computed from `session.started` when the channels are created:

| Channel | Who can see it |
| --- | --- |
| `general-mod-chat` | everyone in the session |
| `enrollment-check` | the Moderator and juniors with the `enrollment` scope |
| `course-registration` | the Moderator and juniors with the `courses` scope |
| `faculty-check` | the Moderator and juniors with the `email-groups` or `fcim-logs` scope |

## Events

Consumed from the shared topic exchange, at-least-once, deduplicated on `event_id`:

- `session.started`: records the session and creates the four channels with their access lists. A replay never duplicates channels.
- `session.ended`: marks the session ended, archives the channels (read-only, history stays readable), pushes `session.ended` to every open connection of the session and closes them.

If `session.ended` arrives before `session.started` (ordering is not guaranteed), the session is
remembered as ended and a late `session.started` creates its channels already archived.

Delivery policy of the consumer: unparseable or unknown events are dead-lettered; a transient failure
is requeued once (bounded by the AMQP `Redelivered` flag) and dead-lettered the second time.

## Fan-out between instances

Every stored message is published on the bus (`dms:events` in Redis) and delivered from the
subscription, so players connected to different instances of the service see the same messages. With
one instance and no Redis the bus is in-process and behaves the same.

## Storage

MongoDB `dms_db`: `sessions` (members and scopes), `channels` (unique per session and name, with
`visible_to`), `messages` (indexed by channel and time, newest first), `consumed_events` (dedup).

## Tests

```bash
go test ./... -cover
TEST_MONGODB_URI=mongodb://dms_user:<pw>@localhost:27019/?authSource=admin go test ./internal/store/
TEST_REDIS_URL=redis://localhost:6380/0 go test ./internal/pubsub/
```

Domain, chat, WebSocket and HTTP layers are unit-tested with an in-memory repository and a real
WebSocket client. The store and Redis tests run against real containers when the variables are set
and are skipped otherwise.

## Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | `POST /channels/{id}/messages`, `/admin/*` and `/dev/*` exist beyond the contract | gateway and auth: `/admin/*` and `/dev/*` must never be routed to players |
| 2 | The player token is also accepted as `?access_token=`, because browsers cannot set headers on a WebSocket upgrade | the game client, the gateway |
| 3 | The WebSocket protocol adds `ping` / `pong` and a final `session.ended` frame before the close | the game client |
| 4 | `422 INVALID_CONTENT` (empty or longer than `MAX_MESSAGE_LENGTH`) and `409 CHANNEL_ARCHIVED` are answered; the contract names neither | the game client |
| 5 | An unknown session answers `403 NOT_IN_SESSION` rather than 404: a session this service has not heard of grants membership to nobody | the game client |

---

*Discord DMs Service is owned by Racovita Dumitru. See the service's own repository README for the full contract copy and the CHANGELOG.*
