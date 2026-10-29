# Gateway Service - Integration Reference

> **Status:** `stewdh/gateway-service:3.1.0` (Lab 3), run by the team `docker-compose.yml`. `3.0.0` added the
> instances from Service Discovery with round-robin, the JSON logs and `GET /status` (#75); `3.1.0` the circuit
> breaker per instance with the mark-down in Service Discovery (#76). Python gateway, single entry point of the
> system. The Lab 3 parts follow CPR issue #71 until its contract is merged into the README; see §13.

## 1. What this service is

The Gateway is the one public entry point: clients and services reach every other service through it.
It owns no data and publishes no events. It finds the instances of every service in Service Discovery,
spreads the requests to a service over them round-robin, and stops sending requests to an instance that
keeps failing (circuit breaker), which it then marks down in Service Discovery.

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI, httpx |
| **Container port** | `8080` (host `8080`) |
| **Health** | `GET /health` (liveness); `GET /status` (load of this instance, §11) |
| **Instances** | read from Service Discovery (`SERVICE_DISCOVERY_URL`) at startup and every 5 s, round-robin (§9) |
| **Circuit breaker** | per instance: 3 failures within 35 s, cooldown 35 s, one trial; mark-down on every trip (§10) |
| **Logs** | one JSON object per line on stdout (§12) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `stewdh/gateway-service:<lab version>` and `:latest`, published by GitHub Actions on merge to `main` |

## 3. Running it

The team stack runs the published image: `docker compose up -d` in the CPR, with `JWT_SECRET` and
`SERVICE_TOKEN` set in `.env`. The compose file runs the Gateway in static mode until #77 adds Service
Discovery to it and every service registers there; `GATEWAY_SERVICE_DISCOVERY_URL=http://service-discovery-service:8090`
in `.env` points the Gateway at Service Discovery. Standalone, on the `student-id-net` network:

```bash
docker run --rm --network student-id-net -p 8080:8080 \
  -e JWT_SECRET=... -e SERVICE_TOKEN=... \
  -e SERVICE_DISCOVERY_URL=http://service-discovery-service:8090 \
  stewdh/gateway-service:3.1.0
curl http://localhost:8080/health
# {"status":"ok","service":"gateway-service","version":"3.1.0"}
curl http://localhost:8080/status
# {"service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"3.1.0","status":"up","in_flight":0,"max_concurrent_tasks":64}
```

Without `SERVICE_DISCOVERY_URL` the Gateway runs in static mode (§9): one instance per service at the
fixed `*_URL` addresses, which default to the container names of the team compose.

Building from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `JWT_SECRET` | none, required | Verifies the player JWT (HS256). Same value as Player Service's, at least 32 characters, or the Gateway does not start |
| `SERVICE_TOKEN` | none, required | The one `X-Service-Token` of the stack. Must not be empty. Also sent to Service Discovery |
| `JWT_LEEWAY_SECONDS` | `5` | Clock skew tolerated on the token's `exp` |
| `HTTP_REQUEST_TIMEOUT` | `10` | Task timeout in seconds (`10` or `10s`), see §7. x 3.5 = the circuit breaker window and cooldown (35 s), see §10. The connection to an instance has its own fixed 2 s bound (§10) |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit, see §7 |
| `RETRY_AFTER_SECONDS` | `1` | The `Retry-After` of the Gateway's `429` |
| `SERVICE_DISCOVERY_URL` | empty | Base URL of Service Discovery (`http://service-discovery-service:8090`; the team compose sets it from `GATEWAY_SERVICE_DISCOVERY_URL`, empty until #77). Empty: static mode |
| `SD_REFRESH_SECONDS` | `5` | Seconds between two reads of the instance list (`5` or `5s`) |
| `SD_TIMEOUT_SECONDS` | `2` | Bound of one call to Service Discovery (list or mark-down), in seconds |
| `INSTANCE_ID` | `gateway-<hostname>` | This Gateway's `instance_id` in its logs and `/status`; the hostname is the container id in Docker |
| `APP_PORT`, `LOG_LEVEL` | `8080`, `info` | `LOG_LEVEL` is `debug`, `info`, `warn` or `error` |
| `PLAYER_URL`, `SESSION_URL`, `APPLICANT_URL`, `CREDENTIAL_URL`, `SERVER_RULES_URL`, `UNIVERSITY_RECORD_URL`, `MODERATION_URL`, `DISCORD_DMS_URL` | the container names and ports of the team compose (`http://player-service:8080`, `http://applicant-service:8081`, `http://moderation-service:8085`, `http://discord-dms-service:8096`, ...) | Static mode only (`SERVICE_DISCOVERY_URL` empty): base URL of each routed service |

## 5. Routing

`{gateway}/api/v1/<prefix>/<rest>` is forwarded to an instance of the service as `/api/v1/<rest>`.
`<prefix>` is one of `player`, `session`, `applicant`, `credential`, `server-rules`, `university-record`,
`moderation`, `discord-dms` (also the service names in Service Discovery and in the logs); the prefix tells
apart paths that exist in several services, e.g. `/api/v1/applicant/applicants/next` and
`/api/v1/university-record/applicants/next`. Which instance gets the request: §9.

- A service's health checks are `GET /api/v1/<prefix>/health` and `/health/ready` (forwarded to
  `/health` and `/health/ready` of one instance, in turn); events are pushed as
  `POST /api/v1/<prefix>/events`.
- Method, query string, body and headers are forwarded, except hop-by-hop headers and the
  credentials (§6). The Gateway adds `X-Forwarded-For` and `X-Request-ID` (kept if the caller sent
  one, a uuid4 otherwise), and returns the service's answer unchanged: status, headers, body - except
  `X-Request-ID`, which is the one the Gateway forwarded, on every answer including its own errors.
- No retry: a request is sent to one instance at most once, never to a second instance.

## 6. Authorization

Each route accepts one kind of credential (`app/auth.py`, README "Authentication"). A player sends
`Authorization: Bearer <jwt>` (HS256, `JWT_SECRET`, `sub` = player id, `exp` required); a service
sends `X-Service-Token`. The Gateway removes both and any `X-Player-Id` of the caller, and for a
player sets `X-Player-Id: <sub>`. No service sees a token.

| Credential | Routes (service-side path, any prefix unless named) |
| --- | --- |
| None | `GET /health`; Player `POST /api/v1/auth/login` and `POST /api/v1/players` |
| Service token | `GET /health/ready`, `/api/v1/dev/*`, `/api/v1/admin/*`, `POST /api/v1/events`; `POST /api/v1/applicants/next` (Applicant, Credential, University Record); Credential `GET /api/v1/applicants/{id}/documents/validation` and `GET /api/v1/applicants/{id}`; University Record `GET /api/v1/applicants/{id}/records`; Server Rules `GET /api/v1/rulesets/current` and `POST /api/v1/rulesets/{id}/evaluations`; Applicant and Credential `GET`/`POST /api/v1/applicants`, `PATCH`/`DELETE /api/v1/applicants/{id}` |
| Player or service | Player `GET /api/v1/players/{id}`, Session `GET /api/v1/sessions/{id}`, Applicant `GET /api/v1/applicants/{id}` |
| Player | Everything else |

Paths are matched after percent-decoding, lower-casing and collapsing slashes, so `/ADMIN` or
`/adm%69n` cannot slip past a service-only rule. Errors: `401 UNAUTHENTICATED` (no usable player
token), `401 INVALID_SERVICE_TOKEN` (a wrong service token), `403 SERVICE_TOKEN_REQUIRED` (a
service-only route without one).

## 7. Limits and error codes

A task is one request being proxied. Contract: README "Task timeout and concurrent task limit".

| Setting | Variable | Default | When reached |
| --- | --- | --- | --- |
| Task timeout | `HTTP_REQUEST_TIMEOUT` (seconds, `10` or `10s`) | `10` | The task is stopped: `408 REQUEST_TIMEOUT`, `details: { service, timeout_seconds }` |
| Concurrent task limit | `MAX_CONCURRENT_TASKS` | `64` | A new task is refused at once: `429 TOO_MANY_REQUESTS`, `Retry-After: 1`, `details: { max_concurrent_tasks }` |

- **The timeout covers the task as a whole**: reading the caller's body, waiting for the service
  and reading its whole answer. A service that keeps sending bytes slowly is stopped too.
- **No retry.** A stopped request is cancelled and never sent again, so `POST /applicants/next` is
  never duplicated by the Gateway.
- **Refused before anything else.** A request above the limit is not queued and no service is
  called for it. The check comes first, so a full Gateway answers `429` whatever else is wrong
  with the request. The instance is chosen after the credential is checked, so a refused request
  never uses up a turn of the round-robin.
- **Exempt.** Liveness checks are not refused while the limit is reached: the Gateway's own
  `GET /health` and each service's `GET /api/v1/<prefix>/health`; `GET /status` is not a task at all.
  Readiness (`/health/ready`) is a service-only route and counts as a task.
- **Pass-through.** A `408` or `429` written by a service is an ordinary answer: status, body and
  `Retry-After` reach the caller unchanged. Only the `details` tell the two apart: the Gateway's
  carry `service` / `max_concurrent_tasks`.
- **Order of the layers.** Services stop their own tasks at `5s`, so with the defaults a slow
  service answers its own `408` first and the Gateway's `10s` is the backstop for a service that
  does not answer at all. To show the Gateway's own `408`, run it with a timeout below the
  service's (`HTTP_REQUEST_TIMEOUT=2`) and call `GET /api/v1/applicant/dev/slow?ms=4000`.
- The limit is counted per process; the image runs one worker.

Other errors the Gateway answers itself: `400 VALIDATION_ERROR` (a path that tries to leave the
service), `404 NOT_FOUND` (unknown prefix), `502 BAD_GATEWAY` (the instance is unreachable, or no
connection to it was made within 2 s),
`503 SERVICE_UNAVAILABLE` (the service has no instance, or the circuit breaker of every instance is open:
`details: { service }`, no instance is called; §9, §10). `503` is new in Lab 3 and not yet in README
"Errors" (#71).

## 8. WebSocket negotiation

The Gateway negotiates the chat connection and never carries it.

- `POST /api/v1/discord-dms/ws-tickets` is an ordinary player route: the JWT is checked,
  `X-Player-Id` set, and Discord DMs answers `201 { "ws_url", "expires_at" }` with a one-time ticket
  (valid 30 s, once), or its own `403 NOT_IN_SESSION` / `409 SESSION_NOT_ACTIVE`. Never retried.
- The client opens `ws_url` on Discord DMs directly (host port `8086`).
- `GET /api/v1/discord-dms/ws` sent to the Gateway is refused with `400 VALIDATION_ERROR` before any
  service is called: forwarded as a plain GET it would only burn the ticket.

## 9. Instances from Service Discovery and round-robin

**Reading the instances.** With `SERVICE_DISCOVERY_URL` set, the Gateway calls

```
GET {SERVICE_DISCOVERY_URL}/api/v1/instances
X-Service-Token: <SERVICE_TOKEN>
X-Request-ID: <a new uuid4 per call>
```

(all services: no `?service=`) once at startup, before it serves its first request, and then every
`SD_REFRESH_SECONDS` (5 s) in the background; each call is bounded by `SD_TIMEOUT_SECONDS` (2 s). The
expected answer is

```json
{ "instances": [ { "instance_id": "applicant-3f4e2a9b1c7d", "service_name": "applicant", "host": "172.18.0.12",
                   "port": 8081, "version": "3.0.0", "status": "up", "last_seen_at": "2026-10-27T12:00:00Z" } ] }
```

and an instance is reached at `http://<host>:<port>` (`[host]` for an IPv6 address).

- **Each successful read replaces the whole list**, so an instance that registered or went away is routed to,
  or no longer routed to, within 5 s, without a restart.
- **Which entries are used.** Only `status` `up` (the list holds nothing else; an entry without `status` is taken
  as `up`); entries whose `service_name` is not one of the 8 prefixes are ignored; entries without a usable
  `instance_id`, `host` or `port` are left out and counted as `invalid` in the `sd.refresh` line. A
  `{ "items": [...] }` answer is accepted as well (§13).
- **Service Discovery unreachable.** No answer, a timeout, an error status (`401`, `5xx`, ...) or an answer that
  is not an instance list: the last list is kept, routing goes on with it, and `sd.refresh` is logged at `warn`
  with the reason. If Service Discovery has never answered since the Gateway started, every service has no
  instance (`503`) until it does.
- **Service Discovery restarted.** Its registry is in memory, so for up to one heartbeat (5 s) after a restart it
  lists no instance at all. An answer that lists no instance at all does not replace a list that holds some until
  3 such answers come in a row (10 s); meanwhile the last list is kept, routing goes on with it, and `sd.refresh`
  is logged at `warn` with `empty_answers`. A service whose own instances all went away while others are still
  listed is dropped at the next read, as before.

**Round-robin.** One counter per service: consecutive requests to a service go to its instances in turn, in
`instance_id` order, which stays the same from one read to the next. Instances whose circuit breaker is open
are skipped (§10). Every request counts, the health checks through the Gateway included, except the ones the
Gateway refuses before choosing an instance (`400`, `401`, `403`, `404`, `429`).

**No instance.** When a service has no instance, or none whose breaker lets the request through, the answer is

```json
503 { "error": { "code": "SERVICE_UNAVAILABLE", "message": "No instance of moderation is available.",
                 "details": { "service": "moderation" } } }
```

logged as `route.no_instance` (with `instances`: how many were listed, all with an open breaker); no instance
is called. An unknown prefix is still `404 NOT_FOUND`.

**Static mode.** With `SERVICE_DISCOVERY_URL` empty (tests, local runs), every service has one instance,
`<prefix>-static` at its `*_URL`, and nothing is read or refreshed. The circuit breaker works the same way, without
a mark-down.

## 10. Circuit breaker

One breaker per instance (`instance_id`). Its window is `HTTP_REQUEST_TIMEOUT` x 3.5: 35 s with the 10 s
default; there is no other setting.

**What counts as a failure** of an instance:

- no answer in time: the HTTP client's timeout (`408`), or the whole-task timeout of §7 (`408`) once the request
  was sent to the instance - not while the caller's own body was still being read;
- a refused or reset connection, a DNS failure, or no connection within 2 s (`502`). A killed container may never
  refuse the connection; without its own bound the connect would wait the whole 10 s. With 2 s even a single
  client makes its 3 failed requests (about 6 s) before Service Discovery expires the record (10-15 s), so the
  Gateway trips and marks the instance down. A slow answer is still bounded by `HTTP_REQUEST_TIMEOUT`;
- any `5xx` answer of the instance, except a `500` whose error code is `DEPENDENCY_UNAVAILABLE`.

Any `4xx` answer, `429` and `422` included, is **not** a failure, and neither is a `500 DEPENDENCY_UNAVAILABLE`:
the instance that answers it is up and reports that a service *it* calls failed or refused it (README "Errors").
That service's own instances are counted by their own breakers; counting the `500` against the caller would trip
every healthy instance of each caller of an unavailable service (Session when Applicant is down, Moderation when
any of its five peers is), and they would flap with every round of health polling. Neither resets anything.

**States.**

| State | What happens | Next |
| --- | --- | --- |
| Closed | Requests go through | The 3rd failure within the sliding 35 s window: open (`breaker.opened`) |
| Open | The round-robin skips the instance (`breaker.rejected`, `debug`) | After a cooldown of 35 s: half-open |
| Half-open | Exactly one trial request goes through (`breaker.half_open`); the others keep skipping the instance while it runs | Trial answered without a failure (below `500`, or `500 DEPENDENCY_UNAVAILABLE`): closed (`breaker.closed`). Trial failed: open again (`breaker.opened`, a new trip) |

A request that was already sent when the breaker changed state counts for nothing: requests in flight at a trip
cannot trip it a second time, and only the trial can close it. A trial that never reached the instance changes
nothing; the next request becomes the trial.

**Mark-down on every trip.** In discovery mode, when the breaker trips (closed to open, or a failed trial):

1. the instance leaves the Gateway's list at once, before the next refresh;
2. one call is sent to Service Discovery in a background task - the request that tripped the breaker gets its
   own answer (`502`, `408` or the `5xx` of the instance) without waiting for it:

   ```
   PUT {SERVICE_DISCOVERY_URL}/api/v1/instances/{instance_id}/status
   X-Service-Token: <SERVICE_TOKEN>
   X-Request-ID: <the id of the request that tripped the breaker>

   { "status": "down", "reason": "breaker_open: 3 failures in 35s" }
   ```

   (`"reason": "breaker_open: trial request failed"` after a failed trial), bounded by `SD_TIMEOUT_SECONDS`;
3. it is logged as `sd.mark_down`: `info` when Service Discovery accepted it, `warn` with the reason when it did
   not answer or answered an error. A single failure is never reported; one trip is one call.

When the mark-down fails, nothing else changes: the open breaker keeps the instance skipped, also if a later
refresh lists it again, and it follows its cooldown and trial. Static mode has no mark-down.

**Recovery.** Service Discovery lists `up` instances only, and an instance marked down there is `up` again only
after its health polling sees it healthy (3 consecutive checks). The breaker uses that:

- When a refresh lists an instance whose breaker is open, **and** a successful refresh *sent after the trip* did
  not list it (Service Discovery confirmed it down), the breaker closes at once (`breaker.closed`, `reason`
  `listed again by Service Discovery`) and the instance is back in the rotation, without waiting for a cooldown.
- A refresh already in flight when the breaker tripped, or one that still lists the instance because the
  mark-down has not reached Service Discovery yet or failed, closes nothing: the instance is back in the list
  but stays skipped, and its breaker keeps to the cooldown and the trial.
- Consequence of the drop in step 1: in discovery mode a tripped instance gets back into the list only through a
  refresh. While Service Discovery is unreachable it stays out (the other instances keep serving; with none left,
  the service answers `503`).

**Every instance open**: `503 SERVICE_UNAVAILABLE` as for a service with no instance (§9). In static mode that is
the answer for 35 s after the third failure of a service in the window, until its trial.

Demo: with 3 copies of a service, the `http.request` lines alternate between their `target_instance`s; stop one
copy and keep sending requests: three `502`s for that copy, then `breaker.opened` and `sd.mark_down` for it, and the
requests go to the other two; Service Discovery shows it `down`. Start it again: once health polling sees it
healthy, Service Discovery lists it, `breaker.closed` (`listed again by Service Discovery`), and it is back in
the rotation.

## 11. Status endpoint

```
GET /status
200 { "service": "gateway", "instance_id": "gateway-3f4e2a9b1c7d", "version": "3.1.0",
      "status": "up", "in_flight": 3, "max_concurrent_tasks": 64 }
```

`in_flight` is the number of requests holding a task slot right now (§7), `max_concurrent_tasks` the configured
limit. No credential; not a task (not counted, never refused), so it answers also when the limit is reached; its
`http.request` line is `debug`. The Gateway has no database: `status` is always `up` (never `503 degraded`).
`GET /health` is unchanged.

## 12. Logs

One JSON object per line on stdout, from the Gateway and from uvicorn alike, at `LOG_LEVEL` and above:

```json
{"time":"2026-10-27T12:00:00.123Z","level":"info","service":"gateway","instance_id":"gateway-3f4e2a9b1c7d","version":"3.1.0","event":"http.request","msg":"request","request_id":"9d2d6c1e-...","method":"GET","path":"/api/v1/moderation/decisions","target":"moderation","target_instance":"moderation-5c1d9e0a7b3f","status":200,"duration_ms":42,"upstream_duration_ms":39,"player_id":"8c1f6a2e-...","client_ip":"172.18.0.9"}
```

Every line has `time` (ISO 8601 UTC with milliseconds and `Z`), `level` (`debug`, `info`, `warn`, `error`),
`service` (`gateway`), `instance_id`, `version`, `event` and `msg`; a line written while a request is handled
also has that request's `request_id`. Fields without a value are left out; `duration_ms` values are integers.

| Event | Level | Fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health*`, `/status` and `/api/v1/<prefix>/health*` | `request_id`, `method`, `path` (no query string), `target` (the prefix), `target_instance`, `status`, `duration_ms`, `upstream_duration_ms` (the call to the instance alone), `player_id` (player tokens), `client_ip`. One line per request, when it ends |
| `http.error` | `warn`; `error` with `stack` for an unexpected error, logged before the `500` is answered | `request_id`, `status`, `code`, `error` (the reason). Every error the Gateway answers itself: `400`, `401`, `403`, `404`, `405`, `408`, `429`, `502`, `503`, `500` |
| `route.no_instance` | `warn` | `target`, `instances` |
| `sd.refresh` | `debug`; `warn` when the read failed, entries were unusable or an answer with no instance at all was not taken | `request_id` (sent to Service Discovery), `instances` (count per service), `error`, `invalid` or `empty_answers` (§9) |
| `breaker.opened` | `warn` | `target`, `target_instance`, `failures` (since the breaker last closed), `window_s` |
| `breaker.half_open` | `info` | the same |
| `breaker.closed` | `info` | the same, and `reason`: `trial request succeeded` or `listed again by Service Discovery` |
| `breaker.rejected` | `debug` | the same; a request skipped the instance |
| `sd.mark_down` | `info`; `warn` when it failed | `target`, `target_instance`, `reason` (as sent), `status` and/or `error`, `request_id` of the request that tripped the breaker |
| `startup`, `shutdown` | `info` | configuration: port, mode, Service Discovery URL and intervals (or the static URLs), timeout, breaker window, limits |

uvicorn's own lines get `event` `server`; its access log is off (the `http.request` line replaces it). Never
logged: `Authorization`, `X-Service-Token`, `JWT_SECRET`, request or response bodies, query strings.

## 13. Contract notes (CPR issue #71 not merged yet)

What the Gateway assumes where #71 is not settled yet, and what it adds:

- **List answer shape.** `{ "instances": [ ... ] }` as in the brief of #71; `{ "items": [ ... ] }` (README "API
  conventions" list shape) is accepted too. An entry without `status` is taken as `up`. The list is read without
  `?service=` and without pagination parameters: it must return every instance in one answer.
- **Mark-down answer.** Any `2xx` counts as accepted; the body is not read.
- **`breaker.half_open`** is a Gateway event not listed in #71 (the open to half-open transition, since every
  transition is logged); `breaker.closed` adds `reason`; `sd.mark_down` is named after `sd.refresh`.
- **`503 SERVICE_UNAVAILABLE`** is to be added to README "Errors" and "Gateway" by #71.
- **`500 DEPENDENCY_UNAVAILABLE` is not a failure** of the instance that answers it (§10). Proposed in the review of
  the Gateway's #76 PR and on #88, whose "Circuit breaker" still reads "any `5xx` answer".
