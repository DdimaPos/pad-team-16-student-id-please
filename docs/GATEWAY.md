# Gateway Service - Integration Reference

> **Status:** published as `stewdh/gateway-service:2.2.0` and run by the team `docker-compose.yml`.
> Python gateway, single entry point of the system.

## 1. What this service is

The Gateway is the one public entry point: clients and services reach every other service through it.
It owns no data and publishes no events.

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI, httpx |
| **Container port** | `8080` (host `8080`) |
| **Health** | `GET /health` |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `stewdh/gateway-service:<lab version>` and `:latest`, published by GitHub Actions on merge to `main` |

## 3. Running it

The team stack runs the published image: `docker compose up -d` in the CPR, with `JWT_SECRET` and
`SERVICE_TOKEN` set in `.env`. Standalone, on the `student-id-net` network so the default peer URLs
resolve:

```bash
docker run --rm --network student-id-net -p 8080:8080 \
  -e JWT_SECRET=... -e SERVICE_TOKEN=... stewdh/gateway-service:2.2.0
curl http://localhost:8080/health
# {"status":"ok","service":"gateway-service","version":"2.2.0"}
```

Building from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `JWT_SECRET` | none, required | Verifies the player JWT (HS256). Same value as Player Service's, at least 32 characters, or the Gateway does not start |
| `SERVICE_TOKEN` | none, required | The one `X-Service-Token` of the stack. Must not be empty |
| `JWT_LEEWAY_SECONDS` | `5` | Clock skew tolerated on the token's `exp` |
| `HTTP_REQUEST_TIMEOUT` | `10` | Task timeout in seconds (`10` or `10s`), see §7 |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit, see §7 |
| `RETRY_AFTER_SECONDS` | `1` | The `Retry-After` of the Gateway's `429` |
| `APP_PORT`, `LOG_LEVEL` | `8080`, `info` | |
| `PLAYER_URL`, `SESSION_URL`, `APPLICANT_URL`, `CREDENTIAL_URL`, `SERVER_RULES_URL`, `UNIVERSITY_RECORD_URL`, `MODERATION_URL`, `DISCORD_DMS_URL` | the container names and ports of the team compose (`http://player-service:8080`, `http://applicant-service:8081`, `http://moderation-service:8085`, ...) | Base URL of each routed service |

## 5. Routing

`{gateway}/api/v1/<prefix>/<rest>` is forwarded to the service as `/api/v1/<rest>`. `<prefix>` is one
of `player`, `session`, `applicant`, `credential`, `server-rules`, `university-record`, `moderation`,
`discord-dms`; the prefix tells apart paths that exist in several services, e.g.
`/api/v1/applicant/applicants/next` and `/api/v1/university-record/applicants/next`.

- A service's health checks are `GET /api/v1/<prefix>/health` and `/health/ready` (forwarded to
  `/health` and `/health/ready`); events are pushed as `POST /api/v1/<prefix>/events`.
- Method, query string, body and headers are forwarded, except hop-by-hop headers and the
  credentials (§6). The Gateway adds `X-Request-ID` (kept if the caller sent one) and
  `X-Forwarded-For`, and returns the service's answer unchanged: status, headers, body.
- No retry: a request is sent to the service at most once.

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
  with the request.
- **Exempt.** Liveness checks are not tasks and answer while the limit is reached: the Gateway's
  own `GET /health` and each service's `GET /api/v1/<prefix>/health`. Readiness
  (`/health/ready`) is a service-only route and counts as a task.
- **Pass-through.** A `408` or `429` written by a service is an ordinary answer: status, body and
  `Retry-After` reach the caller unchanged. Only the `details` tell the two apart: the Gateway's
  carry `service` / `max_concurrent_tasks`.
- **Order of the layers.** Services stop their own tasks at `5s`, so with the defaults a slow
  service answers its own `408` first and the Gateway's `10s` is the backstop for a service that
  does not answer at all. To show the Gateway's own `408`, run it with a timeout below the
  service's (`HTTP_REQUEST_TIMEOUT=2`) and call `GET /api/v1/applicant/dev/slow?ms=4000`.
- The limit is counted per process; the image runs one worker.

Other errors the Gateway answers itself: `400 VALIDATION_ERROR` (a path that tries to leave the
service), `404 NOT_FOUND` (unknown prefix), `502 BAD_GATEWAY` (service unreachable).

## 8. WebSocket negotiation

The Gateway negotiates the chat connection and never carries it.

- `POST /api/v1/discord-dms/ws-tickets` is an ordinary player route: the JWT is checked,
  `X-Player-Id` set, and Discord DMs answers `201 { "ws_url", "expires_at" }` with a one-time ticket
  (valid 30 s, once), or its own `403 NOT_IN_SESSION` / `409 SESSION_NOT_ACTIVE`. Never retried.
- The client opens `ws_url` on Discord DMs directly (host port `8086`).
- `GET /api/v1/discord-dms/ws` sent to the Gateway is refused with `400 VALIDATION_ERROR` before any
  service is called: forwarded as a plain GET it would only burn the ticket.
