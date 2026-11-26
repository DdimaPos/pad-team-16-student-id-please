# Gateway Service - Integration Reference

> **Status:** `stewdh/gateway-service:5.0.0` (Lab 5). `5.0.0` keeps a cache in front of the Message Broker for four
> client `GET`s and for the authentication data (#167), spreads its keys over three Valkey nodes with a consistent-hash
> ring (#166), answers the player's logout itself and serves `GET /cache/stats` (§11, §12). Everything of `4.0.0`
> stays: every client request goes through the broker, only the client's routes are served (#110), the log file with
> `GET /logs` (#112) and `GET /metrics`. README "Gateway", "Caching" and "Cache sharding" (the Lab 5 contract, #163)
> describe `5.0.0`; the divergences are in §16.

## 1. What this service is

The Gateway is the one public entry point: the game client reaches every service through it. It owns no data and
publishes no events. It checks the route and the player's token, then hands the request to the Message Broker as a
gRPC `Request`; the broker puts it into the service's queue `requests.<prefix>`, chooses the least loaded instance
and returns its reply, which the Gateway answers unchanged. Services do not call each other through the Gateway: they
use the broker directly, so the Gateway keeps only the routes a client calls. From Lab 5 it answers four `GET` routes
from its cache when it can, and checks two cached facts about the player's token (revoked, player deleted) before it
sends a request.

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI, `grpcio` (`grpc.aio`, the broker client), `redis` (`redis.asyncio`, the cache nodes), `prometheus-client` |
| **Container port** | `8080` (host `8080`) |
| **Routes** | the user routes of §5 under `/api/v1/<prefix>/...`, `POST /api/v1/player/auth/logout` answered by the Gateway (§11); anything else `404` |
| **Calls** | the Message Broker: gRPC `Request` at `MESSAGE_BROKER_URL` (`message-broker-service:8071`), with the metadata `x-service-token` (§7); the cache nodes at `CACHE_NODES` (`cache-1:6379,cache-2:6379,cache-3:6379`, the Redis protocol, §11) |
| **Cache** | the `200` answers of four `GET` routes, the authentication data and the logouts, on three Valkey nodes chosen by a consistent-hash ring; fails open (§11, §12) |
| **Circuit breakers** | one on the broker: 3 failures within 35 s, cooldown 35 s, one trial (§10); one per cache node: 3 failures within 10 s, cooldown 10 s, one trial (§11) |
| **Health** | `GET /health` (liveness); `GET /status` (load of this instance, §13) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (§14) |
| **Logs** | one JSON object per line on stdout and in `LOG_FILE`; `GET /logs` with `X-Service-Token` (§15) |
| **Cache statistics** | `GET /cache/stats` with `X-Service-Token` (§12) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Service Discovery** | not used: the Gateway does not register and reads no instance list. Service Discovery fetches its `GET /logs` and Prometheus scrapes it as static targets |
| **Docker image** | `stewdh/gateway-service:<lab version>` and `:latest` (`linux/amd64`, `linux/arm64`), published by GitHub Actions on merge to `main`, with the tag `v<version>` and a GitHub Release |

## 3. Running it

The team stack runs the published image: `docker compose up -d` in the CPR, with `JWT_SECRET` and `SERVICE_TOKEN` set
in `.env`. The Gateway needs the broker on `student-id-net` (in the compose since #113) and, for the cache, the nodes
`cache-1`, `cache-2` and `cache-3` (in the compose since #183). Standalone:

```bash
docker run --rm --network student-id-net -p 8080:8080 \
  -e JWT_SECRET=... -e SERVICE_TOKEN=... \
  -e MESSAGE_BROKER_URL=message-broker-service:8071 \
  -e CACHE_NODES=cache-1:6379,cache-2:6379,cache-3:6379 \
  stewdh/gateway-service:5.0.0
curl http://localhost:8080/health
# {"status":"ok","service":"gateway-service","version":"5.0.0"}
curl http://localhost:8080/status
# {"service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"5.0.0","status":"up","in_flight":0,"max_concurrent_tasks":64}
```

The Gateway starts without the broker and without the cache nodes: the channel connects on the first request and
reconnects by itself, and until then every request that needs the broker is `503` with
`details.service: "message-broker"`; a cache node that does not answer is skipped (§11). Without `CACHE_NODES` the
cache is off: every cached route answers `X-Cache: BYPASS`, no player is looked up, and logout answers `503`. Building
from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `JWT_SECRET` | none, required | Verifies the player JWT (HS256). Same value as Player Service's, at least 32 characters, or the Gateway does not start |
| `SERVICE_TOKEN` | none, required | The stack's one service token: the gRPC metadata `x-service-token` of every call to the broker, and the credential of `GET /logs` and `GET /cache/stats`. Must not be empty |
| `MESSAGE_BROKER_URL` | `message-broker-service:8071` | The broker's gRPC address, `host:port` without a scheme; anything else stops the Gateway at startup |
| `JWT_LEEWAY_SECONDS` | `5` | Clock skew tolerated on the token's `exp`; also added to the lifetime of a logout's revocation (§11) |
| `HTTP_REQUEST_TIMEOUT` | `10` | Task timeout in seconds (`10` or `10s`), §8. x 3.5 = the window and cooldown of the breaker on the broker (35 s), §10 |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit, §8 |
| `RETRY_AFTER_SECONDS` | `1` | The `Retry-After` of the Gateway's `429` |
| `INSTANCE_ID` | `gateway-<hostname>` | This Gateway's `instance_id` in its logs and `/status`; the hostname is the container id in Docker |
| `LOG_FILE` | `/var/log/gateway/gateway.jsonl` | The log file next to stdout, read by `GET /logs` (#112); empty = stdout only |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | The file rotates at this size; rotated files kept |
| `APP_PORT`, `LOG_LEVEL` | `8080`, `info` | `LOG_LEVEL` is `debug`, `info`, `warn` or `error` |
| `CACHE_NODES` | empty (the compose: `cache-1:6379,cache-2:6379,cache-3:6379`) | The cache nodes, `host:port` separated by commas. Empty turns the cache off. A scheme, a path, a missing port or a node listed twice stops the Gateway at startup. The ring places keys by these names, not by their order (§12) |
| `CACHE_TIMEOUT_MS` | `50` | Every cache call, connecting included, is cut after this and skipped (fail open, §11) |
| `CACHE_BREAKER_WINDOW_SECONDS` | `10` | The window and the cooldown of each cache node's breaker (§11) |
| `CACHE_TTL_RULESET_SECONDS` | `3600` | TTL of `GET /api/v1/server-rules/rulesets/{version}` |
| `CACHE_TTL_APPLICANT_SECONDS` | `300` | TTL of `GET /api/v1/applicant/applicants/{applicant_id}` |
| `CACHE_TTL_DOCUMENTS_SECONDS` | `300` | TTL of `GET /api/v1/credential/applicants/{applicant_id}/documents` |
| `CACHE_TTL_PROFILE_SECONDS` | `30` | TTL of `GET /api/v1/player/players/{player_id}/profile` |
| `AUTH_CACHE_TTL_SECONDS` | `60` | TTL of `auth:player:<player_id>`, whether the player of a token still exists (§11) |

The defaults are the values of README "Caching"; the compose sets only `CACHE_NODES`. Not read since `4.0.0`:
`SERVICE_DISCOVERY_URL`, `SD_REFRESH_SECONDS`, `SD_TIMEOUT_SECONDS` and the per-service `*_URL` (`PLAYER_URL`, ...,
`DISCORD_DMS_URL`). A stack that still sets them is not refused; they change nothing.

## 5. Routes

`{gateway}/api/v1/<prefix>/<rest>` reaches the service behind `<prefix>` as `/api/v1/<rest>` (`/api/v1/<prefix>/health`
as `/health`). `<prefix>` is one of `player`, `session`, `applicant`, `credential`, `server-rules`, `university-record`,
`moderation`, `discord-dms`: the service's name in the broker's queue `requests.<prefix>`, in Service Discovery and in
the logs. An unknown prefix is `404 NOT_FOUND` with `details.service`.

**Only user routes (#110, grade 8).** This table is the Gateway's whole routing table (`app/routes.py`). Paths are the
service's own; public routes take no credential, every other one the player's JWT. The cached routes (§11) are marked.

| Prefix | Routes |
| --- | --- |
| every prefix | `GET /health` (public, outside the concurrent limit) |
| `player` | `POST /api/v1/auth/login`, `POST /api/v1/players` (public); `POST /api/v1/auth/logout` (answered by the Gateway itself, §11); `GET /api/v1/players`; `GET`, `PATCH`, `DELETE /api/v1/players/{player_id}`; `GET /api/v1/players/{player_id}/profile` (cached per calling player), `/shifts`, `/disciplinary-actions`; `GET`, `POST /api/v1/players/{player_id}/friends`; `DELETE /api/v1/players/{player_id}/friends/{friend_id}` |
| `session` | `GET`, `POST /api/v1/sessions`; `GET`, `DELETE /api/v1/sessions/{session_id}`; `POST /api/v1/sessions/{session_id}/players`, `/start`, `/applicants/next`, `/end`; `DELETE /api/v1/sessions/{session_id}/players/{player_id}`; `GET /api/v1/sessions/{session_id}/decisions`, `/events` |
| `applicant` | `GET /api/v1/applicants/{applicant_id}` (cached) |
| `credential` | `GET /api/v1/applicants/{applicant_id}/documents` (cached) |
| `server-rules` | `GET /api/v1/rulesets/{version}` (`version` an integer; cached) |
| `university-record` | `GET /api/v1/records/{category}` |
| `moderation` | `GET`, `POST /api/v1/decisions`; `GET /api/v1/decisions/{decision_id}`; `GET /api/v1/bans` |
| `discord-dms` | `POST /api/v1/ws-tickets`; `GET /api/v1/sessions/{session_id}/channels`; `GET`, `POST /api/v1/channels/{channel_id}/messages`; `PATCH /api/v1/channels/{channel_id}/messages/{message_id}` |

The Gateway's own routes, outside `/api/v1/<prefix>`: `GET /health`, `GET /status`, `GET /metrics`, `GET /logs` and
`GET /cache/stats`.

**Everything else is `404 NOT_FOUND`** (`"No such route."`, `details.service` naming the prefix), whatever the
credential, before the concurrent limit and the credential are checked, and nothing is sent to the broker. That
covers what only services, operators or developers used through the Gateway until Lab 3:

- `POST /api/v1/events` of every consumer (events travel through the broker's topics);
- `/api/v1/admin/*`, `/api/v1/dev/*`, `GET /health/ready`, `/logs`, `/metrics`, `/status`;
- the service-to-service routes: `POST /api/v1/applicants/next` of Applicant, Credential and University Record,
  Credential's `GET /api/v1/applicants/{id}/documents/validation`, University Record's
  `GET /api/v1/applicants/{id}/records`, Server Rules' `GET /api/v1/rulesets/current` and
  `POST /api/v1/rulesets/{version}/evaluations`, and from Lab 5 the saga step routes `/api/v1/saga-steps/...` of
  Session, University Record and Discord DMs (the broker calls them);
- the Applicant and Credential CRUD extensions (`GET`, `POST /api/v1/applicants`, `PATCH`, `DELETE`, and Credential's
  `GET /api/v1/applicants/{id}`) and Session's `GET /api/v1/sessions/{id}/deliveries`;
- a known path with a method it does not take (`PUT /api/v1/players/{id}`): `404`, never `405`.

The services keep those handlers: the services reach them through the broker, and an operator or a Postman folder
calls an instance directly inside `student-id-net` (its README or `docs/` reference says how).

**Matching.** A path is matched as the service will read it: percent-decoded, case-insensitive (the C# services route
case-insensitively), repeated and trailing slashes collapsed. So `/ADMIN`, `/adm%69n` or `/admin/` never reach a
route by another spelling, and a path parameter never holds a `/`. `{version}` takes digits only, because Server
Rules' service-only `/rulesets/current` has the same shape. A dot segment (`..`, `%2e%2e`) is
`400 VALIDATION_ERROR`. What is sent is the path as the client wrote it, still percent-encoded.

## 6. Authorization

A player sends `Authorization: Bearer <jwt>` (HS256, `JWT_SECRET`, `sub` = player id, `exp` required, `jti` from
Player Service `5.0.0`). The Gateway checks it on every route of §5 that is not public: missing, malformed, expired, a
bad signature, a `sub` that is not a UUID or a `jti` that is not a non-empty string is `401 UNAUTHENTICATED`, and
nothing is sent. It removes `Authorization`, `X-Service-Token` and any `X-Player-Id` of the caller, and sets
`X-Player-Id: <sub>` (canonical UUID) for the service.

From Lab 5, when the cache is on, two cached checks follow the token's signature and `exp` (§11): a token whose `jti`
was revoked by a logout, and a token whose player Player Service no longer knows, are `401 UNAUTHENTICATED`. A token
without `jti` (issued by Player `4.0.0`) is accepted and cannot be revoked.

The service token is no credential for a route: a request with only `X-Service-Token` on a player route is
`401 UNAUTHENTICATED`, and on any other path `404`. The Gateway's own `GET /logs` and `GET /cache/stats` are the routes
that take it (`403 SERVICE_TOKEN_REQUIRED` without it, also with a player token; `401 INVALID_SERVICE_TOKEN` when
wrong). This follows README "Authentication".

## 7. Through the Message Broker

Every request on a user route that is not answered from the cache is one gRPC `Request` (`broker.proto`, package
`broker.v1`; the Gateway vendors the broker's file and its generated Python stubs) to `MESSAGE_BROKER_URL`, with the
metadata `x-service-token: <SERVICE_TOKEN>`.

| `ServiceRequest` field | Value |
| --- | --- |
| `service` | the prefix |
| `correlation_id` | a new uuid4 per request, in the Gateway's `http.request` and `outbound.call` lines and the broker's |
| `method`, `path` | the client's method; the service's path (`/api/v1/<rest>` or `/health`) with the query string |
| `headers` | exactly `X-Request-ID` (the client's, or a new uuid4), `X-Player-Id` (player routes only) and the client's `Content-Type` when there is one. No other header of the client is sent (`Accept`, `X-Forwarded-For`, cookies, custom ones) |
| `body` | the client's body, unchanged |
| `request_id` | the same as `X-Request-ID` |
| `caller` | `gateway` (for the logs; not a credential) |
| `timeout_ms` | what is left of `HTTP_REQUEST_TIMEOUT` once the body has arrived, less a tenth (at most 250 ms): at most 9 750 with the 10 s default |

The player lookup of §11 is a `Request` too: `service` `player`, `GET /api/v1/players/{player_id}`, the headers
`X-Request-ID` and `X-Player-Id` (the token's `sub`), `timeout_ms` at most 1 000, logged `auth.lookup`.

**The reply** is answered unchanged: status, headers and body, except hop-by-hop headers and `Content-Length`;
`X-Request-ID` is the request's, and a cached route adds `X-Cache` (§11). What the broker answers itself is in the
shared envelope already and passes through the same way, so the client sees it as the broker wrote it:

| From the broker | When |
| --- | --- |
| `503 SERVICE_UNAVAILABLE`, `details.service` = the prefix | no instance of the service is subscribed, every one is skipped by its breaker, the instance holding a non-`GET` lost its stream, the broker is stopping |
| `408 REQUEST_TIMEOUT` | no reply within `timeout_ms` |
| `429 TOO_MANY_REQUESTS` + `Retry-After` | the broker's workers are taken |

The Gateway never names the instance that answered, neither in an answer nor in a log line.

**What the Gateway answers when the call itself fails:**

| gRPC outcome of `Request` | Answer | For the breaker (§10) |
| --- | --- | --- |
| `UNAVAILABLE`, `INTERNAL`, `UNKNOWN`, `CANCELLED`, `ABORTED`, `DATA_LOSS`, `UNIMPLEMENTED`, `RESOURCE_EXHAUSTED` | `503 SERVICE_UNAVAILABLE`, `details: { "service": "message-broker" }` | a failure |
| `DEADLINE_EXCEEDED`, or the task timeout once the call was sent | `408 REQUEST_TIMEOUT`, `details: { service, timeout_seconds }` | a failure |
| `UNAUTHENTICATED`, `PERMISSION_DENIED` (the Gateway's `SERVICE_TOKEN` is wrong: a configuration error, logged at `error`) | `503`, `details.service: "message-broker"` | not a failure |
| `INVALID_ARGUMENT`, `OUT_OF_RANGE` (a request the broker will not carry, e.g. an `X-Request-ID` over 200 characters) | `400 VALIDATION_ERROR`, `details: { service, reason }` | not a failure |

**Size.** A request larger than the broker carries (body, headers and path together, 4 MiB less 64 KiB) is
`400 VALIDATION_ERROR` with `details.max_bytes`, refused before all of the body is read (a declared `Content-Length`
over it at once).

**No retries.** A request is sent once. A non-idempotent call such as `POST /decisions` or
`POST /sessions/{id}/applicants/next` is never duplicated by the Gateway; the broker reroutes only a `GET` whose
instance failed (its README "Rerouting").

**The connection.** One `grpc.aio` channel, opened at startup; it connects on the first request and reconnects by
itself. Keepalive every 2 s, 2 s to answer, also without calls: after `docker kill` on Docker Desktop a connection is
never refused, and a dead broker would otherwise be noticed only at each deadline. Reconnect backoff 0.5 s up to 2 s,
so a broker that comes back after a long outage is reached again within 2 s. A call fails at once (`UNAVAILABLE`)
while there is no connection, except the breaker's half-open trial, which waits for it within its deadline.

## 8. Limits and error codes

A task is one request on a user route, the logout included. Contract: README "Task timeout and concurrent task
limit".

| Setting | Variable | Default | When reached |
| --- | --- | --- | --- |
| Task timeout | `HTTP_REQUEST_TIMEOUT` (seconds, `10` or `10s`) | `10` | The task is stopped: `408 REQUEST_TIMEOUT`, `details: { service, timeout_seconds }` |
| Concurrent task limit | `MAX_CONCURRENT_TASKS` | `64` | A new task is refused at once: `429 TOO_MANY_REQUESTS`, `Retry-After: 1`, `details: { max_concurrent_tasks }` |

- **The timeout covers the task as a whole**: the cache checks and lookups, reading the client's body and waiting for
  the broker's reply. The call is cancelled, the broker drops the request, and it is never sent again. A slow upload
  that leaves no time is answered `408` without asking the broker.
- **After the deadline.** Once the reply is decided, the cache writes it causes (storing a `MISS`, moving a profile
  generation on, §11) run outside the deadline and before the answer is sent, each bounded by `CACHE_TIMEOUT_MS`: a
  reply that came in the task's last moments is never turned into a `408` by a slow cache, and the caller's next read
  sees its own change.
- **Order.** The route is resolved first (a removed route is `404` whatever the load), then the limit is checked
  before the credential, and the slot is taken after it with no `await` in between: a full Gateway answers `429`
  whatever the token, and a rejected token never holds a slot. The cached checks of the token (§11) run inside the
  slot.
- **Exempt.** `GET /health` of the Gateway and `GET /api/v1/<prefix>/health` are not refused while the limit is
  reached; `GET /status`, `GET /metrics`, `GET /logs` and `GET /cache/stats` are not tasks at all.
- **Pass-through.** A `408` or `429` written by the broker or a service is an ordinary answer: status, body and
  `Retry-After` reach the client unchanged.
- **Order of the layers.** Services stop their own tasks at `5s`, the broker gives up a margin before the Gateway, so
  a slow service answers its own `408` first, then the broker, and the Gateway's `10s` is the backstop for a broker
  that does not answer at all.
- The limit is counted per process; the image runs one worker.

Other errors the Gateway answers itself: `400 VALIDATION_ERROR` (a dot segment, a request too large), `404 NOT_FOUND`
(unknown prefix, not a user route), `502 BAD_GATEWAY` (a reply whose status is not an HTTP status), the `503` of
§7 and §10, and the logout's `503` with `details.service: "cache"` (§11). `502` for an unreachable instance is gone:
the Gateway connects to no instance.

## 9. WebSocket negotiation

The Gateway negotiates the chat connection and never carries it.

- `POST /api/v1/discord-dms/ws-tickets` is an ordinary player route through the broker: the JWT is checked,
  `X-Player-Id` set, and an instance of Discord DMs answers `201 { "ws_url", "expires_at" }` with a one-time ticket
  (valid 30 s, once), or its own `403 NOT_IN_SESSION` / `409 SESSION_NOT_ACTIVE`. Never retried.
- The client opens `ws_url` on Discord DMs directly (host port `8086`).
- `GET /api/v1/discord-dms/ws` sent to the Gateway is refused with `400 VALIDATION_ERROR` before anything is sent,
  with a message that says where to get the ticket. The image runs uvicorn with `--ws none`, so an upgrade reaches
  this guard as a plain `GET` and its ticket is never logged.

## 10. Circuit breaker on the broker

One breaker on the broker, with the rules of README "Circuit breaker". Its window is `HTTP_REQUEST_TIMEOUT` x 3.5:
35 s with the 10 s default. The cache nodes have breakers of their own (§11).

- **Failures:** a call that failed in transport (the first and second rows of the table in §7). **Not failures:** a
  reply of any status (a `503` of the broker about a service with no instance says nothing against the broker; the
  breakers per instance are the broker's, with their mark-down in Service Discovery), and a call the broker refused.
- **One permit per client request**, taken only when the broker is to be called: a cache hit takes none. The player
  lookup (§11) and the request share it, and the outcome of the last call is recorded.
- **Closed → open:** the 3rd failure within the sliding 35 s window (`breaker.opened`). Every request that needs the
  broker is then answered `503 SERVICE_UNAVAILABLE`, `details: { "service": "message-broker" }`, without a call
  (`breaker.rejected`, `debug`); a cache hit is still answered.
- **Open → half-open:** after a cooldown of 35 s exactly one trial request goes through (`breaker.half_open`), sent
  with `wait_for_ready`; the others keep being refused while it runs. Success closes the breaker (`breaker.closed`,
  `reason: "trial request succeeded"`); failure opens it again. A trial that never reached the broker changes nothing.
- A request let through before a state change counts for nothing when it answers late.
- `breaker_state{target="message-broker"}` in `GET /metrics` shows the state (0 closed, 1 open, 2 half-open).

Demo: stop the broker and send requests: three `503`s with `details.service: "message-broker"` (`outbound.call` lines
with `error: "UNAVAILABLE"`), then `breaker.opened`, and the next requests are refused without a call; start it again:
after the cooldown the trial goes through and `breaker.closed`. The instances' own breakers and the load-based choice
are shown on the broker (its `docs/MESSAGE_BROKER.md`).

## 11. Cache (Lab 5, #167)

The contract is README "Caching" ([`../README.md#caching`](../README.md#caching)). The cache is the Gateway's alone; a
cached answer is a copy whose owner stays the source of truth.

**Nodes.** The Valkey nodes of `CACHE_NODES`: in the stack `cache-1`, `cache-2` and `cache-3` (`valkey/valkey:8-alpine`,
port `6379`, not published on the host, no persistence, 64 MB each with LRU eviction). The Gateway reaches them with
`redis.asyncio`, with no retries and socket timeouts of `CACHE_TIMEOUT_MS`. Each key lives on one node, chosen by the
ring of §12.

**Cached routes.** Only a `200` answer of these `GET`s; every other status, method and route passes through untouched:

| Route at the Gateway | TTL (variable, default) | Key holds the calling player | Invalidated by |
| --- | --- | --- | --- |
| `GET /api/v1/server-rules/rulesets/{version}` | `CACHE_TTL_RULESET_SECONDS`, 1 h | no | nothing: a ruleset version never changes |
| `GET /api/v1/applicant/applicants/{applicant_id}` | `CACHE_TTL_APPLICANT_SECONDS`, 5 min | no | nothing |
| `GET /api/v1/credential/applicants/{applicant_id}/documents` | `CACHE_TTL_DOCUMENTS_SECONDS`, 5 min | no | nothing |
| `GET /api/v1/player/players/{player_id}/profile` | `CACHE_TTL_PROFILE_SECONDS`, 30 s | yes | a `200` or `204` of `PATCH` or `DELETE /api/v1/player/players/{player_id}` through the Gateway |

A hit is answered from the cache with no broker call and no breaker permit.

**Key.** `gw:v1:<prefix>:<service path>`, then `?<query, parameters sorted by name>` when there is a query string,
then `:p=<player_id>` (the calling player) on the profile route, and on the profile route `:g=<generation>`: the value
of `gw:v1:player:gen:<player_id>` for the player in the path, `0` when there is none.

- The path is the one the client sent (not percent-decoded, not lower-cased), with only its UUIDs spelled `8-4-4-4-12`
  in hexadecimal written in lower case. An upper-case UUID is the same resource for every service; braces, a
  `urn:uuid:` prefix, missing or misplaced hyphens or a percent-encoded character keep their own key, so a spelling a
  service may refuse never reads the answer of the one it accepts.
- Examples: `gw:v1:server-rules:/api/v1/rulesets/7`,
  `gw:v1:applicant:/api/v1/applicants/5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13`,
  `gw:v1:player:/api/v1/players/8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11/profile:p=8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11:g=2`.
- **Value:** JSON with the status, the headers the Gateway passes on except `X-Request-ID`, `X-Cache` and
  `Set-Cookie`, and the body in base64. A value that does not decode is a miss.

**`X-Cache`** is on every answer of a cached route, the Gateway's own errors included:

| `X-Cache` | When |
| --- | --- |
| `HIT` | answered from the cache |
| `MISS` | the key's node answered that it has no value and the request went on to the broker; a `200` is stored. Also on the Gateway's own error once the request was sent to the broker (its `408` or `503`) |
| `BYPASS` | the cache was not asked or did not answer: no `CACHE_NODES`, every node's breaker open for the key, the profile's generation could not be read, or the cache call failed or took longer than `CACHE_TIMEOUT_MS`. Also when the broker was not asked after all: a miss whose request the broker's breaker refuses (`503`) or that has no time left to be sent (`408`). And on the Gateway's own error before the cache was asked (`401`, `429`) |

**Invalidation of a profile.** A `200` or `204` of `PATCH` or `DELETE /api/v1/player/players/{player_id}` increments
`gw:v1:player:gen:<player_id>` (`INCR` and its TTL of 24 h set again on every change, both in one `MULTI`/`EXEC`, so
the counter never stays without a TTL). Every cached copy of that player's
profile, whoever cached it, is no longer read and expires with its 30 s TTL, and an answer that was in flight across
the change is stored under the old generation, where nobody reads it. A `DELETE` also sets `auth:player:<player_id>` to
`0` (below). The player is the one Player Service reads in the path: percent-decoded, so `%2D` in the id names the same
player. These writes run once the reply is decided (§8).

**Fail open.** A cache call that errs or takes longer than `CACHE_TIMEOUT_MS` (50 ms) is skipped and logged
`cache.unavailable` (`warn`, `node`, `error`), and the request goes on as if nothing were cached. The cache never fails
a request, except the logout, which exists only to write to it.

**A circuit breaker per cache node**, with the Lab 3 rules: the 3rd failure within `CACHE_BREAKER_WINDOW_SECONDS` (10 s)
opens it (`breaker.opened`, `target` = the node, e.g. `cache-2:6379`); while it is open the node is not called at all
and its keys go to the next node on the ring (§12); after a cooldown of the same 10 s the next call to the node is its
one trial (`breaker.half_open`), and success closes it (`breaker.closed`). A call cut by the request's cancellation
counts for nothing. `breaker_state{target="cache-1:6379"}` and the others show the states (§14).

**Authentication data** (README "Caching"). Only with the cache on, on routes that take a player token, after the token's
signature and `exp`:

1. **Revoked.** When the token has a `jti`, `auth:revoked:<jti>` is read on the key's first two available nodes (the
   owner on the ring and the next one clockwise). Found on either: `401 UNAUTHENTICATED`, "The player token has been
   revoked.". Neither answers: the request goes on.
2. **The player still exists.** `auth:player:<player_id>` holds `1` or `0` for `AUTH_CACHE_TTL_SECONDS` (60 s). On a
   miss the Gateway asks Player `GET /api/v1/players/{player_id}` through the broker (§7, `auth.lookup`): `200` stores
   `1`, `404` stores `0`, anything else, or no answer, stores nothing and the request goes on. Every lookup is counted in
   `gateway_auth_lookups_total` (§14). It is stored only if the
   key is still absent, so a lookup in flight never undoes the `0` of a deletion. `0` answers `401 UNAUTHENTICATED`,
   "The player of this token no longer exists.". When the node that owns `auth:player:<player_id>` does not answer,
   the lookup is skipped: the Gateway never makes a broker call per request while the cache is down.

The token itself is never stored. While the nodes that hold a revocation or `auth:player:<player_id>` do not answer,
or after they restarted or evicted the key, the revocation or deletion is not seen and the token works until its
`exp` (README "Caching").

**Logout.** `POST /api/v1/player/auth/logout` is answered by the Gateway and calls no service. It is a task (§8),
takes no body and needs a valid player token (`401 UNAUTHENTICATED` otherwise).

| Case | Answer | Log |
| --- | --- | --- |
| The token has a `jti` | `auth:revoked:<jti>` = `1` written to the key's first two available nodes, for the token's `exp` minus now, rounded up, plus `JWT_LEEWAY_SECONDS` (at least 1 s), so it lasts as long as the token is accepted; `204 No Content` when at least one node took it | `auth.logout` (`info`: `player_id`, `copies`, `ttl_s`) |
| No node took it (the cache off, every node down) | `503 SERVICE_UNAVAILABLE`, `details: { "service": "cache" }`: the token is still valid | `cache.unavailable` per node that failed |
| The token has no `jti` (Player `4.0.0`) | `204 No Content`; nothing is stored and the token stays valid until it expires | `auth.logout_without_jti` (`info`: `player_id`) |

Its `http.request` line has `target: "gateway"`.

## 12. Cache sharding and `GET /cache/stats` (Lab 5, #166)

The contract is README "Cache sharding" ([`../README.md#cache-sharding`](../README.md#cache-sharding)). The nodes are
plain, independent Valkey servers; the Gateway places the keys itself (`app/ring.py`).

**The ring.**

- The position of a key is `hash(key)`: the first 8 bytes of its MD5 digest, read as a big-endian unsigned 64-bit
  integer. It is the same in every process and after every restart (Python's own `hash()` is randomised per process),
  so every Gateway copy puts a key on the same node.
- Every node of `CACHE_NODES` gets 160 virtual nodes: virtual node `i` (`0` to `159`) of node `n` sits at
  `hash(f"{n}#{i}")`, `n` being its `host:port` (`cache-1:6379`). The placement depends on the node names only, not on
  their order in `CACHE_NODES`.
- A key belongs to the node that owns the first point clockwise from `hash(key)` (`bisect_right`), wrapping around
  after the largest point.
- The nodes of a key are tried in the order of their first point clockwise: the owner first. A node whose breaker is
  open is skipped, so only that node's keys move, each to the node that follows it on the circle, and they come back
  when it answers again. A moved key is a miss, read again from its owner service. A revocation is written to, and read
  from, the first two nodes of that order.
- With 160 points per node, each of three nodes owns about a third of the circle. A fourth node would take over about
  a quarter of the keys, all of them moving to it; `hash % N` would move about three in four.

**`GET /cache/stats`.** The service token, checked by the Gateway (`403 SERVICE_TOKEN_REQUIRED` without it, also with
a player token; `401 INVALID_SERVICE_TOKEN` when wrong). It is not a client route (`/api/v1/<prefix>/cache/stats` is
`404`) and not a task; its `http.request` line is at `debug`. Called inside `student-id-net` or on host port `8080`:

```json
{
  "nodes": [
    { "node": "cache-1:6379", "state": "up", "keys": 123, "hits": 456, "misses": 78 },
    { "node": "cache-2:6379", "state": "down", "keys": null, "hits": null, "misses": null },
    { "node": "cache-3:6379", "state": "up", "keys": 98, "hits": 301, "misses": 64 }
  ],
  "vnodes": 160
}
```

- One entry per node of `CACHE_NODES`, in their order. `state` is `up`, or `down` while the node's breaker refuses calls
  (open and its cooldown not over: it is not called) or when it does not answer within `CACHE_TIMEOUT_MS`.
- `keys` is the node's `DBSIZE`: every key on it, `auth:*` and the generations included. `hits` and `misses` are the
  node's own `keyspace_hits` and `keyspace_misses` (`INFO stats`) since it started: every Gateway's lookups together.
  All three are `null` while `down`.
- The nodes are asked together, so the route costs at most one cache timeout. It is not counted by the breakers: a
  statistics call is not a request.
- A node past its cooldown is asked, so a node that was stopped and started again shows `up` as soon as it answers.
  The stats do not move its breaker: it stays open until a request that the node owns runs the trial.

Demo: `docker compose stop cache-2`, read a cached route a few times (`X-Cache: MISS`, then `HIT` from the next node;
`cache.unavailable` and `breaker.opened` for `cache-2:6379`), `GET /cache/stats` shows `cache-2:6379` `down` with
`null`s; `docker compose start cache-2`, wait 10 s, send a request, and the stats show it `up` again with its keys
coming back as they are read.

## 13. Status endpoint

```
GET /status
200 { "service": "gateway", "instance_id": "gateway-3f4e2a9b1c7d", "version": "5.0.0",
      "status": "up", "in_flight": 3, "max_concurrent_tasks": 64 }
```

`in_flight` is the number of requests holding a task slot right now (§8), `max_concurrent_tasks` the configured
limit. No credential; not a task, so it answers also when the limit is reached; its `http.request` line is `debug`.
The Gateway has no database: `status` is always `up`, whatever the cache nodes (their state is in `GET /cache/stats`).
It is not polled by Service Discovery, since the Gateway does not register.

## 14. Metrics

`GET /metrics` answers the Prometheus text format, with no credential and outside the concurrent limit. Prometheus
scrapes it as a static target, `gateway-service:8080` (#113; Service Discovery's `GET /api/v1/instances/prometheus`
lists only registered instances).

| Series | Meaning |
| --- | --- |
| `http_requests_total{method,route,status}` | Every request the Gateway answered, its own errors included |
| `http_request_duration_seconds{method,route}` | Histogram of the same, in seconds |
| `tasks_in_flight` | Requests holding a task slot now (`in_flight` of `GET /status`) |
| `breaker_state{target}` | 0 closed, 1 open, 2 half-open: `target="message-broker"`, the breaker on the broker (§10), and since `5.0.0` one series per cache node, `target="cache-1:6379"` (§11) |
| `gateway_cache_requests_total{route,result}` | One per request of a cached route, counted when it ends, `result` = `hit`, `miss` (sent to the broker) or `bypass` (a cache call that failed counts as `bypass`, and so does a miss the broker was not asked for: the contract's results are these three; the same result as `X-Cache`, §11) |
| `gateway_cache_node_requests_total{node,result}` | One per call to a cache node, `result` = `hit`, `miss`, `write` or `error`. Beyond the contract (README "Metrics" lets a component add its own series): it shows the load and the failures of each node, which `gateway_cache_requests_total` does not |
| `gateway_auth_lookups_total{result}` | One per lookup of the calling player in Player Service when the cache does not know them (§11), `result` = `known` (`200`), `gone` (`404`), `unknown` (another answer, or the call failed) or `skipped` (the breaker on the broker refused it, or no time was left). The authentication lookups #167 asks to see in Prometheus |

`route` is a template, never the raw path: the user route (`/api/v1/session/sessions/{session_id}`,
`/api/v1/player/players/{player_id}/profile`), the Gateway's own route (`/health`, `/status`, `/metrics`, `/logs`,
`/cache/stats`, `/api/v1/player/auth/logout`, `/api/v1/discord-dms/ws`), or `unmatched` for anything else, removed
routes included. A method outside the standard ones is `OTHER`. `node` is a `host:port` of `CACHE_NODES`. No id,
query string, key or body is a label. The CPR's Grafana dashboard "System" draws the cache hit ratio per node and the
cache answers by result from these two series (#201, #207).

## 15. Logs

One JSON object per line on stdout, from the Gateway and from uvicorn alike, at `LOG_LEVEL` and above:

```json
{"time":"2026-11-25T12:00:00.123Z","level":"info","service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"5.0.0","event":"http.request","msg":"request","request_id":"9d2d6c1e-...","method":"GET","path":"/api/v1/server-rules/rulesets/7","target":"server-rules","correlation_id":"5b0e8f3a-...","status":200,"duration_ms":3,"player_id":"8c1f6a2e-...","cache":"hit","client_ip":"172.18.0.9"}
```

Every line has `time` (ISO 8601 UTC with milliseconds and `Z`), `level` (`debug`, `info`, `warn`, `error`),
`service` (`gateway`), `instance_id`, `version`, `event` and `msg`; a line written while a request is handled also
has that request's `request_id`. Fields without a value are left out; `duration_ms` values are integers.

| Event | Level | Fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status`, `/metrics`, `/logs`, `/cache/stats` and `/api/v1/<prefix>/health*` | `request_id`, `method`, `path` (no query string), `target` (the prefix; `gateway` for the logout), `correlation_id`, `status`, `duration_ms`, `upstream_duration_ms` (the call to the broker alone), `player_id` (player tokens), `cache` (a cached route: `hit`, `miss`, `bypass`, or `error` when the cache call failed), `client_ip`. One line per request, when it ends |
| `outbound.call` | `info`; `warn` for a failed or refused call; `error` when the broker refused the Gateway's token | `target` (`message-broker`), `service_name` (the prefix), `correlation_id`, `method`, `path` (the service's, no query string), `status` or `error` (the gRPC status) and `reason`, `duration_ms` |
| `auth.lookup` | the same as `outbound.call` | the player lookup of §11: `service_name` `player`, `path` `/api/v1/players/{player_id}` |
| `cache.unavailable` | `warn` | `node`, `error` (the exception's type, e.g. `TimeoutError`, `ConnectionError`): a cache call skipped (§11) |
| `auth.logout` | `info` | `player_id`, `copies` (nodes that took the revocation), `ttl_s` |
| `auth.logout_without_jti` | `info` | `player_id`: a logout of a token that cannot be revoked |
| `http.error` | `warn`; `error` with `stack` for an unexpected error, logged before the `500` is answered | `request_id`, `status`, `code`, `error` (the reason). Every error the Gateway answers itself |
| `breaker.opened` | `warn` | `target` (`message-broker`, or a cache node such as `cache-2:6379`), `failures` (since the breaker last closed), `window_s` |
| `breaker.half_open` | `info` | the same |
| `breaker.closed` | `info` | the same, and `reason` |
| `breaker.rejected` | `debug` | the same; a call refused without being made |
| `startup`, `shutdown` | `info` | configuration: port, broker address, timeout, breaker window, limits, the log file, the cache nodes, the cache timeout, the cache breaker window and the TTLs |
| `logs.file_unavailable` | `warn` | `LOG_FILE` cannot be opened: stdout only, `GET /logs` answers `503` (`path`, `error`) |

A request is followed across the system by its `request_id` (the Gateway, the broker, the instance) and its
`correlation_id` (the Gateway's `Request` and the broker's lines). uvicorn's own lines get `event` `server`; its access
log is off (the `http.request` line replaces it). Never logged: `Authorization`, `X-Service-Token`, `JWT_SECRET`,
the token's `jti`, cache keys and values, request or response bodies, query strings.

**The log file and `GET /logs` (#112).** The same lines, uvicorn's included, also go to `LOG_FILE`
(`/var/log/gateway/gateway.jsonl`). It rotates at `LOG_FILE_MAX_MB` (50) and keeps `LOG_FILE_KEEP` (5) rotated files.

- `GET /logs?since=&until=&level=` streams the Gateway's own lines as `application/x-ndjson`, in the shape every
  component shares (README "Logs download").
- `X-Service-Token` only (§6). It is not a task, and its `http.request` line is at `debug`.
- `/api/v1/<prefix>/logs` is not a user route: `404`, so an instance's `GET /logs` is never reachable through the
  Gateway.
- Service Discovery's `GET /api/v1/logs` fetches this endpoint at `gateway-service:8080` (its default
  `LOGS_STATIC_TARGETS`) for the whole system's zip.

## 16. Divergences from the README contract

None in the routes, the credentials, the request to the broker, the limits, the breaker on the broker, the cached
routes, their keys and TTLs, `X-Cache`, the authentication data, the logout, the ring or the shape of
`GET /cache/stats`: README "Gateway", "Authentication", "Circuit breaker", "Task timeout and concurrent task limit",
"Caching" and "Cache sharding" describe `5.0.0`. What differs:

1. **`502 BAD_GATEWAY`** when the broker hands back a reply whose status is not an HTTP status (outside `100`-`599`),
   `details.service` naming the prefix (`app/proxy.py`). README "Errors" lists `502` for the Gateway in Lab 2-3 only.
2. **`outbound.call`** names the broker in `target` (`message-broker`) and the prefix in `service_name`; README
   "Logging" gives `target` as the prefix.
3. **The cache nodes' breakers** have a window and cooldown of their own, `CACHE_BREAKER_WINDOW_SECONDS` (10 s), where
   README "Circuit breaker" gives every breaker the task timeout x 3.5 and no new variable. A cache call is bounded by
   50 ms, and a node that comes back should take its keys again within seconds, not after 35 s of misses.
4. **`GET /cache/stats`** shows a node `down` also when its breaker is closed but it does not answer within
   `CACHE_TIMEOUT_MS`, and `up` when its breaker is open but its cooldown is over and it answers; README "Cache
   sharding" says `down` while the node's breaker is open.
5. **`breaker_state{target}`** has a series per cache node (`target` = the node's `host:port`); README "Metrics" gives
   the Gateway's `target` as `message-broker` only.

Beyond the contract: inside its `400 VALIDATION_ERROR`, the details of a dot segment, of a request too large for the
broker (`details.max_bytes`, §7) and of a request the broker will not carry (`details.reason`); the series
`gateway_cache_node_requests_total` and `gateway_auth_lookups_total` (§14); the `cache` field of `http.request` and the events `auth.lookup`,
`auth.logout` and `auth.logout_without_jti` (§15; README "Logging" names `cache.unavailable` for the Gateway).

## 17. Postman

`postman/gateway.postman_collection.json`: `{{base_url}}` is the Gateway (`http://localhost:8080`). The collection signs
player tokens itself from `{{jwt_secret}}`, for `{{player_id}}`, the seeded player `dima_mod` of Player Service (with
the cache on, the Gateway checks that the token's player exists).

- `health, status and metrics`: the Gateway's own routes.
- `routing through the broker`: user routes through their prefix, a service's `/health`, the unknown prefix, a path
  that climbs out, `X-Request-ID` kept and returned on the Gateway's own errors.
- `only user routes (Lab 4)`: removed routes answering `404` with the service token, a player token or none.
- `authorization`: the player token's `401`s, a service token alone, public routes.
- `websocket negotiation`: the ticket route as a player route, `401` without a token, the `400` of `GET /ws`.
- `logs (#112)`: `GET /logs` with and without the service token, and `/api/v1/player/logs` answering `404`.
- `cache, logout and cache stats (Lab 5)`: the profile read after a change (`X-Cache: MISS`), then from the cache
  (`HIT`, the same body); a `404` never cached (`MISS` twice); `GET /cache/stats` with its shape and its `403`/`401`;
  the cache series in `GET /metrics`; a token with a `jti` accepted, logged out (`204`) and refused (`401`); a logout
  without a token (`401`); and a token without `jti`, whose logout answers `204` and which still works.

The task timeout and the concurrent limit need a slow route, and the `/dev/*` routes that gave one in Lab 3 are no
longer reachable through the Gateway; they are covered by the service repository's tests, and the broker's own `408`
and `429` by its collection and `scripts/smoke.py`. Stopping a cache node (§12) is a manual step, not in the
collection; `lab5-shift` plays the cache and the logout inside a whole shift.
