# Gateway Service - Integration Reference

> **Status:** skeleton. Lab 2, issue #39. Python gateway, single entry point of the system.
> Sections marked *TBD* are filled in by the PRs that implement them.

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

*TBD* - see the service repository README.

## 4. Configuration

*TBD* - route table, peer URLs, `JWT_SECRET`, `SERVICE_TOKEN`, timeout and concurrency variables.

## 5. Routing

*TBD* (issue #40, section 1).

## 6. Authorization

*TBD* (issue #40, section 2): `Authorization` is validated here and not forwarded downstream.

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

*TBD* (issue #40, section 4).
