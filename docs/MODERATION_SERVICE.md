# Moderation Service - Integration Reference

Integration reference of the **Moderation Service**, one of the eight microservices of the FAF Discord
Moderation game **"Student ID, please"**. This service owns the admission decision for every applicant:
the Moderator submits accept / reject / flag / ban, the service works out what the correct decision
would have been from the university records and the server rules, compares the two, records the
verdict with a penalty and publishes it for the session.

Owner: Racovita Dumitru. Source: the private `moderation-service` repository, linked as a submodule of this CPR.

> **Audience:** developers of the other services of *"Student ID, please"* (Team 16, FAF.PAD21.1), or the gateway.
> Copied from the service's own README at `v0.1.0`; relative paths below refer to the `moderation-service/` submodule.
> Where the implementation diverges from the CPR contract, the divergence is called out in the last section.

## Integration card

| | |
| --- | --- |
| Language / framework | Go 1.25, Gin |
| Container port | `8085` (host `8085`) |
| Base path | `/api/v1` |
| Health | `GET /health` (liveness), `GET /health/ready` (readiness: postgres, rabbitmq, pending outbox events) |
| Database | PostgreSQL 17, `moderation_db` (own container, host port `5436`) |
| Broker | RabbitMQ, exchange `student-id.events`; optional, empty `RABBITMQ_URL` keeps events in the outbox |
| Publishes | `decision.recorded` |
| Consumes | nothing |
| Calls | Server Moderation Session, Applicant, Credential, University Record, Server Rules; each one is replaced by a built-in mock when its URL is empty |
| Authentication | `Authorization: Bearer <jwt>` for players (signature not verified, `sub` is the player id); `X-Service-Token` for `/admin/*` and `/dev/*` |
| Docker image | `dmracovit/moderation-service:0.1.0` |

## Running it

Requirements: Docker with Compose v2. For development and tests: Go 1.25.

```bash
./scripts/run.sh            # build the image, start postgres + service, wait until /health/ready answers
./scripts/run.sh --broker   # same, plus a local RabbitMQ (only when the team broker is not running)
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
decisions of an earlier shift, so the ban scenario works out of the box.

### From the published image only

```bash
docker network create student-id-net   # once
docker run -d --name moderation-service --network student-id-net -p 8085:8085 \
  -e DATABASE_URL="postgres://moderation_user:<password>@<postgres-host>:5432/moderation_db?sslmode=disable" \
  -e SERVICE_TOKEN="<shared-secret>" -e DEV_ENDPOINTS=true -e SEED_ON_START=true \
  dmracovit/moderation-service:0.1.0
