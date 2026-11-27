# CLAUDE.md

## What this repo is

This is the **Common Public Repository (CPR)** for Team 16's distributed-systems course project,
_"Student ID, please"_ — a Discord-moderation game decomposed into 8 microservices. This repo itself
contains **no service source code**. It is documentation plus git submodules pointing at each
service's own private repository.

8 services, 2 per team member, plus the shared Gateway (Lab 2, Python), Service Discovery
(`service-discovery-service`, Lab 3, Python, owned by vvtttvv), the Message Broker
(`message-broker-service`, Lab 4, Python, owned by vvtttvv) and the ETL Service (`etl-service`,
Lab 5, Python, owned by vvtttvv); ownership and access rules are in
`.claude/rules/submodule-management.md`.

### Check for a service-specific CLAUDE.md

A given submodule may have its own `CLAUDE.md` with instructions specific to that service. It will not exist for
every service, and you may not have access to the submodule at all — check for it before assuming
it's there, and if present, follow it in addition to this file for work inside that submodule:

- @applicant-service/CLAUDE.md
- @credential-service/CLAUDE.md
- @discord-DMs-service/CLAUDE.md
- @etl-service/CLAUDE.md
- @gateway-service/CLAUDE.md
- @message-broker-service/CLAUDE.md
- @moderation-service/CLAUDE.md
- @player-service/CLAUDE.md
- @server-moderation-session-service/CLAUDE.md
- @server-rules-service/CLAUDE.md
- @service-discovery-service/CLAUDE.md
- @university-record-service/CLAUDE.md

Because of this, **the authoritative source of truth for cross-service behavior is `README.md` at
the repo root**, not any individual submodule. When working on a service you own, treat `README.md`'s
"Service Boundaries" and "Communication Contract" sections as the contract you must satisfy — the
submodule's own README documents only its own slice of that same contract for local reference.
`docs/*.md` (present only for services with a published integration reference) go deeper than the
root README for that one service: full HTTP API, config, edge cases, and divergences from the
contract.

## Commands

This repo has no build/lint/test of its own — there is nothing to compile here. The only commands
relevant at this level:

```bash
git submodule update --init --recursive   # pull the submodules you have access to
```

Running the stack (all 8 services and their databases, from published
Docker Hub images only — `docker-compose.yml` never uses `build:`; image tags and host ports are
listed in the README "Deployments" table):

```bash
docker network create student-id-net   # once
cp .env.example .env                   # fill in real values first
docker compose up -d
```

Build/lint/test commands for an individual service live in that service's own submodule README —
consult it directly once its content is checked out.

## Architecture

### Service boundary rule

Data ownership is strict: for every piece of state exactly one service is the source of truth and
the only writer. Every other service reads it via that owner's API (a request through the Message
Broker) or subscribes to its events — **never** direct database access, and **no cross-service
database**. The one exception (Lab 5) is the ETL Service, which reads every service database
read-only as `etl_reader`, from a standby, to load the data warehouse; no business flow may depend
on it, and `etl_reader` is never granted a secret (password hashes, emails, message text, audit
snapshots, tickets). See "Service Boundaries" and "Data Management" in `README.md` for the full
per-service ownership table and the reasoning.

### The three applicant-data services share identity via an event, not RPC

`applicant-service`, `credential-service`, and `university-record-service` each own a distinct
category of the same applicant (identity / documents / hidden institutional records). Any one of
them may be the first to meet a new applicant; whichever is contacted first generates the shared
`applicant_id` and publishes `applicant.initialized` to `events.applicant.initialized` on the
Message Broker; the other two, subscribed to it, create their own record under that same
`applicant_id`, populated only with the fields relevant to them. This is the pattern to follow for
any change touching applicant creation — the event is the only interaction allowed between these
three services; never add a request (read or write) between them.

### Moderation Service is the only service that reads from everyone

`moderation-service` is the sole consumer that calls Applicant, Credential, University Record (in
parallel), Session, and Server Rules to compute a verdict. If you're touching any of those five
services' read APIs, check `README.md`'s per-service "Consumed/Exposed API endpoints" sections —
Moderation's calling contract is the one most likely to be affected by a breaking change.

