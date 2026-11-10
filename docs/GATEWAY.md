# Gateway Service - Integration Reference

> **Status:** `stewdh/gateway-service:4.0.0` (Lab 4). `4.0.0` sends every client request through the Message Broker
> and serves only the client's routes (#110), and adds the log file with `GET /logs` (#112) and `GET /metrics`.
> The instance table read from Service Discovery, the round-robin and the circuit breaker per instance of `3.x` moved
> to the broker (#107). The Lab 4 contract (#105) is not merged yet; where `4.0.0` goes beyond the README, see §14.

## 1. What this service is

The Gateway is the one public entry point: the game client reaches every service through it. It owns no data and
publishes no events. It checks the route and the player's token, then hands the request to the Message Broker as a
gRPC `Request`; the broker puts it into the service's queue `requests.<prefix>`, chooses the least loaded instance
and returns its reply, which the Gateway answers unchanged. Services no longer call each other through the Gateway:
they use the broker directly, so the Gateway keeps only the routes a client calls.

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI, `grpcio` (`grpc.aio`, the broker client), `prometheus-client` |
| **Container port** | `8080` (host `8080`) |
| **Routes** | the user routes of §5 under `/api/v1/<prefix>/...`; anything else `404` |
| **Calls** | only the Message Broker: gRPC `Request` at `MESSAGE_BROKER_URL` (`message-broker-service:8071`), with the metadata `x-service-token` (§7) |
| **Circuit breaker** | one, on the broker: 3 failures within 35 s, cooldown 35 s, one trial (§10) |
| **Health** | `GET /health` (liveness); `GET /status` (load of this instance, §11) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (§12) |
| **Logs** | one JSON object per line on stdout and in `LOG_FILE`; `GET /logs` with `X-Service-Token` (§13) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Service Discovery** | not used: the Gateway does not register and reads no instance list. Service Discovery fetches its `GET /logs` and Prometheus scrapes it as static targets |
| **Docker image** | `stewdh/gateway-service:<lab version>` and `:latest` (`linux/amd64`, `linux/arm64`), published by GitHub Actions on merge to `main`, with the tag `v<version>` and a GitHub Release |

## 3. Running it

The team stack runs the published image: `docker compose up -d` in the CPR, with `JWT_SECRET` and `SERVICE_TOKEN` set
in `.env`. The Gateway needs the broker on `student-id-net` (#113 adds it to the compose). Standalone:

```bash
docker run --rm --network student-id-net -p 8080:8080 \
  -e JWT_SECRET=... -e SERVICE_TOKEN=... \
  -e MESSAGE_BROKER_URL=message-broker-service:8071 \
  stewdh/gateway-service:4.0.0
curl http://localhost:8080/health
# {"status":"ok","service":"gateway-service","version":"4.0.0"}
curl http://localhost:8080/status
# {"service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"4.0.0","status":"up","in_flight":0,"max_concurrent_tasks":64}
```

The Gateway starts without the broker: the channel connects on the first request and reconnects by itself, and until
then every request is `503` with `details.service: "message-broker"`. Building from source and the test suite are in
the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `JWT_SECRET` | none, required | Verifies the player JWT (HS256). Same value as Player Service's, at least 32 characters, or the Gateway does not start |
| `SERVICE_TOKEN` | none, required | The stack's one service token: the gRPC metadata `x-service-token` of every call to the broker, and the credential of `GET /logs`. Must not be empty |
| `MESSAGE_BROKER_URL` | `message-broker-service:8071` | The broker's gRPC address, `host:port` without a scheme; anything else stops the Gateway at startup |
| `JWT_LEEWAY_SECONDS` | `5` | Clock skew tolerated on the token's `exp` |
| `HTTP_REQUEST_TIMEOUT` | `10` | Task timeout in seconds (`10` or `10s`), §8. x 3.5 = the window and cooldown of the breaker on the broker (35 s), §10 |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit, §8 |
| `RETRY_AFTER_SECONDS` | `1` | The `Retry-After` of the Gateway's `429` |
| `INSTANCE_ID` | `gateway-<hostname>` | This Gateway's `instance_id` in its logs and `/status`; the hostname is the container id in Docker |
| `LOG_FILE` | `/var/log/gateway/gateway.jsonl` | The log file next to stdout, read by `GET /logs` (#112); empty = stdout only |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | The file rotates at this size; rotated files kept |
| `APP_PORT`, `LOG_LEVEL` | `8080`, `info` | `LOG_LEVEL` is `debug`, `info`, `warn` or `error` |

Gone in `4.0.0`: `SERVICE_DISCOVERY_URL`, `SD_REFRESH_SECONDS`, `SD_TIMEOUT_SECONDS` and the per-service `*_URL`
(`PLAYER_URL`, ..., `DISCORD_DMS_URL`). A stack that still sets them is not refused; they change nothing.

## 5. Routes

`{gateway}/api/v1/<prefix>/<rest>` reaches the service behind `<prefix>` as `/api/v1/<rest>` (`/api/v1/<prefix>/health`
as `/health`). `<prefix>` is one of `player`, `session`, `applicant`, `credential`, `server-rules`, `university-record`,
`moderation`, `discord-dms`: the service's name in the broker's queue `requests.<prefix>`, in Service Discovery and in
the logs. An unknown prefix is `404 NOT_FOUND` with `details.service`.

**Only user routes (#110, grade 8).** This table is the Gateway's whole routing table (`app/routes.py`). Paths are the
service's own; public routes take no credential, every other one the player's JWT.

| Prefix | Routes |
| --- | --- |
| every prefix | `GET /health` (public, outside the concurrent limit) |
| `player` | `POST /api/v1/auth/login`, `POST /api/v1/players` (public); `GET /api/v1/players`; `GET`, `PATCH`, `DELETE /api/v1/players/{player_id}`; `GET /api/v1/players/{player_id}/profile`, `/shifts`, `/disciplinary-actions`; `GET`, `POST /api/v1/players/{player_id}/friends`; `DELETE /api/v1/players/{player_id}/friends/{friend_id}` |
| `session` | `GET`, `POST /api/v1/sessions`; `GET`, `DELETE /api/v1/sessions/{session_id}`; `POST /api/v1/sessions/{session_id}/players`, `/start`, `/applicants/next`, `/end`; `DELETE /api/v1/sessions/{session_id}/players/{player_id}`; `GET /api/v1/sessions/{session_id}/decisions`, `/events` |
| `applicant` | `GET /api/v1/applicants/{applicant_id}` |
| `credential` | `GET /api/v1/applicants/{applicant_id}/documents` |
| `server-rules` | `GET /api/v1/rulesets/{version}` (`version` an integer) |
| `university-record` | `GET /api/v1/records/{category}` |
| `moderation` | `GET`, `POST /api/v1/decisions`; `GET /api/v1/decisions/{decision_id}`; `GET /api/v1/bans` |
| `discord-dms` | `POST /api/v1/ws-tickets`; `GET /api/v1/sessions/{session_id}/channels`; `GET`, `POST /api/v1/channels/{channel_id}/messages`; `PATCH /api/v1/channels/{channel_id}/messages/{message_id}` |

**Everything else is `404 NOT_FOUND`** (`"No such route."`, `details.service` naming the prefix), whatever the
credential, before the concurrent limit and the credential are checked, and nothing is sent to the broker. That
covers what only services, operators or developers used through the Gateway until Lab 3:

- `POST /api/v1/events` of every consumer (events travel through the broker's topics);
- `/api/v1/admin/*`, `/api/v1/dev/*`, `GET /health/ready`, `/logs`, `/metrics`, `/status`;
- the service-to-service routes: `POST /api/v1/applicants/next` of Applicant, Credential and University Record,
  Credential's `GET /api/v1/applicants/{id}/documents/validation`, University Record's
  `GET /api/v1/applicants/{id}/records`, Server Rules' `GET /api/v1/rulesets/current` and
  `POST /api/v1/rulesets/{version}/evaluations`;
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

A player sends `Authorization: Bearer <jwt>` (HS256, `JWT_SECRET`, `sub` = player id, `exp` required). The Gateway
checks it on every route of §5 that is not public: missing, malformed, expired, a bad signature or a `sub` that is
not a UUID is `401 UNAUTHENTICATED`, and nothing is sent. It removes `Authorization`, `X-Service-Token` and any
`X-Player-Id` of the caller, and sets `X-Player-Id: <sub>` (canonical UUID) for the service.

The service token is no credential for a route any more: a request with only `X-Service-Token` on a player route is
`401 UNAUTHENTICATED`, and on any other path `404`. The Gateway's own `GET /logs` is the one route that takes it
(`403 SERVICE_TOKEN_REQUIRED` without it, also with a player token; `401 INVALID_SERVICE_TOKEN` when wrong). This
follows README "Authentication", "Through the Message Broker (Lab 4)".

## 7. Through the Message Broker

Every request on a user route is one gRPC `Request` (`broker.proto`, package `broker.v1`; the Gateway vendors the
broker's file and its generated Python stubs) to `MESSAGE_BROKER_URL`, with the metadata
`x-service-token: <SERVICE_TOKEN>`.

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

**The reply** is answered unchanged: status, headers and body, except hop-by-hop headers and `Content-Length`;
`X-Request-ID` is the request's. What the broker answers itself is in the shared envelope already and passes through
the same way, so the client sees it as the broker wrote it:

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

A task is one request on a user route. Contract: README "Task timeout and concurrent task limit".

| Setting | Variable | Default | When reached |
| --- | --- | --- | --- |
| Task timeout | `HTTP_REQUEST_TIMEOUT` (seconds, `10` or `10s`) | `10` | The task is stopped: `408 REQUEST_TIMEOUT`, `details: { service, timeout_seconds }` |
| Concurrent task limit | `MAX_CONCURRENT_TASKS` | `64` | A new task is refused at once: `429 TOO_MANY_REQUESTS`, `Retry-After: 1`, `details: { max_concurrent_tasks }` |

- **The timeout covers the task as a whole**: reading the client's body and waiting for the broker's reply. The call
  is cancelled, the broker drops the request, and it is never sent again. A slow upload that leaves no time is
  answered `408` without asking the broker.
- **Order.** The route is resolved first (a removed route is `404` whatever the load), then the limit is checked
  before the credential, and the slot is taken after it with no `await` in between: a full Gateway answers `429`
  whatever the token, and a rejected token never holds a slot.
- **Exempt.** `GET /health` of the Gateway and `GET /api/v1/<prefix>/health` are not refused while the limit is
  reached; `GET /status`, `GET /metrics` and `GET /logs` are not tasks at all.
- **Pass-through.** A `408` or `429` written by the broker or a service is an ordinary answer: status, body and
  `Retry-After` reach the client unchanged.
- **Order of the layers.** Services stop their own tasks at `5s`, the broker gives up a margin before the Gateway, so
  a slow service answers its own `408` first, then the broker, and the Gateway's `10s` is the backstop for a broker
  that does not answer at all.
- The limit is counted per process; the image runs one worker.

Other errors the Gateway answers itself: `400 VALIDATION_ERROR` (a dot segment, a request too large), `404 NOT_FOUND`
(unknown prefix, not a user route), `502 BAD_GATEWAY` (a reply whose status is not an HTTP status), and the `503` of
§7 and §10. `502` for an unreachable instance is gone: the Gateway connects to no instance.

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

One breaker, on the broker, the Gateway's only target, with the rules of README "Circuit breaker". Its window is
`HTTP_REQUEST_TIMEOUT` x 3.5: 35 s with the 10 s default.

- **Failures:** a call that failed in transport (the first and second rows of the table in §7). **Not failures:** a
  reply of any status (a `503` of the broker about a service with no instance says nothing against the broker; the
  breakers per instance are the broker's, with their mark-down in Service Discovery), and a call the broker refused.
- **Closed → open:** the 3rd failure within the sliding 35 s window (`breaker.opened`). Every request is then answered
  `503 SERVICE_UNAVAILABLE`, `details: { "service": "message-broker" }`, without a call (`breaker.rejected`, `debug`).
- **Open → half-open:** after a cooldown of 35 s exactly one trial request goes through (`breaker.half_open`), sent
  with `wait_for_ready`; the others keep being refused while it runs. Success closes the breaker (`breaker.closed`,
  `reason: "trial request succeeded"`); failure opens it again. A trial that never reached the broker changes nothing.
- A request let through before a state change counts for nothing when it answers late.
- `breaker_state{target="message-broker"}` in `GET /metrics` shows the state (0 closed, 1 open, 2 half-open).

Demo: stop the broker and send requests: three `503`s with `details.service: "message-broker"` (`outbound.call` lines
with `error: "UNAVAILABLE"`), then `breaker.opened`, and the next requests are refused without a call; start it again:
after the cooldown the trial goes through and `breaker.closed`. The instances' own breakers and the load-based choice
are shown on the broker (its `docs/MESSAGE_BROKER.md`).

## 11. Status endpoint

```
GET /status
200 { "service": "gateway", "instance_id": "gateway-3f4e2a9b1c7d", "version": "4.0.0",
      "status": "up", "in_flight": 3, "max_concurrent_tasks": 64 }
```

`in_flight` is the number of requests holding a task slot right now (§8), `max_concurrent_tasks` the configured
limit. No credential; not a task, so it answers also when the limit is reached; its `http.request` line is `debug`.
The Gateway has no database: `status` is always `up`. It is not polled by Service Discovery, since the Gateway does
not register.

## 12. Metrics

`GET /metrics` answers the Prometheus text format, with no credential and outside the concurrent limit. Prometheus
scrapes it as a static target, `gateway-service:8080` (#113; Service Discovery's `GET /api/v1/instances/prometheus`
lists only registered instances).

| Series | Meaning |
| --- | --- |
| `http_requests_total{method,route,status}` | Every request the Gateway answered, its own errors included |
| `http_request_duration_seconds{method,route}` | Histogram of the same, in seconds |
| `tasks_in_flight` | Requests holding a task slot now (`in_flight` of `GET /status`) |
| `breaker_state{target="message-broker"}` | The breaker on the broker: 0 closed, 1 open, 2 half-open |

`route` is a template, never the raw path: the user route (`/api/v1/session/sessions/{session_id}`), the Gateway's own
route (`/health`, `/status`, `/metrics`, `/logs`, `/api/v1/discord-dms/ws`), or `unmatched` for anything else,
removed routes included. A method outside the standard ones is `OTHER`. No id, query string or body is a label.

## 13. Logs

One JSON object per line on stdout, from the Gateway and from uvicorn alike, at `LOG_LEVEL` and above:

```json
{"time":"2026-11-10T12:00:00.123Z","level":"info","service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"4.0.0","event":"http.request","msg":"request","request_id":"9d2d6c1e-...","method":"GET","path":"/api/v1/moderation/decisions","target":"moderation","correlation_id":"5b0e8f3a-...","status":200,"duration_ms":42,"upstream_duration_ms":39,"player_id":"8c1f6a2e-...","client_ip":"172.18.0.9"}
```

Every line has `time` (ISO 8601 UTC with milliseconds and `Z`), `level` (`debug`, `info`, `warn`, `error`),
`service` (`gateway`), `instance_id`, `version`, `event` and `msg`; a line written while a request is handled also
has that request's `request_id`. Fields without a value are left out; `duration_ms` values are integers.

| Event | Level | Fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status`, `/metrics`, `/logs` and `/api/v1/<prefix>/health*` | `request_id`, `method`, `path` (no query string), `target` (the prefix), `correlation_id`, `status`, `duration_ms`, `upstream_duration_ms` (the call to the broker alone), `player_id` (player tokens), `client_ip`. One line per request, when it ends |
| `outbound.call` | `info`; `warn` for a failed or refused call; `error` when the broker refused the Gateway's token | `target` (`message-broker`), `service_name` (the prefix), `correlation_id`, `method`, `path` (the service's, no query string), `status` or `error` (the gRPC status) and `reason`, `duration_ms` |
| `http.error` | `warn`; `error` with `stack` for an unexpected error, logged before the `500` is answered | `request_id`, `status`, `code`, `error` (the reason). Every error the Gateway answers itself |
| `breaker.opened` | `warn` | `target` (`message-broker`), `failures` (since the breaker last closed), `window_s` |
| `breaker.half_open` | `info` | the same |
| `breaker.closed` | `info` | the same, and `reason` |
| `breaker.rejected` | `debug` | the same; a request refused without a call |
| `startup`, `shutdown` | `info` | configuration: port, broker address, timeout, breaker window, limits, the log file |
| `logs.file_unavailable` | `warn` | `LOG_FILE` cannot be opened: stdout only, `GET /logs` answers `503` (`path`, `error`) |

A request is followed across the system by its `request_id` (the Gateway, the broker, the instance) and its
`correlation_id` (the Gateway's `Request` and the broker's lines). uvicorn's own lines get `event` `server`; its access
log is off (the `http.request` line replaces it). Never logged: `Authorization`, `X-Service-Token`, `JWT_SECRET`,
request or response bodies, query strings.

**The log file and `GET /logs` (#112).** The same lines, uvicorn's included, also go to `LOG_FILE`
(`/var/log/gateway/gateway.jsonl`). It rotates at `LOG_FILE_MAX_MB` (50) and keeps `LOG_FILE_KEEP` (5) rotated files.

- `GET /logs?since=&until=&level=` streams the Gateway's own lines as `application/x-ndjson`, in the shape every
  component shares (README "Logs download").
- `X-Service-Token` only (§6). It is not a task, and its `http.request` line is at `debug`.
- `/api/v1/<prefix>/logs` is not a user route: `404`, so an instance's `GET /logs` is never reachable through the
  Gateway.
- Service Discovery's `GET /api/v1/logs` fetches this endpoint at `gateway-service:8080` (its default
  `LOGS_STATIC_TARGETS`) for the whole system's zip.

## 14. Divergences from the README contract (#105 not merged)

The README "Gateway" section still describes Lab 3: requests forwarded to the instances read from Service Discovery,
round-robin, a breaker per instance with the mark-down, and the service-token and player-or-service routes. `4.0.0`
follows the Lab 4 brief and the broker's code, as recorded in README's "Known gap (Lab 4, #110)" note. Choices for
#105 to confirm:

1. **The route table** of §5 is the brief's proposal, with `{version}` digits only.
2. **A known path with another method** is `404`, never `405`, like every path that is not a route.
3. **Only three headers** reach the service: `X-Request-ID`, `X-Player-Id` and `Content-Type`.
4. **`timeout_ms`** is what is left of the 10 s once the body has arrived, less a margin, not a flat 10 000.
5. **A request too large for the broker** is `400 VALIDATION_ERROR` with `details.max_bytes`; the contract has no
   `413`.
6. **`503` with `details.service: "message-broker"`** when the broker is unreachable or its breaker open, next to the
   broker's own `503` naming the prefix; README "Errors" lists `503 SERVICE_UNAVAILABLE` for the Gateway only with a
   prefix.

## 15. Postman

`postman/gateway.postman_collection.json`: `{{base_url}}` is the Gateway (`http://localhost:8080`). The collection signs
player tokens itself from `{{jwt_secret}}`.

- `health, status and metrics`: the Gateway's own routes.
- `routing through the broker`: user routes through their prefix, a service's `/health`, the unknown prefix, a path
  that climbs out, `X-Request-ID` kept and returned on the Gateway's own errors.
- `only user routes (Lab 4)`: removed routes answering `404` with the service token, a player token or none.
- `authorization`: the player token's `401`s, a service token alone, public routes.
- `websocket negotiation`: the ticket route as a player route, `401` without a token, the `400` of `GET /ws`.
- `logs (#112)`: `GET /logs` with and without the service token, and `/api/v1/player/logs` answering `404`.

The task timeout and the concurrent limit need a slow route, and the `/dev/*` routes that gave one in Lab 3 are no
longer reachable through the Gateway; they are covered by the service repository's tests, and the broker's own `408`
and `429` by its collection and `scripts/smoke.py`.
