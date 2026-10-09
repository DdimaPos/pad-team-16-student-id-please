# Discord DMs Service - Integration Reference

Integration reference of the **Discord DMs Service**, one of the eight microservices of the FAF Discord
Moderation game **"Student ID, please"**. This service provides the real-time communication between
the Moderator and the Junior Moderators of a session: it creates the four moderator channels when a
shift starts, moves messages over WebSockets, keeps the history and archives the channels when the
shift ends. It never checks whether what players write is true.

Owner: Racovita Dumitru. Source: the private `discord-DMs-service` repository, linked as a submodule of this CPR.

> **Audience:** developers of the other services of *"Student ID, please"* (Team 16, FAF.PAD21.1), or the Gateway.
> Copied from the service's own README at `v2.1.0`; relative paths below refer to the `discord-DMs-service/` submodule.
> Where the implementation diverges from the CPR contract, the divergence is called out in the last section.

## Integration card

| | |
| --- | --- |
| Language / framework | Go 1.25, Gin, gorilla/websocket |
| Container ports | `8086` WebSocket (`WS_PORT`), the one port published (host `8086`): the WebSocket is connected directly; `8096` REST (`APP_PORT`), reached only through the Gateway inside the network, never published |
| Base path | `/api/v1`; REST reached through the Gateway as `{gateway}/api/v1/discord-dms/...`; `GET /api/v1/ws` reached **directly** on port `8086` |
| Health | `GET /health` (liveness), `GET /health/ready` (readiness: mongodb, pubsub, open connections) |
| Database | MongoDB 7, `dms_db` (own container, host port `27019`) |
| Fan-out | Redis Pub/Sub, `dms_pubsub` (own container, host port `6380`); optional, empty `REDIS_URL` = one instance only |
| Events | `session.started` and `session.ended` are pushed by Session's relay through the Gateway to `POST /api/v1/events`; deduplicated on `event_id` |
| Produces | nothing |
| Receives | `session.started`, `session.ended` |
| Calls | nothing. Zero outbound HTTP dependencies |
| Authentication | Checked by the Gateway, not here: REST endpoints read the calling player from `X-Player-Id` (set by the Gateway after validating the player's JWT); `POST /events`, `/admin/*` and `/dev/*` are forwarded by the Gateway only with the service token. The WebSocket, which bypasses the Gateway, takes a one-time ticket from `POST /api/v1/ws-tickets` |
| Task limits | `HTTP_REQUEST_TIMEOUT` (5 s) stops a task with `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (64) refuses the next one with `429 TOO_MANY_REQUESTS`; health endpoints exempt; a WebSocket upgrade is a task until the protocol switch, the open connection is not. See [Task timeout and concurrent task limit](#task-timeout-and-concurrent-task-limit) |
| Docker image | `dmracovit/discord-dms-service:2.0.0` and `:latest`, public on Docker Hub, linux/amd64 and linux/arm64; published by GitHub Actions on merge to `main` from the `VERSION` file (Lab 2 = `2.x.y`) |

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
across both services.

### From the published image only

```bash
docker network create student-id-net   # once
docker run -d --name discord-dms-service --network student-id-net -p 8086:8086 \
  -e MONGODB_URI="mongodb://dms_user:<password>@<mongo-host>:27017/dms_db?authSource=admin" \
  -e REDIS_URL="redis://<redis-host>:6379/0" \
  -e WS_PUBLIC_URL="ws://localhost:8086" -e DEV_ENDPOINTS=true -e SEED_ON_START=true \
  dmracovit/discord-dms-service:latest
```

`discord-DMs-service/deployments/docker-compose.team.yml` is the same stack without `build:`, the fragment merged into
the team-wide compose in the CPR.

## Configuration

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `MONGODB_URI` | - | yes | MongoDB connection string |
| `MONGODB_DATABASE` | `dms_db` | no | Database name |
| `WS_PUBLIC_URL` | `ws://localhost:8086` | no | The address clients reach this service at **directly**: the base of the `ws_url` a ticket comes with. Not the Gateway |
| `WS_TICKET_TTL` | `30s` | no | How long a WebSocket ticket stays valid |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Task timeout: a request running longer is stopped and answers `408 REQUEST_TIMEOUT`. `5s` or `5`, like the other services. The Gateway allows 10 s, so the outer layer never gives up first |
| `MAX_CONCURRENT_TASKS` | `64` | no | Concurrent task limit: the request above it is refused at once with `429 TOO_MANY_REQUESTS` |
| `APP_PORT` | `8096` | no | Port of the REST API; the Gateway reaches it inside the network (`DISCORD_DMS_URL=http://discord-dms-service:8096`), it is never published |
| `WS_PORT` | `8086` | no | Port of the WebSocket listener: only `GET /api/v1/ws` and `GET /health` answer there. The one port published to clients; must differ from `APP_PORT` |
| `APP_ENV` | `local` | no | `local` / `test` / `development` = text logs; anything else = JSON logs, release mode |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `/api/v1/dev/*` (the slow route for the timeout demo). Keep `false` in shared deployments |
| `SEED_ON_START` | `false` | no | Seed the demo session when there are no sessions |
| `ENSURE_INDEXES_ON_START` | `true` | no | Create the indexes at startup (idempotent), the ticket TTL index included |
| `REDIS_URL` | empty | no | Redis for fan-out between instances. Empty = messages are delivered to this instance's connections only |
| `MAX_MESSAGE_LENGTH` | `2000` | no | Characters per message |
| `HISTORY_DEFAULT_LIMIT` | `50` | no | Page size of the history endpoint |
| `WS_PING_INTERVAL`, `WS_PONG_WAIT`, `WS_WRITE_WAIT` | `30s`, `60s`, `10s` | no | WebSocket keep-alive |
| `DB_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT`, `HTTP_WRITE_TIMEOUT`, `SHUTDOWN_TIMEOUT` | `30s`, `10s`, `0` (none, connections live for the whole shift), `10s` | no | Tuning; a non-zero `HTTP_WRITE_TIMEOUT` must stay above `HTTP_REQUEST_TIMEOUT` |

## HTTP and WebSocket API

Contract endpoints (payloads in the contract section below). "Player" means the Gateway validated
the player's JWT and forwarded the request with `X-Player-Id`; a request without that header answers
`401 UNAUTHENTICATED`. "Service" means the Gateway forwards the route only with the service token.

| Method | Path | Consumed by | Who may call |
| --- | --- | --- | --- |
| `POST` | `/api/v1/ws-tickets` | Client, through the Gateway | player. `{ "session_id" }` -> `201 { ws_url, expires_at }`, a one-time ticket valid `WS_TICKET_TTL` |
| `GET` | `/api/v1/ws?ticket=` | Client, **directly** on port `8086`, upgraded to a WebSocket | the ticket only; `401 INVALID_TICKET` if unknown, expired or already used |
| `GET` | `/api/v1/sessions/{session_id}/channels` | Client, through the Gateway | player |
| `GET` | `/api/v1/channels/{channel_id}/messages?limit=&offset=` | Client, through the Gateway | player |
| `POST` | `/api/v1/events` | Server Moderation Session Service's relay, through the Gateway | service. See [Events](#events) |

Extensions beyond the contract (the CRUD surface of Lab 1 and the demo tooling):

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/api/v1/channels/{channel_id}/messages` | `{ "content": "..." }` sends a message without a WebSocket (player). It is delivered to the open connections like any other |
| `PATCH` | `/api/v1/channels/{channel_id}/messages/{message_id}` | `{ "content": "..." }` edits the caller's own message while the channel is not archived (player); the message gets `edited_at` and open connections receive `message.updated`. `403 NOT_MESSAGE_AUTHOR` for anyone else |
| `DELETE` | `/api/v1/admin/messages/{message_id}` | Removes a message (service) |
| `GET` | `/api/v1/dev/slow?ms=` | Answers after `ms` milliseconds (at most 60 000), to demonstrate `408` and `429` (`DEV_ENDPOINTS=true`, service) |

WebSocket protocol, JSON text frames both ways:

| Direction | Frame |
| --- | --- |
| client to server | `{ "type": "message.send", "channel_id": "...", "content": "..." }` |
| client to server | `{ "type": "ping" }` |
| server to client | `{ "type": "message.new", "message": { message_id, channel_id, author_id, content, sent_at } }` |
| server to client | `{ "type": "message.updated", "message": { ..., edited_at } }` |
| server to client | `{ "type": "error", "error": { "code": "CHANNEL_ACCESS_DENIED", "message": "..." } }` |
| server to client | `{ "type": "pong" }` |
| server to client | `{ "type": "session.ended", "session_id": "..." }`, followed by a normal close |

The server pings every `WS_PING_INTERVAL` and drops a connection that stays silent for `WS_PONG_WAIT`.

Error codes: `VALIDATION_ERROR` (400; also for an empty message or one longer than `MAX_MESSAGE_LENGTH`),
`UNAUTHENTICATED`, `INVALID_TICKET` (401), `NOT_IN_SESSION`, `CHANNEL_ACCESS_DENIED`, `NOT_MESSAGE_AUTHOR`
(403, the last one on the beyond-contract `PATCH` only), `CHANNEL_NOT_FOUND`, `MESSAGE_NOT_FOUND`, `NOT_FOUND`
(404), `METHOD_NOT_ALLOWED` (405), `REQUEST_TIMEOUT` (408), `SESSION_NOT_ACTIVE` (409; also when writing after
the shift ended), `INVALID_EVENT` (422), `TOO_MANY_REQUESTS` (429), `INTERNAL_ERROR` (500). Shared envelope
`{ "error": { "code", "message", "details" } }`.

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

Computed from `session.started` when the channels are created:

| Channel | Who can see it |
| --- | --- |
| `general-mod-chat` | everyone in the session |
| `enrollment-check` | the Moderator and juniors with the `enrollment` scope |
| `course-registration` | the Moderator and juniors with the `courses` scope |
| `faculty-check` | the Moderator and juniors with the `email-groups` or `fcim-logs` scope |

## Events

`POST /api/v1/events` is the consumer side of the CPR "Event delivery": Session's relay pushes every
envelope through the Gateway (`POST {gateway}/api/v1/discord-dms/events`) with the service token.

- **Answer.** `200 { "event_id", "duplicate": false }` once the event is applied. A repeat of an `event_id` already applied answers `200` with `"duplicate": true` and changes nothing: delivery is at-least-once, so a repeat is the deduplication working, not an error.
- **`422 INVALID_EVENT`** when the envelope cannot be parsed, its `event_type` is not one this service consumes, its `version` is not `1`, or its payload fails validation (for example no `session_id`). The producer parks such an event; a retry cannot succeed.
- **`500`** for a failure that may succeed later (MongoDB down). The change is stored first and the `event_id` recorded last - a standalone MongoDB has no multi-document transaction - and applying an event is idempotent, so a failure or a crash in between makes the producer's retry apply it again instead of losing it, and a replay never duplicates channels.
- `session.started`: records the session and creates the four channels with their access lists. A replay never duplicates channels.
- `session.ended`: marks the session ended, archives the channels (read-only, history stays readable), pushes `session.ended` to every open connection of the session and closes them.

There is no ordering guarantee: if `session.ended` arrives before `session.started`, the session is
remembered as ended and a late `session.started` creates its channels already archived.

## Task timeout and concurrent task limit

Every inbound HTTP request under `/api/v1` is one task, as the CPR contract defines it - `POST /events`
and the WebSocket upgrade included. `GET /health` and `GET /health/ready` are not, so a busy service is
not restarted by its orchestrator.

The upgrade request is a task until the protocol switch: the ticket check and the `101 Switching
Protocols` run under the timeout, and an upgrade above the limit is refused with `429` like any
request (the ticket stays usable). Once the protocol switched there is no HTTP request any more, only a
connection that lives for the whole shift: it holds no task slot and no timeout applies to it. Open
connections are reported by `/health/ready`.

- **Timeout.** The request's context expires after `HTTP_REQUEST_TIMEOUT` (5 s). Every MongoDB operation runs under that context, so the task is cancelled where it is and the answer is `408 REQUEST_TIMEOUT` with `details.timeout_ms`. Nothing was changed. The Gateway's own timeout is 10 s, so the outer layer never gives up first.
- **Concurrent limit.** At most `MAX_CONCURRENT_TASKS` (64) requests are in progress; the next one is refused before any work with `429 TOO_MANY_REQUESTS`, `Retry-After: 1` and `details.limit`. Nothing was changed.
- **Demonstration.** With `DEV_ENDPOINTS=true`, `GET /api/v1/dev/slow?ms=7000` answers `408` after 5 s, and 64 parallel `GET /api/v1/dev/slow?ms=3000` make the 65th request answer `429`. The Postman collection's last folder does exactly this.

## Fan-out between instances

Every stored message is published on the bus (`dms:events` in Redis) and delivered from the
subscription, so players connected to different instances of the service see the same messages. With
one instance and no Redis the bus is in-process and behaves the same.

## Storage

MongoDB `dms_db`: `sessions` (members and scopes), `channels` (unique per session and name, with
`visible_to`), `messages` (indexed by channel and time, newest first), `consumed_events` (dedup),
`ws_tickets` (one-time tickets, removed on use and by a TTL index when they expire).

## Docker image, versioning and CI

The image tag is the single line of the `VERSION` file; its MAJOR is the laboratory number, so every
Lab 2 release is `2.x.y` (`2.0.0` now). Images are never pushed by hand:

- `discord-DMs-service/.github/workflows/ci.yml`: on every pull request into `dev` or `main`, and on every push to a work branch, runs `go vet` and the tests against MongoDB and Redis services and builds the image without pushing it.
- `discord-DMs-service/.github/workflows/release.yml`: on every push to `main` (a merge of `dev`), runs the tests and, only if they pass, builds `linux/amd64` and `linux/arm64` and pushes `dmracovit/discord-dms-service:<VERSION>` and `:latest`. It stops when `VERSION` is not `MAJOR.MINOR.PATCH`.

Repository secrets required, never committed: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker
Hub access token with write access). Release flow: bump `VERSION` and the CHANGELOG in a PR into
`dev`, then merge `dev` into `main`.

## Tests

```bash
go test ./... -cover
TEST_MONGODB_URI=mongodb://dms_user:<pw>@localhost:27019/?authSource=admin go test ./internal/store/
TEST_REDIS_URL=redis://localhost:6380/0 go test ./internal/pubsub/
```

Domain, chat, WebSocket and HTTP layers are unit-tested with an in-memory repository and a real
WebSocket client, the ticket negotiation and the events endpoint included. The store and Redis
tests run against real containers when the variables are set and are skipped otherwise.

## Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | `POST /channels/{id}/messages`, `PATCH /channels/{id}/messages/{message_id}` (the Lab 1 CRUD requirement), `/admin/*` and `/dev/*` exist beyond the contract; nothing in the contract depends on them | the Gateway forwards `/admin/*` and `/dev/*` only with the service token |
| 2 | The WebSocket protocol adds frames the contract does not list, all optional for a client: `ping` / `pong`, `message.updated` (after the beyond-contract `PATCH`) and a `session.ended` frame right before the close the contract requires | the game client may ignore them |

Port `8086` is published because the contract says so (the direct WebSocket). Since `2.1.0` it is the WebSocket listener only (`WS_PORT`): the REST routes, which trust `X-Player-Id` like every service, live on `APP_PORT` (`8096`) inside the network and are reached only through the Gateway, so nothing that reads a header is reachable directly.

---

---

*Discord DMs Service is owned by Racovita Dumitru. See the service's own repository README for the full contract copy and the CHANGELOG.*