### Communication rules (pick the right one when adding an interaction)

A client reaches a service only through the Gateway, as REST `{gateway}/api/v1/<prefix>/...`
(README "Gateway"). From Lab 4 everything behind the Gateway travels through the Message Broker over
gRPC (`shared/broker.proto`, README "Message Broker"): the Gateway and every service send their
requests and publish their events to the broker and never address another service or instance.
Never configure a service with another service's own address. The exceptions: Service Discovery
(Lab 3) — instances register, heartbeat and deregister with it directly at `SERVICE_DISCOVERY_URL`,
it polls their `GET /status` and fetches their `GET /logs` directly, and it checks `X-Service-Token`
itself (README "Service Discovery"); and the ETL Service (Lab 5), which reads the service databases.

1. **Request** when the caller needs an answer now (e.g. Session fetching the ruleset before a shift starts): REST at the Gateway for a client, a `Request` on the broker's `requests.<prefix>` queue between components.
2. **Event** when something happened and others should know, no reply needed (e.g. `session.ended`). The producer writes the envelope to its outbox in the same transaction as the change, and a relay publishes it to `events.<event_type>` on the broker, which keeps one queue per subscribed service (README "Event delivery"). Delivery is at least once and unordered — every consumer dedupes by `event_id` and acks only after applying the event.
3. **Saga** (Lab 5) when several services must change their databases together or not at all — today only the start of a shift, saga `shift.start`. The broker coordinates it: it calls each participant's `POST /api/v1/saga-steps/{step}` as a request and, when a step fails, the `.../compensate` routes of the steps already done, in reverse order. Participants are idempotent by `(saga_id, step)`. No two-phase commit anywhere (README "Sagas").
4. **WebSocket** only for pushing to a connected client — used exclusively by `discord-DMs-service`; no other service holds client connections. The Gateway only negotiates it (`POST /ws-tickets` returns a URL with a one-time ticket); the client then connects to Discord DMs directly.

Full event catalog, envelope shape, and the complete "every arrow in the diagram" table are in
`README.md` under "Communication Patterns" and "Communication Contract".

### Identity model is shared and normative

Student ID format, admission-year/study-year derivation, university email assignment rules, and
which profile fields each `university_status` carries are defined once in `README.md`'s "Identity
model" section and apply identically across Applicant, Credential, and University Record. If you
own one of these three services, don't reinvent these rules locally — a divergence here silently
turns an honest applicant into an apparent liar in another service. `REFERENCE_YEAR` (currently
`2026`) must be configured identically in all three and in Moderation. The course catalog is
`shared/courses.json` in this repo (courses are identified by `code`, `^[A-Z]{2,4}$`); the three
services ship byte-identical copies of it.

### Per-service tech stack

Six services (Player, Session, Applicant, Credential, Moderation, Discord DMs) are Go + Gin. Two
(Server Rules, University Record) are C# + ASP.NET Core. The Gateway, Service Discovery, the Message
Broker and the ETL Service are Python + FastAPI (the broker adds `grpcio`). All services expose the
same contract shape regardless of language: REST + JSON under `/api/v1`, snake_case fields, the
same error envelope, `408`/`429` for the task timeout and concurrent limit, and the same gRPC
contract with the broker (`shared/broker.proto`) for requests and events. Auth lives in the Gateway: it validates
`Authorization: Bearer <jwt>` (issued by Player Service; from Lab 5 with a `jti` that logout
revokes), strips it, and passes the player on as `X-Player-Id` — services validate no token.
Between components the one shared `SERVICE_TOKEN` travels as the broker's `x-service-token` gRPC
metadata, never as a request header; only the routes called directly inside the network check
`X-Service-Token` themselves: Service Discovery's, every `GET /logs`, the admin and dev routes, the
broker's and the ETL's `/api/v1` routes and the Gateway's `GET /cache/stats`. Images are versioned `<lab>.x.y`
from a `VERSION` file (Lab 2 = `2.x.y`, Lab 3 = `3.x.y`, Lab 4 = `4.x.y`, Lab 5 = `5.x.y`).
Database-per-service, engine chosen per service, and from Lab 5 each one runs as a primary and two
replicas (see the Databases table in `README.md` for which engine and why).
