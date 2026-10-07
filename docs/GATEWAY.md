# Gateway Service - Integration Reference

> **Audience:** developers and agents building the other services of *"Student ID, please"*
> (Team 16, FAF.PAD21.1). Documents what the Gateway does, how to reach a service through it,
> what it answers itself and what it does not do **yet**. The contract it implements is the CPR
> README ("Gateway", "Authentication", "Task timeout and concurrent task limit"); where the
> implementation is behind it, the gap is listed in [§9](#9-what-is-not-done-yet).

---

## Contents

1. [What this service is](#1-what-this-service-is)
2. [Integration card](#2-integration-card)
3. [Running it](#3-running-it)
4. [Configuration](#4-configuration)
5. [Routing](#5-routing)
6. [What the Gateway answers itself](#6-what-the-gateway-answers-itself)
7. [Authorization](#7-authorization)
8. [Limits and WebSocket negotiation](#8-limits-and-websocket-negotiation)
9. [What is not done yet](#9-what-is-not-done-yet)
10. [Notes for service owners](#10-notes-for-service-owners)

---

## 1. What this service is

The Gateway is the single entry point of the system: a client calling a service and a service
calling another service both send the request to it, and it forwards the request to the service
that owns the path. It owns no data, publishes no events and holds no client connection: the one
WebSocket in the system is negotiated through it but carried by Discord DMs Service directly.

- **Calls:** every service, over REST.
- **Is called by:** the game client and every service.

---

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12 / FastAPI, `httpx` for the forwarded requests |
| **Container name and port** | `gateway-service`, `8080` (host `8080`) |
| **Base path** | `/api/v1/<prefix>/...` |
| **Health** | `GET /health` (the Gateway's own), `GET /api/v1/<prefix>/health` (a service's) |
| **Database** | none |
| **Broker** | none |
| **Authentication** | contract: validates the player JWT and the service token and strips both; **not implemented yet** ([§7](#7-authorization)) |
| **Docker image** | `d1vinexd/gateway-service:<lab version>` and `:latest`, published by GitHub Actions on a merge to `main` (`VERSION` file, Lab 2 = `2.x.y`) |
| **Repository** | `gateway-service` (private submodule, owner IacovlevMaxim, the whole team contributes) |

---

## 3. Running it

From the published image, through the team compose in the CPR root (the Gateway block is added
to `docker-compose.yml` once the image is on Docker Hub):

```bash
docker network create student-id-net   # once
cp .env.example .env
docker compose up -d
curl http://localhost:8080/health
```

From source (development), see the service repository README:

```bash
cd gateway-service
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
uvicorn app.main:app --port 8080
pytest
```

---

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `APP_PORT` | `8080` | Listening port |
| `LOG_LEVEL` | `info` | Python log level |
| `HTTP_REQUEST_TIMEOUT` | `10` | Seconds a forwarded request may take (`10` or `10s`); a service that does not answer in time gets `408 REQUEST_TIMEOUT`. Services use `5`, so the outer layer never gives up first |
| `PLAYER_URL` | `http://player-service:8080` | Base URL of Player Service |
| `SESSION_URL` | `http://session-service:8080` | Server Moderation Session Service |
| `APPLICANT_URL` | `http://applicant-service:8081` | Applicant Service |
| `CREDENTIAL_URL` | `http://credential-service:8082` | Credential Service |
| `SERVER_RULES_URL` | `http://server-rules-service:8080` | Server Rules Service |
| `UNIVERSITY_RECORD_URL` | `http://university-record-service:8080` | University Record Service |
| `MODERATION_URL` | `http://moderation-service:8085` | Moderation Service |
| `DISCORD_DMS_URL` | `http://discord-dms-service:8086` | Discord DMs Service |

Planned with the authorization part ([§7](#7-authorization)): `JWT_SECRET` (shared only with Player
Service), `SERVICE_TOKEN` (the one token of the stack) and `MAX_CONCURRENT_TASKS`.

---

## 5. Routing

`{gateway}/api/v1/<prefix>/<rest>` is forwarded to the service behind `<prefix>` as `/api/v1/<rest>`:
the prefix is removed, so every service keeps the paths documented in the CPR README.

| Prefix | Service | Forwarded to |
| --- | --- | --- |
| `player` | Player Service | `http://player-service:8080` |
| `session` | Server Moderation Session Service | `http://session-service:8080` |
| `applicant` | Applicant Service | `http://applicant-service:8081` |
| `credential` | Credential Service | `http://credential-service:8082` |
| `server-rules` | Server Rules Service | `http://server-rules-service:8080` |
| `university-record` | University Record Service | `http://university-record-service:8080` |
| `moderation` | Moderation Service | `http://moderation-service:8085` |
| `discord-dms` | Discord DMs Service | `http://discord-dms-service:8086` |

Examples:

| Call through the Gateway | Reaches |
| --- | --- |
| `GET /api/v1/server-rules/rulesets/current?difficulty=3` | `GET http://server-rules-service:8080/api/v1/rulesets/current?difficulty=3` |
| `POST /api/v1/applicant/applicants/next` | `POST http://applicant-service:8081/api/v1/applicants/next` |
| `POST /api/v1/university-record/applicants/next` | `POST http://university-record-service:8080/api/v1/applicants/next` |
| `POST /api/v1/university-record/events` | `POST http://university-record-service:8080/api/v1/events` |
| `GET /api/v1/session/health` | `GET http://session-service:8080/health` |

**The prefix tells apart paths that exist in several services** (`POST /applicants/next` is in
Applicant, Credential and University Record; `POST /events` in every consumer; `/health` everywhere).

**Health.** `/api/v1/<prefix>/health` and `/api/v1/<prefix>/health/ready` are forwarded to the
service's `/health` and `/health/ready`, which sit outside `/api/v1`.

**What is forwarded.** Method, path remainder, query string (as sent, percent-encoding kept), body and headers.
Hop-by-hop headers (`Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade`, ...) are not. The
Gateway adds `X-Forwarded-For` and `X-Request-ID` (the caller's own `X-Request-ID` is kept).

**What comes back.** The status, headers and body of the service's answer, unchanged: a service's own
errors reach the caller as the service wrote them.

**No retries.** The Gateway forwards a request once. A non-idempotent call such as
`POST /applicants/next` is never duplicated by it; retrying is the caller's job (the event relay of a
producer, for example).

**A path that climbs out of the service** (`..`, also percent-encoded) is rejected with `400`
before anything is forwarded.

---

## 6. What the Gateway answers itself

Always in the shared error envelope `{ "error": { "code", "message", "details" } }`.

| Situation | Status and code | `details` |
| --- | --- | --- |
| Unknown prefix (or a path outside `/api/v1`) | `404 NOT_FOUND` | `{ "service": "<prefix>" }` |
| A path that tries to leave the service's tree (`..`) | `400 VALIDATION_ERROR` | |
| The service is unreachable (connection refused, DNS failure) | `502 BAD_GATEWAY` | `{ "service": "<prefix>" }` |
| The service did not answer within `HTTP_REQUEST_TIMEOUT` | `408 REQUEST_TIMEOUT` | `{ "service": "<prefix>", "timeout_seconds": 10 }` |
| Wrong method on the Gateway's own routes | `405 METHOD_NOT_ALLOWED` | |
| Anything unexpected | `500 INTERNAL_ERROR` (no internals are leaked) | |

Planned with [§7](#7-authorization) and [§8](#8-limits-and-websocket-negotiation): `401 UNAUTHENTICATED`,
`401 INVALID_SERVICE_TOKEN`, `403 SERVICE_TOKEN_REQUIRED`, `429 TOO_MANY_REQUESTS`.

In all of these the request either never reached the service or its answer was lost; callers treat
`408`, `429` and `502` as "may be retried", except for the non-idempotent `POST`s.

---

## 7. Authorization

> **Not implemented yet.** The Gateway currently forwards every header, including `Authorization` and
> `X-Service-Token`, and checks nothing. This section is what the contract requires; see
> [§9](#9-what-is-not-done-yet).

Credentials are checked at the Gateway and only there; services never see the caller's token.

| Caller | Sends | The Gateway checks |
| --- | --- | --- |
| A player | `Authorization: Bearer <jwt>` | HS256 signature with `JWT_SECRET`, `exp` not past, `sub` is a UUID |
| A service | `X-Service-Token: <token>` | equals `SERVICE_TOKEN` |

Before forwarding, the Gateway **removes** `Authorization`, `X-Service-Token` and any `X-Player-Id` the
caller sent, and for a player sets **`X-Player-Id: <sub>`**. A service call carries no `X-Player-Id`.
Which credential each route accepts is the table in the CPR README "Authentication" (public, service
token only, player or service, player only); `/api/v1/<prefix>/dev/*` and `/admin/*` need the service token.

Public routes: `GET /health`, `GET /api/v1/<prefix>/health[/ready]`, `POST /api/v1/player/auth/login`.

---

## 8. Limits and WebSocket negotiation

**Task timeout.** `HTTP_REQUEST_TIMEOUT` (10 s in the Gateway, 5 s in a service): a request that runs longer
is stopped with `408 REQUEST_TIMEOUT`. Today this bounds the wait for the service; a limit on the whole
request is part of the limits work.

**Concurrent task limit.** *Not implemented yet.* `MAX_CONCURRENT_TASKS`: a request above the limit is refused
at once with `429 TOO_MANY_REQUESTS` and `Retry-After`; `/health*` is exempt.

**WebSocket.** The Gateway never carries the chat connection. The client calls
`POST {gateway}/api/v1/discord-dms/ws-tickets` with its JWT; the Gateway authorizes the player and forwards
the request with `X-Player-Id`; **Discord DMs Service** answers with `{ ws_url, expires_at }`, a URL with a
one-time ticket (valid 30 s, bound to the player and the session). The client then connects to that URL,
host port `8086`, directly. So for the Gateway this is an ordinary authorized route, the ticket is issued
and checked by Discord DMs.

---

## 9. What is not done yet

| Part | State | Where |
| --- | --- | --- |
| Routing and error mapping | **done** | `app/routes.py`, `app/proxy.py` |
| CI and Docker Hub release | workflows in `dev`; the image appears after the repository secrets and the first `dev` -> `main` release | `.github/workflows` |
| Authorization (validate JWT and service token, strip, `X-Player-Id`) | not started | `app/auth.py` (planned) |
| Concurrent task limit and a limit on the whole request | not started | `app/limits.py` (planned) |
| Service-only `/dev/*` and `/admin/*` | needs the authorization part | |
| Gateway block in `docker-compose.yml`, published image | after the first release | CPR |

Until the authorization part ships, services keep their own checks and their ports stay published; the
services switch to `X-Player-Id` and unpublish their ports together with it.

---

## 10. Notes for service owners

- Reach another service as `{GATEWAY}/api/v1/<prefix>/...`, never by its own address. Set your peer URL
  variables to the Gateway plus the peer's prefix, for example
  `APPLICANT_URL=http://gateway-service:8080/api/v1/applicant`. Keep your variable names.
- Send `X-Service-Token` on service calls; it is passed through today and checked by the Gateway once the
  authorization part ships.
- Do not retry a non-idempotent `POST` automatically; the Gateway does not either.
- Your service's own timeout must be shorter than the Gateway's (5 s against 10 s), and your calls to
  peers shorter than your own.
- Events are pushed as `POST {GATEWAY}/api/v1/<consumer>/events`; the consumer's `POST /api/v1/events` answers.
- Postman collections use the Gateway as `base_url` (`http://localhost:8080`) with the service prefix in
  the path.
