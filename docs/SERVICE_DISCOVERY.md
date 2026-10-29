# Service Discovery Service - Integration Reference

> **Status:** `3.0.0` released (tag `v3.0.0`, the merge commit of vvtttvv/service-discovery-service#8). Image
> `d1vinexd/service-discovery-service:3.0.0` and `:latest` (`linux/amd64`, `linux/arm64`). It holds the registry
> (#69), the mark-down and the circuit breakers (#74), health polling and its alerts (#72), and the Telegram
> notifications (#73). Added to the team `docker-compose.yml` with #77.

## 1. What this service is

The instance registry of Lab 3: which instance of which service runs where, and whether it is `up`
or `down`. Every instance of the eight services registers here and sends a heartbeat; the Gateway
reads the `up` instances from here and marks an instance down when its circuit breaker trips. Service
Discovery polls every instance's `GET /status`, raises alerts on a critical load or an instance that stops
answering, and posts them to the team's Telegram group. It owns no business data and takes part in no
event. Contract: CPR README "Service Discovery", "Status endpoint", "Logging".

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn, httpx |
| **Container port** | `8090` (host `8090`) |
| **Address in the stack** | `http://service-discovery-service:8090` = `SERVICE_DISCOVERY_URL` |
| **Health** | `GET /health`, `GET /status` (no credential) |
| **Credential** | `X-Service-Token` on every `/api/v1/instances` route, checked by Service Discovery itself |
| **Storage** | none, in memory, one copy |
| **Calls out** | each instance's `GET /status` (directly, no credential); the Telegram Bot API when configured |
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

Without `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` it starts as usual and only logs its alerts
(`notify.disabled` at startup). Building from source and the test suite are in the service repository README.

## 4. Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVICE_TOKEN` | none, required | The stack's one `X-Service-Token`. Service Discovery does not start without it |
| `APP_PORT` | `8090` | Listening port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `HTTP_REQUEST_TIMEOUT` | `5s` | Task timeout: `408 REQUEST_TIMEOUT`; x 3.5 = the circuit breaker window (17.5 s) |
| `MAX_CONCURRENT_TASKS` | `64` | Concurrent task limit: `429 TOO_MANY_REQUESTS` + `Retry-After` |
| `RETRY_AFTER_SECONDS` | `1` | `Retry-After` of a `429` |
| `HEARTBEAT_TTL_SECONDS` | `15` | A record with no heartbeat for this long is removed |
| `EXPIRY_SWEEP_SECONDS` | `1` | How often expired records are removed |
| `HEALTH_POLL_SECONDS` | `10` | How often each instance's `GET /status` is checked |
| `HEALTH_POLL_TIMEOUT_SECONDS` | `2` | Longest one status check may take |
| `HEALTH_RECHECK_SECONDS` | `2` | After a failed check, the next one comes this soon |
| `HEALTH_CRITICAL_LOAD` | `0.8` | `in_flight / max_concurrent_tasks` at or above this is a critical load |
| `TELEGRAM_BOT_TOKEN` | empty | The bot's token (@BotFather). Empty: alerts are only logged. Only in `.env` |
| `TELEGRAM_CHAT_ID` | empty | The team group's chat id. Empty: alerts are only logged |
| `NOTIFY_COOLDOWN_SECONDS` | `300` | The same problem for the same instance is sent at most once in this time; `60` for a demo |
| `TELEGRAM_TIMEOUT_SECONDS` | `5` | Longest one `sendMessage` may take |
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
logged only when a record was removed. A deregistered instance raises no alert.

### `GET /api/v1/instances?service=<name>` - list

`200 {"instances": [{instance_id, service_name, host, port, version, status, last_seen_at}]}`. Only `up`
instances. `service` omitted: every service; empty or unknown: `[]`. This is what the Gateway reads every 5 s.

### `PUT /api/v1/instances/{instance_id}/status` - mark down

Called by the Gateway when the circuit breaker of that instance trips (3 failures within its own task timeout
x 3.5):

```json
{ "status": "down", "reason": "breaker_open: 3 failures in 35s" }
```

- `200` with the record (`"status": "down"`) and `ttl_seconds`. The record is kept and heartbeats keep it
  alive, but the list leaves it out until health polling sees 3 healthy checks in a row (20-30 s); heartbeats
  alone never bring it back. Logged as `registry.marked_down` (`marked_down_by: gateway`, `reason`) and raised
  as a `marked_down` alert.
- Marking a `down` instance again is a no-op `200` (no second log line or alert; the first reason stays).
- `400 VALIDATION_ERROR` for anything but `"status": "down"` or a missing or empty `reason` (at most 500
  characters); `404 NOT_FOUND` for an unknown id (it expired or deregistered; the Gateway logs it and moves on).

### `GET /status`

```json
{"service": "service-discovery", "instance_id": "service-discovery-1a2b3c4d5e6f", "version": "3.0.0",
 "status": "up", "in_flight": 0, "max_concurrent_tasks": 64}
```

No database, so always `200 up`. `in_flight` counts the `/api/v1` requests in progress; `/status` and
`/health` are not counted and never refused.

## 6. Health polling, alerts and notifications

- **Polling.** Every registered instance, `up` and `down`, is checked with `GET http://<host>:<port>/status`
  every 10 s, directly, in parallel, each within 2 s. A failed check (anything but a `200` with `in_flight` and
  `max_concurrent_tasks`: a `503 degraded`, a `4xx`, a timeout, a refused connection) is repeated after 2 s.
  The 1st failed check of a streak raises `unreachable`; the 3rd in a row (4-12 s after the first) sets the
  instance `down` (`marked_down_by: health`) and opens its breaker. The 3rd healthy check in a row brings a
  `down` instance back `up` (`registry.recovered`, a `recovered` alert), whoever marked it down.
- **Critical load.** `in_flight / max_concurrent_tasks` at or above 0.8 raises `critical_load`; back under it,
  `load_recovered`. The instance stays listed.
- **Expiry.** The TTL sweep raises `expired` for every record it removes (a crashed instance, 10-15 s after the
  crash). When that id registers again (a restarted container keeps its hostname), the new record is `up` at
  once and a `recovered` alert says it is back.
- **Circuit breakers** (3 failures within 17.5 s, cooldown 17.5 s, one trial call): one per polled instance,
  counting failed checks in a row, and one for Telegram (a timeout, a connection error or a `5xx`).
- **Telegram.** With `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` set, every alert is posted to the group
  (`sendMessage`, HTML: a title with an icon per kind, the service, the instance and its address, the load, the
  UTC time, hashtags of the kind and the service; plain text when the markup is refused). The same problem for
  the same instance is sent at most once per `NOTIFY_COOLDOWN_SECONDS`; a recovery is sent only when it closes a
  problem the group was told about. A `429` blocks the whole chat until its `retry_after`. The token is never
  logged. Setting up the bot: the service README, "Telegram notifications".

What a demo shows, with `docker compose logs -f service-discovery-service`: a service held at its
`MAX_CONCURRENT_TASKS` through its `/dev/slow` endpoint gives `critical_load` within 10 s; `docker kill` gives
`unreachable`, then `marked_down` (by health polling or by the Gateway, whichever comes first) and `expired`,
and `docker start` gives `recovered`; requests slower than the Gateway's timeout make the Gateway trip and mark
the instance down. `docker stop` deregisters and raises nothing.

## 7. Limits and error codes

| Situation | Answer |
| --- | --- |
| No `X-Service-Token` on `/api/v1/instances*` | `403 SERVICE_TOKEN_REQUIRED` |
| Wrong `X-Service-Token` | `401 INVALID_SERVICE_TOKEN` |
| Malformed body or path, mark-down other than `down` | `400 VALIDATION_ERROR` |
| Mark-down of an unknown id, unknown route | `404 NOT_FOUND` |
| Concurrent task limit reached | `429 TOO_MANY_REQUESTS` + `Retry-After` |
| Task longer than `HTTP_REQUEST_TIMEOUT` | `408 REQUEST_TIMEOUT` |
| Anything else | `500 INTERNAL_ERROR`, logged at `error` with the stack trace |

The token check runs before the concurrent limit, so a wrong token never takes a slot.

## 8. Logging

One JSON object per line on stdout, with `time`, `level`, `service` (`service-discovery`),
`instance_id` (its own), `version`, `event`, `msg`, and `request_id` while handling a request
(`X-Request-ID`, generated when missing, echoed in the response). A registered instance is named by
`instance`, `service_name` and `address`, because `instance_id` is Service Discovery's own on every line.

| `event` | Level | When |
| --- | --- | --- |
| `startup` / `shutdown` | `info` | start (the effective settings, `notifications: telegram` or `off`) / stop |
| `http.request` | `info`; `debug` for `/health`, `/status` | every request: `method`, `path`, `status`, `duration_ms`, `client_ip` |
| `http.error` | `info`; `error` for a `500` (with `stack`) | every error answer: `status`, `code` |
| `registry.registered` / `registry.deregistered` | `info` | a new record (`instance_version`; `after_expiry: true` for a return) / a `DELETE` |
| `registry.expired` | `warn` | the TTL sweep removed a record (`last_seen_at`, `ttl_seconds`) |
| `registry.marked_down` / `registry.recovered` | `warn` / `info` | an instance leaves / comes back to the list (`reason`, `marked_down_by`) |
| `health.checked` | `debug` | every status check (`healthy`, `reason`, `load`, `duration_ms`) |
| `health.unreachable` / `health.reachable` | `warn` / `info` | a failure streak starts / ends |
| `health.critical` / `health.load_recovered` | `warn` / `info` | load at or above / back under the threshold |
| `health.error` | `error` | polling of one instance raised; the others go on |
| `breaker.opened` / `breaker.closed` / `breaker.rejected` | `warn` / `info` / `debug` | a circuit breaker changes state or refuses a call |
| `alert.emitted` / `alert.subscriber_failed` | `debug` / `warn` | an alert went through the hook / a subscriber raised |
| `notify.sent` / `notify.failed` / `notify.dropped` | `info` / `warn` / `warn` | a Telegram message was sent / not sent / not queued |
| `notify.skipped` / `notify.disabled` | `debug` / `warn` | cooldown or no open episode / no bot configured |

uvicorn's own access log is off, and its other lines are at `warn` and above only. The service token and the
bot token are never logged.

## 9. Edge cases

- **Restart:** the registry is empty; every instance is back at its next heartbeat (within 5 s). No alert is
  raised for them.
- **Expiry:** a record whose last `PUT` is older than 15 s is removed (checked every second). An
  instance that registers after that gets a new record, `up`, even if the old one was `down`.
- **`down` survives heartbeats:** a heartbeat never sets `status`; only 3 healthy status checks in a row bring a
  `down` instance back `up`.
- **A new IP:** a heartbeat from another source IP (a recreated container keeping its hostname)
  updates `host`.
- **A hung instance** that answers its own requests with `408` after its 5 s task timeout is not a failure for
  the Gateway's breaker (a `4xx`); health polling catches it when its `/status` stops answering within 2 s.