```

`moderation-service/deployments/docker-compose.team.yml` is the same stack without `build:`, the fragment merged into
the team-wide compose in the CPR.

## Configuration

Everything comes from the environment and is validated at startup; a bad value exits immediately
naming the variable.

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | - | yes | PostgreSQL connection string (pgx format) |
| `SERVICE_TOKEN` | - | yes | Shared secret: required on `/api/v1/admin/*` and `/api/v1/dev/*`, sent as `X-Service-Token` to peers |
| `APP_PORT` | `8085` | no | HTTP port |
| `APP_ENV` | `local` | no | `local` / `test` / `development` = text logs and Gin debug; anything else = JSON logs, release mode |
| `LOG_LEVEL` | `info` | no | `debug`, `info`, `warn`, `error` |
| `DEV_ENDPOINTS` | `false` | no | Mounts `/api/v1/dev/*` (token mint, mock editing). Keep `false` in shared deployments |
| `SEED_ON_START` | `false` | no | Seed demo data when the ban list is empty |
| `MIGRATE_ON_START` | `true` | no | Apply embedded migrations at startup |
| `REFERENCE_YEAR` | `2026` | no | The calendar year treated as "now" when computing `years_enrolled`; must match the applicant-data services |
| `SESSION_URL`, `APPLICANT_URL`, `CREDENTIAL_URL`, `UNIVERSITY_RECORD_URL`, `RULES_URL` | empty | no | Base URL of each peer. Empty = the built-in mock of that peer |
| `UPSTREAM_TIMEOUT` | `5s` | no | Timeout per peer call |
| `RABBITMQ_URL` | empty | no | Empty disables messaging; events accumulate in the outbox and are published once a broker is configured |
| `RABBITMQ_EXCHANGE` | `student-id.events` | no | Must match every other service |
| `OUTBOX_POLL_INTERVAL` / `OUTBOX_BATCH_SIZE` | `500ms` / `50` | no | Outbox relay |
| `DB_CONNECT_TIMEOUT`, `DB_MAX_CONNS`, `HTTP_READ_TIMEOUT`, `HTTP_WRITE_TIMEOUT`, `SHUTDOWN_TIMEOUT` | `30s`, `10`, `10s`, `10s`, `10s` | no | Tuning |

## HTTP API

Contract endpoints (see the contract section below for payloads):

| Method | Path | Consumed by | Auth |
| --- | --- | --- | --- |
| `POST` | `/api/v1/decisions` | Client (the Moderator) | player JWT |
| `GET` | `/api/v1/decisions?session_id=&applicant_id=&moderator_id=&limit=&offset=` | Client | player JWT |
| `GET` | `/api/v1/bans?q=&limit=&offset=` | Client | player JWT |

Extensions beyond the contract (the CRUD surface of Lab 1):

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/api/v1/decisions/{decision_id}` | One decision. Players never see the snapshot |
| `GET` | `/api/v1/admin/decisions/{decision_id}` | The same decision **with the snapshot** of the data behind the verdict. Service token only |
| `DELETE` | `/api/v1/admin/decisions/{decision_id}` | Removes a decision so a demo scenario can be replayed. Decisions are immutable for players |
| `POST` | `/api/v1/admin/bans` | `{ "student_id": "FAF20101", "name": "..." }` adds a ban list entry by hand |
| `DELETE` | `/api/v1/admin/bans/{ban_id}` | Removes a ban list entry |
| `GET` | `/api/v1/dev/tokens?player_id=` | Mints an unsigned player JWT for Postman (`DEV_ENDPOINTS=true`) |
| `GET` / `PUT` | `/api/v1/dev/mock/sessions[/{session_id}]` | Read or replace the mock session object |
| `POST` | `/api/v1/dev/mock/sessions/{session_id}/current-applicant` | `{ "applicant_id": "..." }` points the mock session at another applicant |
| `GET` / `PUT` | `/api/v1/dev/mock/applicants[/{applicant_id}]` | Read or replace a mock applicant (`profile`, `documents`, `records`) |

Error codes: `VALIDATION_ERROR` (400), `UNAUTHENTICATED`, `INVALID_SERVICE_TOKEN` (401),
`NOT_MODERATOR`, `SERVICE_TOKEN_REQUIRED` (403), `SESSION_NOT_FOUND`, `APPLICANT_NOT_FOUND`,
`RULESET_NOT_FOUND`, `DECISION_NOT_FOUND`, `BAN_NOT_FOUND`, `NOT_FOUND` (404), `SESSION_NOT_ACTIVE`,
`NOT_CURRENT_APPLICANT`, `ALREADY_DECIDED`, `MOCKS_DISABLED` (409), `GRANTED_CHANNELS_REQUIRED`,
`GRANTED_CHANNELS_NOT_ALLOWED` (422), `DEPENDENCY_UNAVAILABLE`, `INTERNAL_ERROR` (500). All use the
shared envelope `{ "error": { "code", "message", "details" } }`.

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
`no-previously-banned`, `first-years-general-only`, `teachers-channel`). Mixed mode works: point
`APPLICANT_URL`, `CREDENTIAL_URL`, `RULES_URL` and `UNIVERSITY_RECORD_URL` at the real services and
leave `SESSION_URL` empty until Server Moderation Session Service exists.

The Postman collection in `postman/` of this repository runs every scenario with assertions: set `base_url` and
`service_token`, run the folders in order.

## How a verdict is computed

1. `GET /sessions/{id}`: the session must be `active`, the caller its Moderator, the applicant the current one. `ruleset_version` is read from it.
2. Applicant, Credential and University Record are called in parallel; the ban list is checked for the claimed student ID (or the name when there is none).
3. Facts are built **from the records**, never from the claims: `university_status`, `major`, `year`, `currently_enrolled` from the enrollment list and email groups, `years_enrolled` from the admission year encoded in the student ID (`{MAJOR}{yy}{g}{nn}`), `previously_banned` from the ban list.
4. Server Rules evaluates the facts against the shift's ruleset version.
5. Expected action, first match wins: a `forged` document or records that belong to another person = `ban`; `admitted: false` or an `expired` document = `reject`; an `inconsistent` or `incomplete` document = `flag`; otherwise `accept` with `allowed_channels`.
6. `is_correct` compares the Moderator's action (and, for `accept`, the granted channels) with the expected one. Penalty matrix (expected in rows, actual in columns):

| | accept | reject | flag | ban |
| --- | --- | --- | --- | --- |
| **accept** | 0 (5 with wrong channels) | 10 | 5 | 15 |
| **reject** | 20 | 0 | 5 | 5 |
| **flag** | 15 | 5 | 0 | 10 |
| **ban** | 30 | 10 | 15 | 0 |

7. Decision, snapshot, ban list entry (for `ban`) and the `decision.recorded` outbox event are written in one transaction; the relay publishes the event with publisher confirms. Delivery is at-least-once; consumers deduplicate on `event_id`.

## Storage

PostgreSQL `moderation_db`: `decisions` (one row per applicant per session, immutable, with a `snapshot` jsonb column), `bans` (filled by ban decisions, searchable by student ID and name), `outbox` (events waiting for the broker). Migrations are embedded and applied at startup under an advisory lock.

## Tests

```bash
go test ./... -cover
TEST_DATABASE_URL=postgres://moderation_user:<pw>@localhost:5436/moderation_db?sslmode=disable go test ./internal/store/
```

Domain, orchestration and HTTP layers are unit-tested against the in-memory repository and the mock
peers. The store test runs against a real PostgreSQL when `TEST_DATABASE_URL` is set and is skipped
otherwise.

## Divergences from the CPR contract

| # | Divergence | Who is affected |
| --- | --- | --- |
| 1 | `GET /decisions/{decision_id}` and the `/admin/*` and `/dev/*` routes exist beyond the contract | gateway and auth: `/admin/*` and `/dev/*` must never be routed to players |
| 2 | `422 GRANTED_CHANNELS_NOT_ALLOWED` is answered when `granted_channels` is sent with an action other than `accept`; the contract only names `GRANTED_CHANNELS_REQUIRED` | the game client |
| 3 | The ban list lookup uses the claimed student ID when there is one, otherwise the exact name (case-insensitive) | Server Rules receives `previously_banned` computed this way |
| 4 | The penalty matrix above is this service's reading of "grows with how harmful the mistake is" | Server Moderation Session Service, which adds `penalty` to the session |

---

*Moderation Service is owned by Racovita Dumitru. See the service's own repository README for the full contract copy and the CHANGELOG.*
