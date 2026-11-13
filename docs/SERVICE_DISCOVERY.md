# Service Discovery Service - Integration Reference

> **Status:** `4.0.1` (Lab 4, hotfix #156, vvtttvv/service-discovery-service#20). Image
> `d1vinexd/service-discovery-service:4.0.1` and `:latest` (`linux/amd64`, `linux/arm64`), run by the team
> `docker-compose.yml`. `3.0.0` (tag `v3.0.0`) holds the registry (#69), the mark-down and the circuit breakers (#74),
> health polling and its alerts (#72), and the Telegram notifications (#73). `4.0.0` adds what the Message Broker and
> Prometheus need (#111): `topics` in the registration, `load` on the list, `GET /api/v1/instances?topic=`,
> `GET /api/v1/topics`, `GET /api/v1/instances/prometheus`, `GET /metrics`, `POST /api/v1/alerts`, the broker as the
> mark-down's caller; the log file, `GET /logs` and the aggregated `GET /api/v1/logs` (#112); it no longer serves
> `/openapi.json`, and its dependencies are updated. The Lab 4 additions follow the Lab 4 contract (#105): see §10.
> `4.0.1` changes no API: uvicorn keeps an idle keep-alive connection 120 s instead of 5 s, so heartbeats no longer
> fail now and then (§9, #156).

## 1. What this service is

The instance registry of Lab 3: which instance of which service runs where, and whether it is `up`
or `down`. Every instance of the eight services registers here and sends a heartbeat; in Lab 3 the Gateway
read the `up` instances from here and marked an instance down when its circuit breaker tripped. Service
Discovery polls every instance's `GET /status`, raises alerts on a critical load or an instance that stops
answering, and posts them to the team's Telegram group. It owns no business data and takes part in no
event. Contract: CPR README "Service Discovery", "Status endpoint", "Logging", "Logs download".

From Lab 4 (`4.0.0`) the Message Broker registers too, with the topics each instance publishes and subscribes to;
the broker reads the instances and their load from here, is the mark-down's caller and posts its dead letters as
alerts, and Prometheus finds its targets here (#113).

## 2. Integration card

| | |
| --- | --- |
| **Language / framework** | Python 3.12, FastAPI + uvicorn, httpx |
| **Container port** | `8090` (host `8090`) |
| **Address in the stack** | `http://service-discovery-service:8090` = `SERVICE_DISCOVERY_URL` |
| **Health** | `GET /health`, `GET /status` (no credential) |
| **Metrics** | `GET /metrics`, Prometheus text format, no credential (`4.0.0`) |
| **Logs** | `GET /logs` (its own lines) and `GET /api/v1/logs` (the whole system's, one zip), `X-Service-Token` (`4.0.0`, #112) |
| **Credential** | `X-Service-Token` on every `/api/v1/*` route and on `GET /logs`, checked by Service Discovery itself |
| **Storage** | none, in memory, one copy; its log file inside the container |
| **Calls out** | each instance's `GET /status` (directly, no credential); each component's `GET /logs` for a download; the Telegram Bot API when configured |
| **Callers** | every instance and the broker (registration); the Gateway (Lab 3 list and mark-down); from Lab 4 the broker (list, mark-down, alerts) and Prometheus (targets, `/metrics`) |
| **Error envelope** | `{ "error": { "code", "message", "details" } }`, same as every service |
| **Docker image** | `d1vinexd/service-discovery-service:4.0.1` and `:latest`, published by GitHub Actions on merge to `main` |
| **API schema** | none served: `/docs`, `/redoc` and `/openapi.json` answer `404` (`4.0.0`); this file and the Postman collection document the API |

Instances call it **directly**, not through the Gateway or the broker: the broker itself (the Gateway in Lab 3) needs
the registry to route.

## 3. Running it

```bash
docker run --rm --network student-id-net --name service-discovery-service -p 8090:8090 \
  -e SERVICE_TOKEN=... d1vinexd/service-discovery-service:4.0.1
curl http://localhost:8090/health
# {"status":"ok","service":"service-discovery","version":"4.0.1"}
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
| `LOG_FILE` | `/var/log/service-discovery/service-discovery.jsonl` | The log file next to stdout, read by `GET /logs` (#112); empty = stdout only |
| `LOG_FILE_MAX_MB` / `LOG_FILE_KEEP` | `50` / `5` | The file rotates at this size; rotated files kept |
| `LOGS_STATIC_TARGETS` | `gateway=http://gateway-service:8080` | Components the aggregated download fetches although they do not register, `name=base-url` pairs separated by commas; empty = none. The default is the Gateway of the team compose, which therefore leaves it unset |
| `LOGS_FETCH_DEADLINE_SECONDS` | `60` | Longest one component's download may take in all |

A startup check makes 3 failed status checks fit the circuit breaker window: when `2 x HEALTH_RECHECK_SECONDS + 4 x
HEALTH_POLL_TIMEOUT_SECONDS` (12 s with the defaults) is above `HTTP_REQUEST_TIMEOUT` x 3.5, Service Discovery does not
start (a configuration error naming both numbers), so with the defaults an `HTTP_REQUEST_TIMEOUT` below about 3.43 s
keeps the container restarting.

## 5. Endpoints

### `PUT /api/v1/instances/{instance_id}` - register and heartbeat

```json
{
  "service_name": "session", "port": 8080, "version": "4.0.0",
  "topics": { "publishes": ["events.session.started"], "subscribes": ["events.decision.recorded"] }
}
```

`host` is optional (from `INSTANCE_HOST`, for an instance outside Docker); without it the request's
source IP is stored. `topics` is optional (`4.0.0`). `200` with the record:

```json
{
  "instance_id": "session-3f4e2a9b1c7d", "service_name": "session", "host": "172.18.0.12", "port": 8080,
  "version": "4.0.0", "status": "up", "last_seen_at": "2026-11-09T12:00:00.123Z",
  "topics": { "publishes": ["events.session.started"], "subscribes": ["events.decision.recorded"] },
  "load": null, "last_checked_at": null, "ttl_seconds": 15
}
```

- `instance_id`: `<service_name>-<hostname>`, letters, digits, `.`, `_`, `-`, at most 200 characters.
- `service_name`: one of `player`, `session`, `applicant`, `credential`, `server-rules`,
  `university-record`, `moderation`, `discord-dms`, and from `4.0.0` `message-broker`; `port` 1-65535; `version`
  1-64 characters; `host`, when sent, 1-255 characters.
- `topics` (`4.0.0`): `{ "publishes": [...], "subscribes": [...] }`, both optional, at most 50 names each, every name
  matching `events(\.[a-z][a-z0-9_]*)+` (at most 200 characters); a name given twice is kept once. A heartbeat without
  `topics` keeps what the record has; one with `topics` replaces it. It documents the intent: the broker is the source
  of truth for subscriptions and queues.
- `load` and `last_checked_at` (`4.0.0`) come from the last status check (§6): `load` is
  `in_flight / max_concurrent_tasks` rounded to 3 digits, `null` before the first check and after a failed one.
- `400 VALIDATION_ERROR` for a bad body, an unknown `service_name` or a bad topic name, `details.errors[]` names the
  fields.
- Sending it again updates `service_name`, `host`, `port`, `version` and `last_seen_at` of the same
  record. It never changes `status`.

### `DELETE /api/v1/instances/{instance_id}` - deregister

`204 No Content`, also for an unknown id (idempotent): after a Service Discovery restart or an expired
record, an instance shutting down does not see its deregistration fail. `registry.deregistered` is
logged only when a record was removed. A deregistered instance raises no alert.

### `GET /api/v1/instances?service=<name>&topic=<name>` - list

`200 {"instances": [{instance_id, service_name, host, port, version, status, last_seen_at, topics, load,
last_checked_at}]}`. Only `up` instances. `service` omitted: every service; empty or unknown: `[]`. `topic`
(`4.0.0`): only the instances whose registration subscribes to it; empty or unknown: `[]`. From Lab 4 the broker
reads it every 5 s (`SERVICE_DISCOVERY_REFRESH_SECONDS`) and routes on it (`load`). Gateway `3.1.0` read it every 5 s
for its Lab 3 routing table; Gateway `4.0.0` (#110), which the team compose runs since #113, no longer reads it.

### `GET /api/v1/topics` - topics named by the registrations (`4.0.0`)

```json
{"topics": [{"name": "events.session.started", "publishers": ["session"], "subscribers": ["discord-dms", "university-record"]}]}
```

Every topic named in a registration, sorted by name, with the services (not instances) on each side, sorted. `down`
instances count too, because an outage does not change who means to listen. The broker's own topics listing is the
source of truth for queues and subscriptions; this one shows who says they publish and listen.

### `GET /api/v1/instances/prometheus` - Prometheus targets (`4.0.0`)

Prometheus `http_sd_configs`: every `up` instance of every service and the broker, one entry each, `200` with
`application/json` (`[]` for an empty registry; an IPv6 host is written `[fd00::12]:8080`):

```json
[{"targets": ["172.18.0.12:8080"], "labels": {"service": "player", "instance_id": "player-3f4e2a9b1c7d"}}]
```

It needs `X-Service-Token`, as every `/api/v1/instances` route does, because the list names the instances' addresses
and the port is published on the host. The labels `service` and `instance_id` are enough to group the series by service
and tell the instances apart. The Gateway and Service Discovery do not register, so they are static targets with a
`service` label of their own. The core of the scrape configuration of #113 (the CPR's
`monitoring/prometheus/prometheus.yml`, README "Monitoring"), with the token read from a file so it stays out of
`prometheus.yml`:

```yaml
scrape_configs:
  - job_name: instances
    http_sd_configs:
      - url: http://service-discovery-service:8090/api/v1/instances/prometheus
        http_headers:
          X-Service-Token:
            files: [/etc/prometheus/service_token]
  - job_name: static
    static_configs:
      - targets: [gateway-service:8080]
        labels: {service: gateway}
      - targets: [service-discovery-service:8090]
        labels: {service: service-discovery}
```

`service` and `instance_id` always name the scraped target. The broker's `broker_request_duration_seconds{service}`
has a `service` label of its own, the called service; without `honor_labels` (left off, so a target cannot override
its labels) Prometheus keeps the target's `service: message-broker` and renames the scraped one to `exported_service`.
So the called service is queried as `broker_request_duration_seconds{exported_service="player"}`.

### `GET /metrics` (`4.0.0`)

The Prometheus text format, no credential, outside the concurrent task limit (like `/status`):
`http_requests_total{method,route,status}`, `http_request_duration_seconds{method,route}` (histogram),
`tasks_in_flight` and `breaker_state{target}` (0 closed, 1 open, 2 half-open; `target` is a polled `instance_id` or `telegram`). `route` is
the route's template, an unknown path is `unmatched` and an unknown method `OTHER`, so a caller cannot grow the number
of series. A breaker's series goes away with its record.

### `POST /api/v1/alerts` - an alert from the broker (`4.0.0`)

How the broker tells the developers about a dead letter, through the same alert hook (one bot, one cooldown), so the
broker needs no Telegram code:

```json
{ "kind": "dead_letter", "service_name": "player", "instance_id": "message-broker-1a2b3c4d5e6f",
  "detail": "<event_id> on events.session.ended: <reason>" }
```

- `kind`: only `dead_letter`. `service_name`: the service whose queue held the message, one of the known names above.
  `instance_id`: the broker's own (the cooldown is per kind and instance). `detail`: 1-500 characters; it goes to the
  log and to Telegram, so it names ids and the reason, never a message body.
- `202 {"status": "accepted"}`, logged as `alert.received` (`warn`). The group reads at most one dead letter alert per
  `NOTIFY_COOLDOWN_SECONDS`; the log has every one.
- The address in the alert comes from the raiser's record; right after a Service Discovery restart there may be none,
  and the alert goes out with the source IP and port `0`.
- `400 VALIDATION_ERROR` for any other `kind`, an unknown `service_name` or a bad `instance_id` or `detail`.

### `PUT /api/v1/instances/{instance_id}/status` - mark down

Called when the circuit breaker of that instance trips: in Lab 3 by the Gateway (3 failures within its own task timeout
x 3.5), from Lab 4 by the broker, the endpoint's only caller then. The endpoint itself is unchanged in `4.0.0`:

```json
{ "status": "down", "reason": "breaker_open: 3 failures in 35s" }
```

- `200` with the record (`"status": "down"`) and `ttl_seconds`. The record is kept and heartbeats keep it
  alive, but the list leaves it out until health polling sees 3 healthy checks in a row (20-30 s); heartbeats
  alone never bring it back. Logged as `registry.marked_down` (`reason`; `marked_down_by: broker` from `4.0.0`,
  `gateway` in `3.0.0`) and raised as a `marked_down` alert ("marked down by the broker"). `4.0.0` names the broker
  whoever calls (§10); Gateway `4.0.0` no longer calls it.
- Marking a `down` instance again is a no-op `200` (no second log line or alert; the first reason stays).
- `400 VALIDATION_ERROR` for anything but `"status": "down"` or a missing or empty `reason` (at most 500
  characters); `404 NOT_FOUND` for an unknown id (it expired or deregistered; the broker logs it, `sd.mark_down`, and
  moves on).

### `GET /status`

```json
{"service": "service-discovery", "instance_id": "service-discovery-1a2b3c4d5e6f", "version": "4.0.0",
 "status": "up", "in_flight": 0, "max_concurrent_tasks": 64}
```

No database, so always `200 up`. `in_flight` counts the `/api/v1` requests in progress; `/status` and
`/health` are not counted and never refused.

### `GET /logs?since=&until=&level=` - its own logs (#112)

`X-Service-Token`. Service Discovery's own lines in the window, oldest first, across the rotated files, as
`application/x-ndjson` (`Content-Disposition: attachment; filename="<instance_id>-<since>.jsonl"`). The window is
`since <= time < until` (RFC 3339 with a zone, both optional), and `level` keeps that level and above. `400
VALIDATION_ERROR` names the field. `503 LOGS_UNAVAILABLE` means there is no log file. The route is outside the limiter.
The shape is the one every component shares (CPR README "Logs download").

### `GET /api/v1/logs?service=&instance=&since=&until=&level=` - the whole system's logs (#112)

`X-Service-Token`. It calls `GET /logs` of every matching component in parallel and answers one `application/zip`
(`logs-<since>.zip`) with a `<instance_id>.jsonl` per component and a `manifest.json`.

- `service` omitted means the whole system: every `up` instance, the broker, Service Discovery itself (its own file)
  and the Gateway (`LOGS_STATIC_TARGETS`, file `gateway.jsonl`).
- `service=player`, `message-broker`, `service-discovery` or `gateway` narrows it to one name, and `instance=` to one id.

```json
{"generated_at": "2026-11-05T11:38:16.151Z", "generated_by": "service-discovery-5a3f37dec7e1",
 "query": {"service": null, "instance": null, "since": "2026-11-05T10:00:00.000Z", "until": null, "level": null},
 "files": [{"file": "player-3f4e2a9b1c7d.jsonl", "service": "player", "instance_id": "player-3f4e2a9b1c7d",
            "source": "http://172.18.0.7:8080", "bytes": 48213, "lines": 131}],
 "failed": [{"service": "gateway", "instance_id": "gateway", "source": "http://gateway-service:8080",
             "reason": "unreachable: ConnectError"}]}
```

Some components can fail: one is unreachable, does not send its answer's headers within `HEALTH_POLL_TIMEOUT_SECONDS`,
refuses (`answered 401 INVALID_SERVICE_TOKEN`), fails (`answered 500`, or `failed: <error>` for anything else, such as a
registered host that is no address) or is not done after `LOGS_FETCH_DEADLINE_SECONDS`. Each such component is left out
of the zip and named in `failed`; the download is still `200`. The body is bounded only by the deadline, because an
instance sends its headers at once and then nothing while it scans its files for a narrow window. A registered `host` is only ever a host in the URL, so it cannot choose the port or the path. A `down`
instance is not fetched. One download runs at a time; a second one meanwhile is `429` with `Retry-After: 5`. An unknown
`service`, or an `instance` that is no instance id (letters, digits, `.`, `_`, `-`, at most 200 characters), is `400
VALIDATION_ERROR`. `503 LOGS_UNAVAILABLE` when the zip itself cannot be written.

## 6. Health polling, alerts and notifications

- **Polling.** Every registered instance, `up` and `down`, is checked with `GET http://<host>:<port>/status`
  every 10 s, directly, in parallel, each within 2 s. A failed check (anything but a `200` with `in_flight` and
  `max_concurrent_tasks`: a `503 degraded`, a `4xx`, a timeout, a refused connection) is repeated after 2 s.
  The 1st failed check of a streak raises `unreachable`; the 3rd in a row (4-12 s after the first) sets the
  instance `down` (`marked_down_by: health`) and opens its breaker. The 3rd healthy check in a row brings a
  `down` instance back `up` (`registry.recovered`, a `recovered` alert), whoever marked it down.
- **Critical load.** `in_flight / max_concurrent_tasks` at or above 0.8 raises `critical_load`; back under it,
  `load_recovered`. The instance stays listed.
- **Load on the record** (`4.0.0`). Every check stores its `load` (rounded to 3 digits; `null` after a failed one)
  and `last_checked_at` on the record, which the list returns and the broker routes on.
- **Alert kinds.** `critical_load`, `unreachable`, `expired`, `marked_down`, `dead_letter` (`4.0.0`, from the broker
  through `POST /api/v1/alerts`, its own Telegram title) and the recoveries `recovered` (ends `unreachable`,
  `marked_down` and `expired`) and `load_recovered` (ends `critical_load`).
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
`unreachable`, then `marked_down` (by health polling or by the broker, whichever comes first) and `expired`,
and `docker start` gives `recovered`; an instance that stops replying to the requests it holds, or loses its broker
stream while it holds them, makes the broker's breaker on it trip and mark it down (README "Circuit breaker").
`docker stop` deregisters and raises nothing.

## 7. Limits and error codes

| Situation | Answer |
| --- | --- |
| No `X-Service-Token` on `/api/v1/*` or `GET /logs` | `403 SERVICE_TOKEN_REQUIRED` |
| Wrong `X-Service-Token` | `401 INVALID_SERVICE_TOKEN` |
| Malformed body or path, mark-down other than `down`, a bad topic name, an alert `kind` other than `dead_letter` | `400 VALIDATION_ERROR` |
| Mark-down of an unknown id, unknown route (`/docs`, `/redoc`, `/openapi.json` included, `4.0.0`) | `404 NOT_FOUND` |
| Concurrent task limit reached | `429 TOO_MANY_REQUESTS` + `Retry-After` |
| A logs download while another one runs | `429 TOO_MANY_REQUESTS` + `Retry-After: 5` |
| `GET /logs` without a log file, `GET /api/v1/logs` when the zip cannot be written | `503 LOGS_UNAVAILABLE` |
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
| `http.request` | `info`; `debug` for `/health`, `/status`, `/metrics`, `/logs` | every request: `method`, `path`, `status`, `duration_ms`, `client_ip` |
| `http.error` | `info`; `error` for a `500` (with `stack`) | every error answer: `status`, `code` |
| `registry.registered` / `registry.deregistered` | `info` | a new record (`instance_version`; `after_expiry: true` for a return) / a `DELETE` |
| `registry.expired` | `warn` | the TTL sweep removed a record (`last_seen_at`, `ttl_seconds`) |
| `registry.marked_down` / `registry.recovered` | `warn` / `info` | an instance leaves (`reason`, `marked_down_by`) / comes back to the list (`was_marked_down_by`) |
| `health.checked` | `debug` | every status check (`healthy`, `reason`, `load`, `duration_ms`) |
| `health.unreachable` / `health.reachable` | `warn` / `info` | a failure streak starts / ends |
| `health.critical` / `health.load_recovered` | `warn` / `info` | load at or above / back under the threshold |
| `health.error` | `error` | polling of one instance raised; the others go on |
| `breaker.opened` / `breaker.closed` / `breaker.rejected` | `warn` / `info` / `debug` | a circuit breaker changes state or refuses a call |
| `alert.emitted` / `alert.subscriber_failed` | `debug` / `warn` | an alert went through the hook / a subscriber raised |
| `alert.received` | `warn` | `POST /api/v1/alerts` (`4.0.0`): `kind`, `service_name`, `instance`, the detail in `msg` |
| `notify.sent` / `notify.failed` / `notify.dropped` | `info` / `warn` / `warn` | a Telegram message was sent / not sent / not queued |
| `notify.skipped` / `notify.disabled` | `debug` / `warn` | cooldown or no open episode / no bot configured |
| `logs.file_unavailable` | `warn` | `LOG_FILE` cannot be opened: stdout only (`path`, `error`) |
| `logs.fetch_failed` / `logs.downloaded` | `warn` / `info` | one component left out of a download (`service_name`, `instance`, `reason`) / a download built (`files`, `failed`, `bytes`, `duration_ms`) |
| `logs.download_failed` | `error` | the zip of `GET /api/v1/logs` could not be written: `503 LOGS_UNAVAILABLE` (`error`, the exception's type) |

The same lines also go to `LOG_FILE`, and `GET /logs` reads them back (§5).

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
  the broker's breaker on that instance (README "Circuit breaker"); health polling catches it when its `/status`
  stops answering within 2 s.
- **`topics` after a restart** (`4.0.0`): the record is rebuilt from the instance's next `PUT`, so its `topics` are
  back only when that `PUT` carries them. An instance that sends `topics` with every heartbeat loses nothing.
- **Keep-alive** (`4.0.1`, #156): an idle connection stays open 120 s, longer than the clients' own pool idle
  timeouts (Go 90 s, .NET 60 s, httpx 5 s), so the client closes it first. `4.0.0` used uvicorn's default of 5 s,
  the heartbeat interval: a heartbeat sent on a pooled connection just as it closed got no answer
  (`sd.heartbeat_failed` with `ReadError`, `connection reset by peer` or `HttpRequestException`, and the broker's
  `sd.refresh`), a few per instance per 30 minutes; three in a row would have expired a healthy instance.

## 10. Lab 4 contract notes

`4.0.0` follows the Lab 4 contract (#105): README "Service Discovery", "Logging", "Logs download", "Circuit breaker"
and "Monitoring" describe `topics` in the registration and on the record, `load` and `last_checked_at`, `?topic=` on
the list, `GET /api/v1/topics`, `GET /api/v1/instances/prometheus`, `GET /metrics`, `POST /api/v1/alerts` with the
`dead_letter` kind and the `alert.received` log event, `message-broker` as a known `service_name`, and the broker as
the mark-down's only caller (`marked_down_by: broker`). No divergence is left. Beyond the contract:

1. **Mark-down naming.** `4.0.0` records every mark-down as `marked_down_by: broker` and its alert as "marked down by
   the broker", whoever calls (`3.0.0` logged a Gateway mark-down as `gateway`). Since Gateway `4.0.0` no longer calls
   it, this shows only for a mark-down sent by hand (Postman, `curl`).
2. **No API schema.** `/openapi.json` answers `404` from `4.0.0`; the contract never named it.
