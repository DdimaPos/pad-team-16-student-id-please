# CLAUDE.md

## What this repo is

This is the **Common Public Repository (CPR)** for Team 16's distributed-systems course project,
_"Student ID, please"_ — a Discord-moderation game decomposed into 8 microservices. This repo itself
contains **no service source code**. It is documentation plus git submodules pointing at each
service's own private repository.

8 services, 2 per team member, plus the shared Gateway (Lab 2, Python); ownership and access rules
are in `.claude/rules/submodule-management.md`.

### Check for a service-specific CLAUDE.md

A given submodule may have its own `CLAUDE.md` with instructions specific to that service. It will not exist for
every service, and you may not have access to the submodule at all — check for it before assuming
it's there, and if present, follow it in addition to this file for work inside that submodule:

- @applicant-service/CLAUDE.md
- @credential-service/CLAUDE.md
- @discord-DMs-service/CLAUDE.md
- @gateway-service/CLAUDE.md
- @moderation-service/CLAUDE.md
- @player-service/CLAUDE.md
- @server-moderation-session-service/CLAUDE.md
- @server-rules-service/CLAUDE.md
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

Running the stack (all 8 services, their databases and the shared RabbitMQ broker, from published
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
the only writer. Every other service reads it via that owner's REST API or subscribes to its
events — **never** direct database access, and **no cross-service database**. See "Service
Boundaries" and "Data Management" in `README.md` for the full per-service ownership table and the
reasoning.

### The three applicant-data services share identity via an event, not RPC

`applicant-service`, `credential-service`, and `university-record-service` each own a distinct
category of the same applicant (identity / documents / hidden institutional records). Any one of
them may be the first to meet a new applicant; whichever is contacted first generates the shared
`applicant_id` and publishes `applicant.initialized` (exchange `student-id.events`, routing key
`applicant.initialized`). The other two subscribe and create their own record under that same
`applicant_id`, populated only with the fields relevant to them. This is the pattern to follow for
any change touching applicant creation — never add a direct call between these three services.

### Moderation Service is the only service that reads from everyone

`moderation-service` is the sole consumer that calls Applicant, Credential, University Record (in
parallel), Session, and Server Rules to compute a verdict. If you're touching any of those five
services' read APIs, check `README.md`'s per-service "Consumed/Exposed API endpoints" sections —
Moderation's calling contract is the one most likely to be affected by a breaking change.

### Communication rules (pick the right one when adding an interaction)

1. **REST** when the caller needs an answer now (e.g. Session fetching the ruleset before a shift starts).
2. **RabbitMQ event** (topic exchange `student-id.events`) when something happened and others should know, no reply needed (e.g. `session.ended`). Events may be delivered more than once — every consumer must dedupe by `event_id`.
3. **WebSocket** only for pushing to a connected client — used exclusively by `discord-DMs-service`; no other service holds client connections.

Full event catalog, envelope shape, and the complete "every arrow in the diagram" table are in
`README.md` under "Communication Patterns" and "Communication Contract".

### Identity model is shared and normative

Student ID format, admission-year/study-year derivation, university email assignment rules, and
which profile fields each `university_status` carries are defined once in `README.md`'s "Identity
model" section and apply identically across Applicant, Credential, and University Record. If you
own one of these three services, don't reinvent these rules locally — a divergence here silently
turns an honest applicant into an apparent liar in another service. `REFERENCE_YEAR` (currently
`2026`) must be configured identically in all three.

### Per-service tech stack

Six services (Player, Session, Applicant, Credential, Moderation, Discord DMs) are Go + Gin. Two
(Server Rules, University Record) are C# + ASP.NET Core. All services expose the same contract
shape regardless of language: REST + JSON under `/api/v1`, snake_case fields, the same error
envelope, and RabbitMQ for events. Database-per-service, engine chosen per service (see the
Databases table in `README.md` for which engine and why).
