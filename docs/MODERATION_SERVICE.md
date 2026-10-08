# Moderation Service - Integration Reference

Integration reference of the **Moderation Service**, one of the eight microservices of the FAF Discord
Moderation game **"Student ID, please"**. This service owns the admission decision for every applicant:
the Moderator submits accept / reject / flag / ban, the service works out what the correct decision
would have been from the university records and the server rules, compares the two, records the
verdict with a penalty and pushes it to the session.

Owner: Racovita Dumitru. Source: the private `moderation-service` repository, linked as a submodule of this CPR.

> **Audience:** developers of the other services of *"Student ID, please"* (Team 16, FAF.PAD21.1), or the Gateway.
> Copied from the service's own README at `v2.0.0`; relative paths below refer to the `moderation-service/` submodule.
> Where the implementation diverges from the CPR contract, the divergence is called out in the last section.

## Integration card

| | |
| --- | --- |
| Language / framework | Go 1.25, Gin |
| Container port | `8085` (host `8085` during Lab 2 development; the final stack publishes the Gateway only) |
| Base path | `/api/v1`; reached through the Gateway as `{gateway}/api/v1/moderation/...` |
| Health | `GET /health` (liveness), `GET /health/ready` (readiness: postgres, pending and parked event deliveries) |
| Database | PostgreSQL 17, `moderation_db` (own container, host port `5436`) |
| Events | `decision.recorded` is written to the outbox in the same transaction as the decision; the relay pushes it through the Gateway to `POST {gateway}/api/v1/session/events` with `X-Service-Token`, tracking the delivery per consumer. `GET /api/v1/admin/events` shows every event with its delivery state |
| Produces | `decision.recorded`, pushed to Server Moderation Session Service |
| Receives | nothing |
| Calls | Server Moderation Session, Applicant, Credential, University Record, Server Rules - all through the Gateway, with `X-Service-Token`; each one is replaced by a built-in mock when its URL is empty |
| Authentication | Checked by the Gateway, not here: player endpoints read the calling player from `X-Player-Id` (set by the Gateway after validating the player's JWT), `/admin/*` and `/dev/*` are forwarded by the Gateway only with the service token. The service validates no token |
| Task limits | `HTTP_REQUEST_TIMEOUT` (5 s) stops a task with `408 REQUEST_TIMEOUT`; `MAX_CONCURRENT_TASKS` (64) refuses the next task with `429 TOO_MANY_REQUESTS`; health endpoints exempt. See [Task timeout and concurrent task limit](#task-timeout-and-concurrent-task-limit) |
| Docker image | `dmracovit/moderation-service:2.0.0` and `:latest`, public on Docker Hub, linux/amd64 and linux/arm64; published by GitHub Actions on merge to `main` from the `VERSION` file (Lab 2 = `2.x.y`) |

## Running it

Requirements: Docker with Compose v2. For development and tests: Go 1.25.

```bash
./scripts/run.sh            # build the image, start postgres + service, wait until /health/ready answers
./scripts/run.sh --local    # run from source against the containerised postgres
./scripts/run.sh --test     # unit tests with coverage
./scripts/run.sh --logs     # follow the logs
./scripts/run.sh --down     # stop (add --volumes to drop the data)
```

On the first run the script creates `.env` from `.env.example` with generated secrets. `.env` is
gitignored and must never be committed.

Without Docker: `DATABASE_URL=... SERVICE_TOKEN=... go run ./cmd/moderationd`.

The service is ready when `GET http://localhost:8085/health/ready` answers `200`. With
`SEED_ON_START=true` (the default in compose) an empty database gets one ban list entry and two
decisions of an earlier shift, so the ban scenario works out of the box. With every peer URL empty
(the default of the development stack) the five peers are the built-in mocks, so the whole decision
flow - relay included - runs with nothing else installed.

### From the published image only

```bash
docker network create student-id-net   # once
docker run -d --name moderation-service --network student-id-net -p 8085:8085 \
  -e DATABASE_URL="postgres://moderation_user:<password>@<postgres-host>:5432/moderation_db?sslmode=disable" \
  -e SERVICE_TOKEN="<the stack's service token>" -e DEV_ENDPOINTS=true -e SEED_ON_START=true \
  -e SESSION_URL=http://gateway-service:8080/api/v1/session \
  -e APPLICANT_URL=http://gateway-service:8080/api/v1/applicant \
  -e CREDENTIAL_URL=http://gateway-service:8080/api/v1/credential \
  -e UNIVERSITY_RECORD_URL=http://gateway-service:8080/api/v1/university-record \
  -e RULES_URL=http://gateway-service:8080/api/v1/server-rules \
  dmracovit/moderation-service:latest
```

`moderation-service/deployments/docker-compose.team.yml` is the same stack without `build:`, the fragment merged into
the team-wide compose in the CPR.

## Configuration

Everything comes from the environment and is validated at startup; a bad value exits immediately
naming the variable.

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | - | yes | PostgreSQL connection string (pgx format) |
| `SERVICE_TOKEN` | - | yes | The stack's one `X-Service-Token`: sent on every call to a peer and on every event push. The Gateway checks it; this service does not check inbound tokens |
| `SESSION_URL`, `APPLICANT_URL`, `CREDENTIAL_URL`, `UNIVERSITY_RECORD_URL`, `RULES_URL` | empty | no | Where each peer's `/api/v1` lives: the Gateway plus the peer's prefix, e.g. `http://gateway-service:8080/api/v1/session`, `.../api/v1/applicant`, `.../api/v1/credential`, `.../api/v1/university-record`, `.../api/v1/server-rules`. Empty = the built-in mock of that peer |
| `HTTP_REQUEST_TIMEOUT` | `5s` | no | Task timeout: a request running longer is stopped and answers `408 REQUEST_TIMEOUT`. `5s` or `5`, like the other services. The Gateway allows 10 s, so the outer layer never gives up first |
| `MAX_CONCURRENT_TASKS` | `64` | no | Concurrent task limit: the request above it is refused at once with `429 TOO_MANY_REQUESTS` |
| `UPSTREAM_TIMEOUT` | `4s` | no | Timeout of one call to a peer, event pushes included. Must stay below `HTTP_REQUEST_TIMEOUT`, so the service can still answer `500 DEPENDENCY_UNAVAILABLE` before its own deadline |
| `RELAY_INTERVAL` | `1s` | no | How often the outbox relay looks for events to push |
| `APP_PORT` | `8085` | no | HTTP port |
| `APP_ENV` | `local` | no | `local` / `test` / `development` = text logs and Gin debug; anything else = JSON logs, release mode |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `/api/v1/dev/*` (mock editing, events the mock Session accepted). Keep `false` in shared deployments |
| `SEED_ON_START` | `false` | no | Seed demo data when the ban list is empty |
| `MIGRATE_ON_START` | `true` | no | Apply embedded migrations at startup |
| `REFERENCE_YEAR` | `2026` | no | The calendar year treated as "now" when computing `years_enrolled`; must match the applicant-data services |
| `DB_CONNECT_TIMEOUT`, `DB_MAX_CONNS`, `HTTP_READ_TIMEOUT`, `HTTP_WRITE_TIMEOUT`, `SHUTDOWN_TIMEOUT` | `30s`, `10`, `10s`, `10s`, `10s` | no | Tuning; `HTTP_WRITE_TIMEOUT` must stay above `HTTP_REQUEST_TIMEOUT` |

## HTTP API

Contract endpoints (see the contract section below for payloads). "Player" means the Gateway
validated the player's JWT and forwarded the request with `X-Player-Id`; a request without that
header answers `401 UNAUTHENTICATED`.

| Method | Path | Consumed by | Who may call |
| --- | --- | --- | --- |
| `POST` | `/api/v1/decisions` | Client (the Moderator) | player |
| `GET` | `/api/v1/decisions?session_id=&applicant_id=&moderator_id=&limit=&offset=` | Client | player |
| `GET` | `/api/v1/bans?q=&limit=&offset=` | Client | player |

Extensions beyond the contract (the CRUD surface of Lab 1 and the demo tooling). The Gateway forwards
`/admin/*` and `/dev/*` only with the service token, so they are never reachable with a player token:

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/api/v1/decisions/{decision_id}` | One decision (player). Players never see the snapshot |
| `GET` | `/api/v1/admin/decisions/{decision_id}` | The same decision **with the snapshot** of the data behind the verdict |
| `GET` | `/api/v1/admin/events?limit=&offset=` | The outbox, oldest first: every `decision.recorded` envelope with the delivery state per consumer (see [Event delivery](#event-delivery)) |
| `DELETE` | `/api/v1/admin/decisions/{decision_id}` | Removes a decision so a demo scenario can be replayed. Decisions are immutable for players |
| `POST` | `/api/v1/admin/bans` | `{ "student_id": "FAF20101", "name": "..." }` adds a ban list entry by hand |
| `PATCH` | `/api/v1/admin/bans/{ban_id}` | `{ "name": "...", "student_id": "..." }` edits a ban list entry; an absent field keeps its value, an empty `student_id` clears it |
| `DELETE` | `/api/v1/admin/bans/{ban_id}` | Removes a ban list entry |
| `GET` / `PUT` | `/api/v1/dev/mock/sessions[/{session_id}]` | Read or replace the mock session object (`DEV_ENDPOINTS=true`) |
| `POST` | `/api/v1/dev/mock/sessions/{session_id}/current-applicant` | `{ "applicant_id": "..." }` points the mock session at another applicant |
| `GET` / `PUT` | `/api/v1/dev/mock/applicants[/{applicant_id}]` | Read or replace a mock applicant (`profile`, `documents`, `records`) |
| `GET` | `/api/v1/dev/mock/events` | The envelopes the mock Session accepted from the relay, oldest first |
| `GET` | `/api/v1/dev/slow?ms=` | Answers after `ms` milliseconds (at most 60 000), to demonstrate `408` and `429` |

Error codes: `VALIDATION_ERROR` (400; also when `granted_channels` is sent with an action other than
`accept`, which the contract says must be left out), `UNAUTHENTICATED` (401), `NOT_MODERATOR` (403),
`SESSION_NOT_FOUND`, `APPLICANT_NOT_FOUND`, `RULESET_NOT_FOUND`, `DECISION_NOT_FOUND`, `BAN_NOT_FOUND`,
`NOT_FOUND` (404), `METHOD_NOT_ALLOWED` (405), `REQUEST_TIMEOUT` (408), `SESSION_NOT_ACTIVE`,
`NOT_CURRENT_APPLICANT`, `ALREADY_DECIDED` (409), `MOCKS_DISABLED` (409, dev routes only),
`GRANTED_CHANNELS_REQUIRED` (422), `TOO_MANY_REQUESTS` (429), `DEPENDENCY_UNAVAILABLE`, `INTERNAL_ERROR`
(500). All use the shared envelope
`{ "error": { "code", "message", "details" } }`. `DEPENDENCY_UNAVAILABLE` names the failed peer in
`details.dependency`; it covers a peer that is down or answers `5xx`, the Gateway answering `408`,
`429` or `502` for it, and a `404 NOT_FOUND` for a route nobody serves (a wrong prefix or base URL) -
a peer's own `404` (`SESSION_NOT_FOUND`, `APPLICANT_NOT_FOUND`, `RULESET_NOT_FOUND`) keeps its code.

## Mocks and demo fixtures

Every peer sits behind an interface. A peer with an empty URL is served by an in-memory mock that
ships with eight applicants, one per scenario, and one active session whose Moderator is
`8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11`:

| Applicant | Scenario | Expected action |
| --- | --- | --- |
| `5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13` | honest third-year FAF student | `accept`, channels `general`, `dark-memes`, `groapa` |
| `6e3d9f5b-8c2a-4d4e-af7b-1c9a3e5d7f24` | outsider with a forged card, no records | `ban` |
| `7f4ea06c-9d3b-4e5f-b08c-2daa4f6e8a35` | real student, expired card | `reject` |
| `8a5fb17d-ae4c-4f60-919d-3ebb507f9b46` | real student, incomplete enrollment confirmation | `flag` |
| `9b60c28e-bf5d-4a71-a2ae-4fcc618a0c57` | real student who is on the ban list | `reject` |
| `a071d39f-c06e-4b82-b3bf-50dd729b1d68` | claims someone else's student ID | `ban` |
| `b182e4a0-d17f-4c93-84c0-61ee83ac2e79` | staff member | `accept`, channels `general`, `teachers` |
| `c293f5b1-e280-4da4-95d1-72ff94bd3f8a` | honest first-year | `accept`, channel `general` |

The mock Server Rules implements the example ruleset of the contract (`only-faf-or-teachers`,
`no-previously-banned`, `first-years-general-only`, `teachers-channel`). The mock Session also
accepts events the way the real `POST /api/v1/events` does: a relayed `decision.recorded` marks the
mock session's current applicant as decided, counts the application and adds the penalty, and a
repeated `event_id` is reported as a duplicate. `GET /api/v1/dev/mock/events` lists what it accepted.

Mixed mode works: point `APPLICANT_URL`, `CREDENTIAL_URL`, `RULES_URL`, `UNIVERSITY_RECORD_URL` and
`SESSION_URL` at the real services one by one, through the Gateway
(`http://gateway-service:8080/api/v1/<prefix>`); the team compose in the CPR points all five at it.

The Postman collection in `postman/` of this CPR runs every scenario with assertions through the Gateway: set
`base_url` to the Gateway (`http://localhost:8080`) and `service_token` to the stack's token, run the
folders in order. The Setup folder resets the session's decisions so the run can be repeated, and
the Read back folder checks that the relay delivered the event to the mock Session. A request names
its player in `X-Player-Id`, and the collection's pre-request script turns that into the player JWT the
Gateway expects (`Authorization: Bearer`, signed with `jwt_secret` = the Gateway's `JWT_SECRET`); the
Gateway then sets `X-Player-Id` from the token for the service.

## How a verdict is computed

1. `GET /sessions/{id}`: the session must be `active`, the caller its Moderator, the applicant the current one. `ruleset_version` is read from it.
2. Applicant, Credential and University Record are called in parallel; the ban list is checked for the claimed student ID (an applicant who claims none has nothing to look up).
3. Facts are built **from the records**, never from the claims (courses are compared by `code`, the contract's course identifier): `university_status`, `major`, `year`, `currently_enrolled` from the enrollment list and email groups, `years_enrolled` from the admission year encoded in the student ID (`{MAJOR}{yy}{g}{nn}`), `previously_banned` from the ban list.
4. Server Rules evaluates the facts against the shift's ruleset version.
5. Expected action, first match wins: a `forged` document or records that belong to another person = `ban`; `admitted: false` or an `expired` document = `reject`; an `inconsistent` or `incomplete` document = `flag`; otherwise `accept` with `allowed_channels`.
6. `is_correct` compares the Moderator's action (and, for `accept`, the granted channels) with the expected one. The contract fixes the rule for the penalty - 0 for a correct decision, growing with how harmful the mistake is, letting in someone who should have been banned costing the most - and leaves the numbers to this service. These are the numbers (expected in rows, actual in columns):

| | accept | reject | flag | ban |
| --- | --- | --- | --- | --- |
| **accept** | 0 (5 with wrong channels) | 10 | 5 | 15 |
| **reject** | 20 | 0 | 5 | 5 |
| **flag** | 15 | 5 | 0 | 10 |
| **ban** | 30 | 10 | 15 | 0 |

7. Decision, snapshot, ban list entry (for `ban`) and the `decision.recorded` event with one pending delivery per consumer are written in one transaction, and the service replies. The relay then pushes the event to Session; consumers deduplicate on `event_id`.

## Event delivery

The CPR "Event delivery" section, as implemented here:

- **Outbox.** The envelope (`event_id`, `event_type`, `occurred_at`, `producer`, `version`, `payload`) is stored in `outbox` inside the decision's transaction, so an event never exists without its decision, nor the reverse. One row per consumer of the event type goes to `outbox_deliveries` (`decision.recorded` has one consumer, `session`).
- **Relay.** A background loop (every `RELAY_INTERVAL`) takes the pending deliveries whose time has come and posts the envelope, unchanged, to `POST {SESSION_URL}/events` with `X-Service-Token`; through the Gateway that is `POST {gateway}/api/v1/session/events`. One push per delivery per pass, never in parallel for the same event.
- **Answers.** `2xx` (`{ "event_id", "duplicate" }`) marks the delivery `delivered`, and the event `published_at` once every consumer has accepted it. `422 INVALID_EVENT` marks it `parked`: a retry cannot succeed, the reason stays in `last_error` and the operator sees it in `GET /admin/events` and in `/health/ready` (`parked_events`). Anything else - the Gateway's `408`, `429`, `502`, a `5xx`, a timeout, a refused connection - schedules a retry after 2, 4, 8, 16 and then 30 seconds between attempts, for as long as it takes.
- **At-least-once.** A crash between a successful push and the bookkeeping sends the event again; Session answers `duplicate: true` and changes nothing.

One item of `GET /api/v1/admin/events`:

```json
{
  "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "decision.recorded",
  "event": { "event_id": "...", "event_type": "decision.recorded", "occurred_at": "...", "producer": "moderation-service", "version": 1, "payload": { "decision_id": "...", "penalty": 30 } },
  "created_at": "2026-10-07T18:14:00Z",
  "published_at": "2026-10-07T18:14:01Z",
  "deliveries": [
    { "consumer": "session", "status": "delivered", "attempts": 1, "next_attempt_at": null, "last_status": 200, "last_error": null, "delivered_at": "2026-10-07T18:14:01Z" }
  ]
}
```

## Task timeout and concurrent task limit

Every inbound request under `/api/v1` is one task, as the CPR contract defines it; `GET /health` and
`GET /health/ready` are not, so a busy service is not restarted by its orchestrator. The relay is
background work and is not counted either; it backs off on its own.

- **Timeout.** The request's context expires after `HTTP_REQUEST_TIMEOUT` (5 s). Every database query and every call to a peer runs under that context, so the task is cancelled where it is - a transaction in progress is rolled back, a peer call is abandoned - and the answer is `408 REQUEST_TIMEOUT` with `details.timeout_ms`. Nothing was changed. The Gateway's own timeout is 10 s and a call to a peer gives up after `UPSTREAM_TIMEOUT` (4 s), so the outer layer never gives up first.
- **Concurrent limit.** At most `MAX_CONCURRENT_TASKS` (64) requests are in progress; the next one is refused before any work with `429 TOO_MANY_REQUESTS`, `Retry-After: 1` and `details.limit`. Nothing was changed.
- **Demonstration.** With `DEV_ENDPOINTS=true`, `GET /api/v1/dev/slow?ms=7000` answers `408` after 5 s, and 64 parallel `GET /api/v1/dev/slow?ms=3000` make the 65th request answer `429`. The Postman collection's last folder does exactly this.

## Storage

PostgreSQL `moderation_db`: `decisions` (one row per applicant per session, immutable, with a `snapshot` jsonb column), `bans` (filled by ban decisions, searchable by student ID and name), `outbox` (the `decision.recorded` envelopes, oldest first) and `outbox_deliveries` (the state of every event for every consumer). Migrations are embedded and applied at startup under an advisory lock.

## Docker image, versioning and CI

The image tag is the single line of the `VERSION` file; its MAJOR is the laboratory number, so every
Lab 2 release is `2.x.y` (`2.0.0` now). Images are never pushed by hand:

- `moderation-service/.github/workflows/ci.yml`: on every pull request into `dev` or `main`, and on every push to a work branch, runs `go vet` and the tests against a PostgreSQL service and builds the image without pushing it.
- `moderation-service/.github/workflows/release.yml`: on every push to `main` (a merge of `dev`), runs the tests and, only if they pass, builds `linux/amd64` and `linux/arm64` and pushes `dmracovit/moderation-service:<VERSION>` and `:latest`. It stops when `VERSION` is not `MAJOR.MINOR.PATCH`.

Repository secrets required, never committed: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker
Hub access token with write access). Release flow: bump `VERSION` and the CHANGELOG in a PR into
`dev`, then merge `dev` into `main`.

## Tests

```bash
go test ./... -cover
TEST_DATABASE_URL=postgres://moderation_user:<pw>@localhost:5436/moderation_db?sslmode=disable go test ./internal/store/
```

Domain, orchestration, relay and HTTP layers are unit-tested against the in-memory repository and the
mock peers; the HTTP clients against a local test server, including the Gateway's answers. The store
test runs against a real PostgreSQL when `TEST_DATABASE_URL` is set and is skipped otherwise.

## Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | `GET /decisions/{decision_id}` and the `/admin/*` and `/dev/*` routes exist beyond the contract (the Lab 1 CRUD requirement and the demo tooling); nothing in the contract depends on them, and `PATCH /admin/bans/{ban_id}` edits only the ban list, decisions stay immutable | the Gateway forwards `/admin/*` and `/dev/*` only with the service token |

---

*Moderation Service is owned by Racovita Dumitru. See the service's own repository README for the full contract copy and the CHANGELOG.*
