# Service Discovery Service - Integration Reference

> **Status:** `3.0.0` in development (#69, base registry). Image `d1vinexd/service-discovery-service`,
> published by CI on the first release; added to the team `docker-compose.yml` with #77. Health
> polling (#72), notifications (#73) and mark-down with the circuit breakers (#74) are not in it yet.

## 1. What this service is

The instance registry of Lab 3: which instance of which service runs where, and whether it is `up`
or `down`. Every instance of the eight services registers here and sends a heartbeat; the Gateway
reads the `up` instances from here. It owns no business data and takes part in no event. Contract:
CPR README "Service Discovery", "Status endpoint", "Logging".

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn, httpx |
| **Container port** | `8090` (host `8090`) |
| **Address in the stack** | `http://service-discovery-service:8090` = `SERVICE_DISCOVERY_URL` |
| **Health** | `GET /health`, `GET /status` (no credential) |
| **Credential** | `X-Service-Token` on every `/api/v1/instances` route, checked by Service Discovery itself |
| **Storage** | none, in memory, one copy |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `d1vinexd/service-discovery-service:<lab version>` and `:latest`, published by GitHub Actions on merge to `main` |

Instances call it **directly**, not through the Gateway: the Gateway itself needs the registry to route.

## 3. Running it

```bash
docker run --rm --network student-id-net --name service-discovery-service -p 8090:8090 \
  -e SERVICE_TOKEN=... d1vinexd/service-discovery-service:3.0.0
curl http://localhost:8090/health
# {"status":"ok","service":"service-discovery","version":"3.0.0"}
```

Building from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVICE_TOKEN` | none, required | The stack's one `X-Service-Token`. Service Discovery does not start without it |
| `APP_PORT` | `8090` | Listening port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout: `408 REQUEST_TIMEOUT` |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit: `429 TOO_MANY_REQUESTS` + `Retry-After` |
| `RETRY_AFTER_SECONDS` | `1` | `Retry-After` of a `429` |
| `HEARTBEAT_TTL_SECONDS` | `15` | A record with no heartbeat for this long is removed |
| `EXPIRY_SWEEP_SECONDS` | `1` | How often expired records are removed |
| `INSTANCE_ID` | `service-discovery-<hostname>` | Its own id, in its logs and `/status` |

## 5. Endpoints

### `PUT /api/v1/instances/{instance_id}` - register and heartbeat

```json
{ "service_name": "player", "port": 8080, "version": "3.0.0" }
```

`host` is optional (from `INSTANCE_HOST`, for an instance outside Docker); without it the request's
source IP is stored. `200` with the record:

```json
{
  "instance_id": "player-3f4e2a9b1c7d", "service_name": "player", "host": "172.18.0.12", "port": 8080,
  "version": "3.0.0", "status": "up", "last_seen_at": "2026-10-27T12:00:00.123Z", "ttl_seconds": 15
}
```

- `instance_id`: `<service_name>-<hostname>`, letters, digits, `.`, `_`, `-`, at most 200 characters.
- `service_name`: one of `player`, `session`, `applicant`, `credential`, `server-rules`,
  `university-record`, `moderation`, `discord-dms`; `port` 1-65535; `version` non-empty.
- `400 VALIDATION_ERROR` for a bad body or an unknown `service_name`, `details.errors[]` names the fields.
- Sending it again updates `service_name`, `host`, `port`, `version` and `last_seen_at` of the same
  record. It never changes `status`.

### `DELETE /api/v1/instances/{instance_id}` - deregister

`204 No Content`, also for an unknown id (idempotent): after a Service Discovery restart or an expired
record, an instance shutting down does not see its deregistration fail. `registry.deregistered` is
logged only when a record was removed.

### `GET /api/v1/instances?service=<name>` - list

`200 {"instances": [{instance_id, service_name, host, port, version, status, last_seen_at}]}`. Only `up`
instances. `service` omitted: every service; empty or unknown: `[]`.

### `GET /status`

```json
{"service": "service-discovery", "instance_id": "service-discovery-1a2b3c4d5e6f", "version": "3.0.0",
 "status": "up", "in_flight": 0, "max_concurrent_tasks": 64}
```

No database, so always `200 up`. `in_flight` counts the `/api/v1` requests in progress; `/status` and
`/health` are not counted and never refused.

## 6. Limits and error codes

| Situation | Answer |
| --- | --- |
| No `X-Service-Token` on `/api/v1/instances*` | `403 SERVICE_TOKEN_REQUIRED` |
| Wrong `X-Service-Token` | `401 INVALID_SERVICE_TOKEN` |
| Malformed body or path | `400 VALIDATION_ERROR` |
| Unknown route | `404 NOT_FOUND` |
| Concurrent task limit reached | `429 TOO_MANY_REQUESTS` + `Retry-After` |
| Task longer than `HTTP_REQUEST_TIMEOUT` | `408 REQUEST_TIMEOUT` |
| Anything else | `500 INTERNAL_ERROR`, logged at `error` with the stack trace |

The token check runs before the concurrent limit, so a wrong token never takes a slot.

## 7. Logging

One JSON object per line on stdout, with `time`, `level`, `service` (`service-discovery`),
`instance_id` (its own), `version`, `event`, `msg`, and `request_id` while handling a request
(`X-Request-ID`, generated when missing, echoed in the response).

| `event` | Level | Extra fields |
| --- | --- | --- |
| `http.request` | `info`; `debug` for `/health`, `/status` | `method`, `path`, `status`, `duration_ms`, `client_ip` |
| `http.error` | `info`; `error` for a `500` (with `stack`) | `status`, `code`, `error` |
| `registry.registered` | `info` | `instance`, `service_name`, `address`, `instance_version` |
| `registry.deregistered` | `info` | same |
| `registry.expired` | `info` | same + `last_seen_at`, `ttl_seconds` |
| `startup` / `shutdown` | `info` | port, log level, timeout, limit, TTL (no secrets) |

The registered instance is logged as `instance` because `instance_id` is Service Discovery's own on
every line. uvicorn's own access log is off, and its other lines are at `warn` and above only.

## 8. Edge cases

- **Restart:** the registry is empty; every instance is back at its next heartbeat (within 5 s).
- **Expiry:** a record whose last `PUT` is older than 15 s is removed (checked every second). An
  instance that registers after that gets a new record, `up`, even if the old one was `down`.
- **`down` survives heartbeats:** a heartbeat never sets `status`. Only health polling (#72) brings a
  `down` instance back `up`; the `down` itself comes from health polling (#72) or the Gateway's
  mark-down (#74). Until then nothing in this version sets `down`.
- **A new IP:** a heartbeat from another source IP (a recreated container keeping its hostname)
  updates `host`.

## 9. Not in this version

- Health polling of every instance's `/status` and load alerts (#72).
- Telegram notifications to the developers (#73).
- `PUT /api/v1/instances/{instance_id}/status` (mark-down) and the circuit breakers (#74).
