# TEAM 16's COURSE PROJECT - Student ID, please

This Common Public Repository (CPR) serves as a centralized documentation hub for the
FAF Discord Moderation game called **"Student ID, please"**

In accordance with course guidelines, each microservice source code is hosted in its
own isolated private repository accessible only to its assigned author and course professors.
This CPR contains submodules linking to those repositories and provides the global
service boundaries and communication architecture for the distributed system.

## Repo structure and Submodule Access

Due to repository permissions, cloing the CPR with submodules will only pull code for the services you personally own (or have professor-level permissions to read).

```
git clone https://github.com/your-org/faf-moderation-cpr.git

git submodule update --init --recursive
```

## Module ownership list

- Postoronca Dumitru: `player service` and `server moderation session service`;
- Iacovlev Maxim: `applicant service` and `credential service`;
- Racovita Dumitru: `moderation service` and `discord dm service`;
- Titerez Vladislav: `server rule service` and `university-record-service`;

## Service Boundaries

The system is decomposed following a data ownership principle: for every piece of state, exactly one service is the source of truth and the only service allowed to write it. Other services may read or trigger changes only through that owning service's API. This is why applicant-related data is split into three services (Applicant, Credential, University Record) rather than one - each owns a distinct category of data (identity, documents, hidden institutional records) with a different lifecycle and different access rules, even though they describe the same real-world person.

**Note on applicant initialization:** the topic allows any of Applicant, Credential, or University Record Service to be the first to encounter a new applicant. To keep this from turning into three services writing to each other's data, we resolve it as follows: whichever service is contacted first generates a shared `applicant_id` and publishes an `ApplicantInitialized` event carrying that ID plus the fields it was given. The other two services subscribe to this event and create their own record under the same `applicant_id`, populated only with the fields relevant to them. Each service still only ever writes its own record - there is no cross-service write, only event-driven record creation.

**Note on applicant assignment to sessions:** the topic does not specify how a session acquires its `current_applicant_id`. We resolve this as: when the Moderator requests the next applicant, Server Moderation Session Service calls Applicant Service to generate the next applicant profile, and stores the returned `applicant_id` as `current_applicant_id` for that session.

**Note on scoped access assignment:** the topic specifies that access to University Record Service categories (enrollment, email-groups, courses, fcim-logs) is distributed among Junior Moderators within a session, but does not say who assigns it. We resolve this as: Server Moderation Session Service, which already assigns player roles when a session is formed, also assigns each Junior Moderator a subset of record categories at that same point, and passes this mapping to University Record Service so it can enforce access per `player_id` + `session_id`.

### 1. Player Service

- **Owns:** moderator player accounts - `player_id`, username, hashed credentials, email, profile, friends list, XP, level, moderation experience stats, shift history, disciplinary action log
- **Does NOT own:** any data about the people attempting to join the university server (that belongs entirely to the applicant-side services)
- **Interacts with:** Server Moderation Session Service, which reads a player's profile and level when they create or join a session, and reports shift results back so this service can update XP/level/disciplinary history

### 2. Server Moderation Session Service

- **Owns:** the moderation session/shift itself - `session_id`, assigned Moderator, assigned Junior Moderators and the record categories each of them may read, session status, shift difficulty, `ruleset_version` used by the shift, `current_applicant_id`, number of applications processed, session score, penalties, start/end timestamps
- **Does NOT own:** applicant data, and does NOT make the admission decision - it only tracks that a decision is in progress and records the eventual outcome
- **Interacts with:** Player Service (checks players and reads their level when they create or join a session, reports shift results), Server Rules Service (gets the ruleset for the shift when it starts), Moderation Service (Moderation reads the current applicant from it before recording a decision, and reports the outcome back), Discord DMs Service (supplies session membership so it can scope its own channels), Applicant Service (requests a new applicant profile per the assignment logic above), University Record Service (assigns each Junior Moderator's record-category scope when the session is formed)

### 3. Applicant Service

- **Owns:** the applicant's core identity - `applicant_id`, name, student ID, major, year, university status (FAF student / other-major student / TA / staff / alumni / outsider), enrolled courses, role
- **Does NOT own:** credential documents (Credential Service), hidden institutional records (University Record Service), or the admission decision (Moderation Service)
- **Interacts with:** Credential Service and University Record Service via the `ApplicantInitialized` event described above; Server Moderation Session Service (supplies a new applicant profile when requested); Moderation Service (supplies the base profile for a decision)

### 4. Credential Service

- **Owns:** the documents an applicant presents - student ID card, university email, enrollment confirmation, course registration proof - along with each document's validation status (valid / expired / forged / inconsistent / incomplete)
- **Does NOT own:** the applicant's identity profile, and does NOT decide whether the applicant is admitted - it only certifies whether the documents are structurally and logically sound
- **Interacts with:** Applicant Service and University Record Service (initialization event), Moderation Service (supplies validation results, not a verdict)

### 5. Server Rules Service

- **Owns:** the current, versioned ruleset for server access, which can be edited between shifts (e.g. "first-years cannot access #dark-memes", "must be enrolled 2+ years", "banned users are rejected regardless of credentials")
- **Does NOT own:** any applicant data, and does NOT issue the final admission decision - it only answers "does this applicant satisfy the current rules?" when asked
- **Interacts with:** Server Moderation Session Service, which gets the ruleset for each new shift, and Moderation Service, which asks it to evaluate each applicant during a decision

### 6. University Record Service

- **Owns:** hidden institutional data - enrollment list, Outlook group email lists, existing course list, current academic year, semester schedule, FCIM server message records
- **Access control:** each record type is tagged by category (e.g. `enrollment`, `email-groups`, `courses`, `fcim-logs`). Within a session, each Junior Moderator is assigned a subset of categories they're permitted to query, per the scope assigned by Server Moderation Session Service; the service enforces this at the API level using `player_id` + `session_id`, and requests for a category outside a player's assignment are rejected
- **Does NOT own:** credential documents, and does NOT decide on admission, and does NOT assign the scope itself (Server Moderation Session Service does)
- **Interacts with:** Applicant Service and Credential Service (initialization event), Server Moderation Session Service (receives the per-player scope assignment when a shift starts, and closes that access when the shift ends), Moderation Service (supplies verification data, respecting the requesting player's scope)

### 7. Moderation Service

- **Owns:** the admission decision itself - `applicant_id`, decision (accept / reject / flag / ban), violated rules (if any), penalty, outcome, deciding moderator, timestamp - and the ban list built from its own `ban` decisions
- **Does NOT own:** applicant identity, documents, or institutional records - it only consumes them, read-only, to reach and record a verdict
- **Interacts with:** Applicant, Credential, and University Record Services (gathers data for the decision), Server Rules Service (checks compliance), Server Moderation Session Service (reads the current applicant and the shift's ruleset version, reports the outcome back)

### 8. Discord DMs Service

- **Owns:** real-time communication for a session - channels (e.g. `#enrollment-check`, `#faculty-check`, `#course-registration`, `#general-mod-chat`), messages (author, timestamp, channel, content), and per-player channel access mapping
- **Does NOT own:** the correctness of any information exchanged - it is a pure transport layer and never validates message content
- **Interacts with:** Server Moderation Session Service, which supplies session membership (who is in the session and their assigned roles); Discord DMs Service uses that membership data to scope its own channels and access mapping, but ownership of the channels and access mapping stays with Discord DMs Service

## Architecture Diagram

The diagram below visualizes the communication paths described above: the Session Layer (Player, Server Moderation Session, Discord DMs) coordinates around an active shift; the Applicant Data group (Applicant, Credential, University Record) stays loosely coupled through a shared `ApplicantInitialized` event instead of direct service-to-service calls; and Moderation Service sits at the center as the only consumer that reads from every data-owning service to produce a decision, which then flows back into the session.

![Architecture Diagram](img/Architecture_2.drawio.png)

---

## Technologies

### Languages

We use two languages: **Go** and **C#**.

| Language | Services | Owners |
| --- | --- | --- |
| Go | Player, Server Moderation Session, Applicant, Credential, Moderation, Discord DMs | Postoronca Dumitru, Iacovlev Maxim, Racovita Dumitru |
| C# | Server Rules, University Record | Titerez Vladislav |

**Why Go for six services.** Most of our services do the same kind of work: receive an HTTP request, call one or two other services, read or write their own database, and answer. Go is built for exactly this. It compiles to one small binary, starts in milliseconds, and goroutines make it simple to call several services at the same time (Moderation Service calls three at once). Go is also quick to learn, which matters because most of the team is picking it up during this course.

**Why C# for the rules and records services.** These two services are about data rules, not traffic. Server Rules answers "does this applicant satisfy rule version 7?" and University Record answers "may this player read the enrollment list?". C# has a strong type system and pattern matching that make such rules explicit in code, and ASP.NET Core has built-in policy-based authorization that expresses "player X may read category Y" directly. Their owner has the most C# experience in the team.

**Trade-off.** Two languages mean two toolchains, two sets of libraries and two ways to write a Dockerfile. We accept that because every service exposes the same interface (REST + JSON, RabbitMQ events), so a Go service and a C# service talk to each other in exactly the same way.

### Frameworks and libraries

| Purpose | Go | C# |
| --- | --- | --- |
| HTTP server | Gin | ASP.NET Core Web API |
| HTTP client | `net/http` | `HttpClient` |
| RabbitMQ | `rabbitmq/amqp091-go` | `RabbitMQ.Client` |
| WebSocket | `gorilla/websocket` (Discord DMs only) | not needed |
| PostgreSQL | `pgx` | Npgsql + EF Core |
| MongoDB | `mongo-go-driver` | `MongoDB.Driver` |
| Redis | `go-redis` | `StackExchange.Redis` |

Every service runs in its own Docker container. RabbitMQ runs as one shared container.

### Databases

**Rule: every service has its own database, and no service ever connects to another service's database.** Why this rule exists is explained in Communication Contract, Data Management.

We use three engines. PostgreSQL is the default. MongoDB and Redis are used only where there is a concrete reason.

| Service | Database | Engine | Why this engine |
| --- | --- | --- | --- |
| Player | `player_db` | PostgreSQL | Accounts, XP, shift history and the disciplinary log are tables with relations between them. When a shift ends, XP and history must update together, which needs a transaction. |
| Server Moderation Session | `session_db`, `session_cache` | PostgreSQL, Redis | History of shifts (who, when, score) goes to PostgreSQL. The state of the shift running right now (current applicant, counters) goes to Redis because it is read on every action and must be fast. |
| Applicant | `applicant_db` | PostgreSQL | Every applicant has the same fields (name, student ID, major, year, status, courses). A fixed structure is a table. |
| Credential | `credential_db` | MongoDB | Each applicant has a bundle of documents, and every document type has different fields. In a table this would be many empty columns. A document store keeps each bundle as one JSON document. |
| Server Rules | `rules_db` | PostgreSQL | Rulesets are versioned, and each shift records which version it used, so versions must be queryable. Rule conditions are stored as JSONB so a new rule type does not need a schema change. |
| University Record | `university_record_db` | PostgreSQL | Enrollment lists, email groups, courses and schedules are tables. Access control is a join between "records by category" and "which player may see which category in this session". |
| Moderation | `moderation_db` | PostgreSQL | Each decision is an audit record: who decided, what, whether it was correct, which rules were broken. Queried by session, moderator and applicant. Never changed after it is written. |
| Discord DMs | `dms_db`, `dms_pubsub` | MongoDB, Redis | Messages are appended and read back per channel in time order, which is what a Mongo collection with an index does. Redis Pub/Sub is not storage: it passes each new message to every running instance of the service so all connected players receive it. |

---

## Communication Patterns

Services talk to each other in three ways. Each way has one rule for when to use it.

### Rule 1. You need an answer right now: REST (HTTP + JSON)

Example: Session Service needs the next applicant before it can continue. It calls `POST /api/v1/applicants/next` on Applicant Service and waits for the reply.

Every service exposes a REST API. Services call each other through the same API a client would use. We chose REST over gRPC because JSON is easy to read, to test with curl or Postman, and to debug across two languages. gRPC would be faster, but nothing in Lab 0 needs that speed. If the four parallel calls of Moderation Service ever become a bottleneck, that path is the candidate for gRPC.

### Rule 2. Something happened and others should know, no reply needed: RabbitMQ event

Example: a shift ends. Session Service publishes one event, `session.ended`. Player Service reads it and updates XP. Discord DMs Service reads it and archives the channels. Session Service does not wait for either of them and does not need to know who is listening.

All events go through one RabbitMQ topic exchange. An event may be delivered twice, so every consumer remembers the `event_id` values it has seen and ignores repeats. This is what makes events safe: if Player Service is down for a minute, the event waits in the queue and XP is still awarded exactly once.

### Rule 3. The client must be pushed to: WebSocket (Discord DMs only)

Players chat in channels and must see new messages instantly. Discord DMs Service keeps one WebSocket connection open per player. No other service holds client connections. Channel lists and message history are also available over REST, so a client that reconnects can catch up.

### Every arrow in the diagram and the rule it follows

| Interaction | Rule | Who calls whom | Why this rule |
| --- | --- | --- | --- |
| Player creates or joins a session | REST | client → Session; Session → Player `GET /players/{id}` | Needs an answer now |
| Session reports shift results | Event `session.ended` | Session → Player | Player updates XP later; closing the shift must not wait for it |
| Session picks the ruleset for a new shift | REST `GET /rulesets/current` | Session → Server Rules | The shift cannot start without knowing its `ruleset_version` |
| Session requests the next applicant | REST | Session → Applicant | Needs the `applicant_id` now |
| Applicant is initialized (`ApplicantInitialized` in Service Boundaries) | Event `applicant.initialized` | the service contacted first → the other two | Two listeners, no waiting, no cross-service writes |
| Session assigns record scopes to Junior Moderators | Event `session.started` | Session → University Record | Membership and scopes travel together in one event |
| Session supplies channel membership | Events `session.started`, `session.ended` | Session → Discord DMs | Discord DMs creates and archives channels on its own |
| Moderator submits a decision | REST `POST /decisions` | client → Moderation | The verdict must come back now |
| Session supplies the current applicant | REST `GET /sessions/{id}` | Moderation → Session | Moderation checks that the decision is about the current applicant and reads the shift's `ruleset_version` |
| Moderation gathers data for the verdict | REST, three calls in parallel | Moderation → Applicant, Credential, University Record | All three answers are needed to know what is true about the applicant |
| Moderation checks the rules | REST `POST /rulesets/{version}/evaluations` | Moderation → Server Rules | Needs the verified facts from the three calls above, so it comes after them |
| Moderation reports the outcome | Event `decision.recorded` | Moderation → Session | Session updates score and counters; no reply needed |
| Players chat during a shift | WebSocket (REST for history) | client ↔ Discord DMs | Push in real time |

### Worked example: one applicant from start to finish

1. The Moderator asks for the next applicant. Session calls Applicant over REST. Applicant Service creates the applicant and publishes `applicant.initialized`. Credential and University Record create their own records under the same `applicant_id`.
2. Junior Moderators look up records. The client calls University Record over REST. Each player only sees the categories assigned to them in `session.started`.
3. The team discusses in channels through Discord DMs over WebSocket.
4. The Moderator submits a decision with `POST /api/v1/decisions`. Moderation Service calls Session (is this the current applicant, and which ruleset does the shift use?), then Applicant, Credential and University Record in parallel. From the records it builds the verified facts and sends them to Server Rules. All calls are REST. It computes the correct verdict, compares it with the Moderator's choice, stores the decision and replies.
5. Moderation publishes `decision.recorded`. Session updates the score and counters.
6. The shift ends. Session publishes `session.ended`. Player updates XP and history; Discord DMs archives the channels; University Record closes the juniors' access.

**Note on University Record access.** A player's request is limited to the categories assigned to that player in the session. Moderation Service needs all categories to compute the correct verdict, so it calls University Record with an internal service token that has full read access. That token never reaches a client.

---

## Communication Contract

### Data Management

**Rule: one database per service, and only the owning service writes to it.** If a service needs data it does not own, it either calls the owner's REST API or listens to the owner's events. It never reads another service's tables.

Why:

- Service Boundaries say each piece of data has exactly one writer. With a shared database that is a promise; with separate databases it is enforced.
- Services must be deployable and scalable one by one in later laboratories. A shared schema ties every deploy to every other service.
- The data has different shapes: relational decisions and rules, document-shaped credentials and messages, cached shift state. One engine does not fit all of them well.

What it costs, and what we do about it:

- **Data that crosses a boundary through events arrives a little later.** Credential Service learns about a new applicant a few milliseconds after Applicant Service creates it. Consumers are idempotent and keyed by the shared identifier, so order and repeats do not matter.
- **No transaction can span two services.** A flow like "decision → session score → player XP" is a chain of events, not one transaction. Compensation for failures is a topic for the transactions laboratory.
- **No joins across services.** A service that needs a combined view asks each owner and combines the answers itself. Moderation Service does exactly this.

**Permitted duplication.** A service may keep a read-only copy of another service's data if it needs it for auditing or speed, as long as the owner stays the source of truth. Moderation Service stores a snapshot of the applicant, credentials and rule version behind each verdict, so the decision can still be explained after the applicant or the rules have changed.

**Shared identifiers.** `player_id`, `session_id`, `applicant_id`, `decision_id`, `channel_id` and `message_id` are UUID v4 strings. `ruleset_version` is an integer that grows by one with every new ruleset. `applicant_id` is generated by whichever service initializes the applicant and is the same in Applicant, Credential and University Record.

#### Event catalog

Exchange `student-id.events`, type `topic`. Every event has the same envelope; only `payload` differs.

```json
{
  "event_id": "4f0c2a8e-1c3b-4d0e-9a6f-2b7e8c9d1a23",
  "event_type": "session.started",
  "occurred_at": "2026-09-09T14:32:10Z",
  "producer": "server-moderation-session-service",
  "version": 1,
  "payload": {}
}
```

| Routing key | Published by | Consumed by | Payload (key fields) |
| --- | --- | --- | --- |
| `applicant.initialized` | the first of Applicant, Credential, University Record to be contacted | the other two | `applicant_id`, `session_id`, `initialized_by`, `difficulty`, `claimed { profile }`, `actual { profile }` |
| `session.started` | Server Moderation Session | University Record, Discord DMs | `session_id`, `moderator_id`, `junior_moderators[] { player_id, record_scopes[] }`, `ruleset_version`, `started_at` |
| `session.ended` | Server Moderation Session | Player, Discord DMs, University Record | `session_id`, `score`, `penalties`, `applications_processed`, `players[] { player_id, xp_delta, disciplinary_actions[] }`, `ended_at` |
| `decision.recorded` | Moderation | Server Moderation Session | `decision_id`, `session_id`, `applicant_id`, `moderator_id`, `action`, `is_correct`, `expected_action`, `violated_rules[]`, `penalty` |

#### API conventions

These apply to every endpoint listed in the next section.

- Base path `/api/v1`. Resource names are plural nouns. JSON fields are `snake_case`. Timestamps are ISO 8601 in UTC. Identifiers are UUID strings.
- Errors always look the same and use the matching HTTP status (400, 401, 403, 404, 409, 422, 500): `{ "error": { "code": "APPLICANT_NOT_FOUND", "message": "...", "details": {} } }`.
- Lists are paginated with `?limit=&offset=` and return `{ "items": [], "total": 0 }`.
- A request from a player carries the player's JWT. A request from another service carries a service token, so the receiver can tell the two apart (University Record relies on this).
- Every service exposes `GET /health`.

### Endpoints

For every service this section lists three things: the endpoints it **calls** in other services, the endpoints it **offers**, and the **events** it publishes or listens to. Paths, field names and errors follow the API conventions above.

How to read it:

- **Client** means the player's game client. Only the client endpoints that start or feed a flow between services are listed here. Account features (register, login, friends, profile editing) will be added when the client is designed.
- **Who is calling.** Authentication is out of scope for now. When an endpoint needs to know which player is calling (for example, "only the Moderator may do this"), it takes the `player_id` from the player's JWT, as the API conventions say. That player is called "the calling player" below.
- **Errors.** Each endpoint lists only its own error codes. On top of those, any endpoint can answer `400 VALIDATION_ERROR` for a malformed request, or `500 DEPENDENCY_UNAVAILABLE` when a service it needs does not answer. In that second case nothing is changed.
- **Events** always use the common envelope from the event catalog, so only the `payload` is shown.
- `GET /health` exists in every service and is not repeated below.

#### Shared values

These values are used by more than one service, so they are defined once here.

| Field | Allowed values |
| --- | --- |
| `university_status` | `faf_student`, `other_major_student`, `teaching_assistant`, `staff`, `alumni`, `outsider` |
| `role` (the server role an applicant asks for) | `student`, `teacher`, `alumni`, `guest` |
| document `type` | `student_id_card`, `university_email`, `enrollment_confirmation`, `course_registration` |
| document `validation_status` | `valid`, `expired`, `forged`, `inconsistent`, `incomplete` |
| record `category` | `enrollment` (enrollment list and current academic year), `email-groups` (Outlook group lists), `courses` (existing courses and semester schedule), `fcim-logs` (FCIM server messages) |
| decision `action` | `accept`, `reject`, `flag`, `ban` |
| session `status` | `lobby` (players are joining), `active` (the shift is running), `ended` |
| server channels (what an accepted applicant may enter) | `general`, `dark-memes`, `groapa`, `teachers`, `alumni`; a ruleset may add more |
| moderator channels (in Discord DMs) | `general-mod-chat`, `enrollment-check`, `faculty-check`, `course-registration` |
| `difficulty` | integer from `1` (easy) to `5` (hard) |

**Applicant profile.** This is the shape of what an applicant says about themselves. It is used by Applicant Service and inside the `applicant.initialized` event (both `claimed` and `actual` have this shape):

```json
{
  "name": "Ion Popescu",
  "student_id": "FAF231017",
  "email": "ion.popescu@isa.utm.md",
  "major": "FAF",
  "year": 2,
  "university_status": "faf_student",
  "courses": ["PAD", "ELSE-NET"],
  "role": "student"
}
```

`student_id`, `major` and `year` are `null` for people who never studied at the university.

#### Player Service

##### Consumed API endpoints

None. Player Service never calls other services; it only listens to `session.ended`.

##### Exposed API endpoints

###### `GET /api/v1/players/{player_id}` - consumed by Server Moderation Session Service, Client

**Description.** Returns the public part of a player's profile. Session Service calls it when a player creates or joins a session, to make sure the player exists and to read their level. Session uses the levels to decide how hard the shift will be.

**Payload.** None.

**Response.** `200 OK`

```json
{
  "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "username": "dima_mod",
  "level": 4,
  "xp": 1250,
  "completed_shifts": 12
}
```

`404 PLAYER_NOT_FOUND` if no player has this ID.

**Usage.** Private data (email, password hash, friends list, disciplinary log) is never returned here.

##### Message queue events

**Published:** none.

**Consumed:**

- `session.ended` - published by Server Moderation Session Service  
  For every player in `players[]`, adds `xp_delta` to their XP, recalculates their level, adds the shift to their history and appends any `disciplinary_actions` to their log. The `event_id` is remembered, so the same shift is never counted twice.

#### Server Moderation Session Service

##### Consumed API endpoints

- `GET /api/v1/players/{player_id}` - available in Player Service  
  Checks that the player exists and reads their level when they create or join a session.
- `GET /api/v1/rulesets/current?difficulty={n}` - available in Server Rules Service  
  Picks the ruleset when the shift starts. The returned `version` is stored in the session and used for the whole shift.
- `POST /api/v1/applicants/next` - available in Applicant Service  
  Creates the next applicant. The returned `applicant_id` becomes the session's `current_applicant_id`.

##### Exposed API endpoints

Several endpoints below return the **session object**:

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "status": "active",
  "created_by": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "players": [
    { "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11", "username": "dima_mod", "level": 4 },
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "username": "maxim_jr", "level": 2 },
    { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "username": "vlad_jr", "level": 3 }
  ],
  "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "junior_moderators": [
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] },
    { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "record_scopes": ["email-groups", "fcim-logs"] }
  ],
  "difficulty": 3,
  "ruleset_version": 7,
  "current_applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "current_applicant_decided": false,
  "applications_processed": 5,
  "score": 40,
  "penalties": 10,
  "created_at": "2026-09-10T18:00:00Z",
  "started_at": "2026-09-10T18:05:00Z",
  "ended_at": null
}
```

While the session is in the `lobby`, `moderator_id`, `ruleset_version` and `current_applicant_id` are `null` and `junior_moderators` is empty.

###### `POST /api/v1/sessions` - consumed by Client

**Description.** The calling player opens a new session. The session starts in the `lobby`, and this player is its first member and its creator.

**Payload.** None (empty body).

**Response.** `201 Created` with the session object (`status: "lobby"`).

**Usage.** Session first calls `GET /api/v1/players/{player_id}` in Player Service. Errors: `404 PLAYER_NOT_FOUND`, and `409 PLAYER_ALREADY_IN_SESSION` if the player is already in a lobby or an active session.

###### `POST /api/v1/sessions/{session_id}/players` - consumed by Client

**Description.** The calling player joins a session that is still in the lobby.

**Payload.** None (empty body).

**Response.** `200 OK` with the updated session object.

**Usage.** As with creating a session, the player is checked in Player Service first. A session holds at most 5 players (1 Moderator and up to 4 Junior Moderators). Errors: `404 SESSION_NOT_FOUND`, `404 PLAYER_NOT_FOUND`, `409 SESSION_NOT_IN_LOBBY`, `409 SESSION_FULL`, `409 PLAYER_ALREADY_IN_SESSION`.

###### `POST /api/v1/sessions/{session_id}/start` - consumed by Client

**Description.** The creator starts the shift. Session assigns the roles, splits the record categories between the Junior Moderators, picks the ruleset and publishes `session.started`.

**Payload.**

```json
{
  "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11"
}
```

`moderator_id` must be one of the session's players. Everyone else becomes a Junior Moderator.

**Response.** `200 OK` with the session object (`status: "active"`).

**Usage.**

- Only the creator can start the session, and at least 2 players are needed (a Moderator and one Junior Moderator).
- `difficulty` is the average level of the players, rounded and kept between 1 and 5. Session sends it to `GET /api/v1/rulesets/current` and stores the returned `version` as `ruleset_version`.
- The four record categories are handed out in turn: with 4 juniors each gets one category, with 2 juniors each gets two, and with 3 juniors one of them gets two. The Moderator gets no category.
- If Server Rules does not answer, the session stays in the lobby.
- Errors: `403 NOT_SESSION_CREATOR`, `409 SESSION_NOT_IN_LOBBY`, `409 NOT_ENOUGH_PLAYERS`, `422 MODERATOR_NOT_IN_SESSION`.

###### `POST /api/v1/sessions/{session_id}/applicants/next` - consumed by Client

**Description.** The Moderator asks for the next applicant. Session calls `POST /api/v1/applicants/next` in Applicant Service, stores the new `applicant_id` as `current_applicant_id` and returns it. The client then reads the profile from Applicant Service and the documents from Credential Service.

**Payload.** None (empty body).

**Response.** `201 Created`

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "current_applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "applications_processed": 5
}
```

**Usage.**

- Only the session's Moderator can ask for the next applicant.
- A new applicant is given only when the current one already has a decision. Session learns about decisions through the `decision.recorded` event, which can arrive a moment after the Moderator got the reply from Moderation Service. So, right after a decision, this endpoint may answer `409 CURRENT_APPLICANT_NOT_DECIDED`; the client waits briefly and tries again.
- Errors: `403 NOT_MODERATOR`, `409 SESSION_NOT_ACTIVE`, `409 CURRENT_APPLICANT_NOT_DECIDED`.

###### `POST /api/v1/sessions/{session_id}/end` - consumed by Client

**Description.** The Moderator ends the shift. Session works out the result (final score, penalties, XP for every player, disciplinary actions), stores it and publishes `session.ended`.

**Payload.** None (empty body).

**Response.** `200 OK`

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "status": "ended",
  "score": 40,
  "penalties": 10,
  "applications_processed": 6,
  "players": [
    { "player_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11", "role": "moderator", "xp_delta": 30, "disciplinary_actions": [{ "type": "warning", "reason": "Accepted an applicant with a forged student ID" }] },
    { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "role": "junior_moderator", "xp_delta": 40, "disciplinary_actions": [] }
  ],
  "ended_at": "2026-09-10T18:45:00Z"
}
```

**Usage.** If the current applicant has no decision yet, that applicant is dropped and does not count. Session decides how XP and disciplinary actions are calculated. Player Service only applies the result it receives in `session.ended`. Errors: `403 NOT_MODERATOR`, `409 SESSION_NOT_ACTIVE`.

###### `GET /api/v1/sessions/{session_id}` - consumed by Moderation Service, Client

**Description.** Returns the current state of a session. Before recording a decision, Moderation Service uses it to check four things: the session is active, the calling player is its Moderator, the applicant is the current one, and which `ruleset_version` the shift uses.

**Payload.** None.

**Response.** `200 OK` with the session object. `404 SESSION_NOT_FOUND` if the session does not exist.

##### Message queue events

**Published:**

- `session.started` - consumed by University Record Service, Discord DMs Service  
  A shift has started. University Record learns which categories each junior may read, and Discord DMs learns who is in the session so it can create the channels.

  ```json
  {
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
    "junior_moderators": [
      { "player_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "record_scopes": ["enrollment", "courses"] },
      { "player_id": "c3e5a7b9-2d4f-4b6c-8e0a-1f3b5d7f9a21", "record_scopes": ["email-groups", "fcim-logs"] }
    ],
    "ruleset_version": 7,
    "started_at": "2026-09-10T18:05:00Z"
  }
  ```

- `session.ended` - consumed by Player Service, Discord DMs Service, University Record Service  
  The shift is over. Player Service updates progression, Discord DMs archives the channels and University Record closes the juniors' access. The payload is the same as the response of `POST /api/v1/sessions/{session_id}/end` above, without `status`.

**Consumed:**

- `decision.recorded` - published by Moderation Service  
  Increases `applications_processed`, adds points to `score` when the decision was correct, adds `penalty` to `penalties`, and marks the current applicant as decided so the Moderator can ask for the next one.

#### Applicant Service

##### Consumed API endpoints

None. Applicant Service never calls other services. It shares new applicants through the `applicant.initialized` event.

##### Exposed API endpoints

###### `POST /api/v1/applicants/next` - consumed by Server Moderation Session Service

**Description.** Creates a new applicant for a session. The service makes up two profiles: what the applicant will claim (`claimed`) and who they really are (`actual`). It stores both, publishes `applicant.initialized` so Credential and University Record can create their part, and returns the new `applicant_id`.

**Payload.**

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "difficulty": 3
}
```

**Response.** `201 Created`

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "created_at": "2026-09-10T18:10:00Z"
}
```

**Usage.**

- The higher the `difficulty`, the more likely the applicant lies or brings tricky documents.
- The same endpoint (same path, payload and response) also exists in Credential Service and University Record Service, so any of the three can be the first service to meet a new applicant, as the topic allows. For now, Session Service only calls this one.
- `actual` is never returned by any endpoint. It only travels inside the event.

###### `GET /api/v1/applicants/{applicant_id}` - consumed by Moderation Service, Client

**Description.** Returns what the applicant claims about themselves. The Moderator's client shows it on screen, and Moderation Service compares it with the university records when checking a decision.

**Payload.** None.

**Response.** `200 OK`: the claimed [applicant profile](#shared-values) plus its identifiers.

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "name": "Ion Popescu",
  "student_id": "FAF231017",
  "email": "ion.popescu@isa.utm.md",
  "major": "FAF",
  "year": 2,
  "university_status": "faf_student",
  "courses": ["PAD", "ELSE-NET"],
  "role": "student",
  "created_at": "2026-09-10T18:10:00Z"
}
```

`404 APPLICANT_NOT_FOUND` if the applicant does not exist. This can also happen for a moment if another service created the applicant and the event has not arrived yet.

##### Message queue events

**Published:**

- `applicant.initialized` - consumed by Credential Service, University Record Service  
  A new applicant exists. Sent only when Applicant Service is the first service contacted.

  ```json
  {
    "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "initialized_by": "applicant-service",
    "difficulty": 3,
    "claimed": {
      "name": "Ion Popescu", "student_id": "FAF231017", "email": "ion.popescu@isa.utm.md",
      "major": "FAF", "year": 2, "university_status": "faf_student", "courses": ["PAD", "ELSE-NET"], "role": "student"
    },
    "actual": {
      "name": "Ion Popescu", "student_id": null, "email": "ion.popescu99@gmail.com",
      "major": null, "year": null, "university_status": "outsider", "courses": [], "role": "guest"
    }
  }
  ```

  `claimed` and `actual` have the same fields. If they are equal, the applicant is honest. Every field where they differ is a lie. In this example an outsider pretends to be a second-year FAF student. Every receiver stores only what it needs, and `actual` must never be shown to players.

**Consumed:**

- `applicant.initialized` - published by Credential Service or University Record Service  
  When another service met the applicant first, Applicant Service stores the profile from `claimed` (and keeps `actual` hidden) under the same `applicant_id`. Events where `initialized_by` is `applicant-service` are its own and are ignored.

#### Credential Service

##### Consumed API endpoints

None. Credential Service never calls other services. It learns about new applicants from the `applicant.initialized` event.

##### Exposed API endpoints

###### `POST /api/v1/applicants/next` - consumed by: no service yet

**Description.** Creates a new applicant, starting from the documents they bring (for example, a student ID card that was found or copied). Credential stores the documents, publishes `applicant.initialized` and returns the new `applicant_id`.

**Payload.** Same as in Applicant Service: `{ "session_id": "...", "difficulty": 3 }`.

**Response.** `201 Created`, same as in Applicant Service: `{ "applicant_id": "...", "session_id": "...", "created_at": "..." }`.

**Usage.** This endpoint exists so that Credential can be the first service to meet a new applicant, as the topic allows. No service calls it yet. Session Service can switch to it later without any change on its side, because the contract is the same as in Applicant Service.

###### `GET /api/v1/applicants/{applicant_id}/documents` - consumed by Client

**Description.** Returns the documents the applicant shows to the Moderator. Validation results are **not** included: finding the problems is the players' job.

**Payload.** None.

**Response.** `200 OK`

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "documents": [
    {
      "document_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "type": "student_id_card",
      "fields": { "name": "Ion Popescu", "student_id": "FAF231017", "faculty": "FCIM", "major": "FAF", "valid_until": "2027-06-30" }
    },
    {
      "document_id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e",
      "type": "enrollment_confirmation",
      "fields": { "name": "Ion Popescu", "student_id": "FAF231017", "academic_year": "2026-2027", "year": 2, "issued_at": "2026-09-01" }
    }
  ]
}
```

**Usage.** The `fields` are different for every document type. When Applicant Service creates the applicant, the documents are created from the `applicant.initialized` event. That means that just after a new applicant appears, this endpoint may answer `404 APPLICANT_NOT_FOUND` for a moment. The client then tries again.

###### `GET /api/v1/applicants/{applicant_id}/documents/validation` - consumed by Moderation Service

**Description.** Returns the same documents together with the result of the structure and authenticity check. It says whether each document is sound, not whether the applicant should be admitted.

**Payload.** None.

**Response.** `200 OK`

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "documents": [
    {
      "document_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "type": "student_id_card",
      "fields": { "name": "Ion Popescu", "student_id": "FAF231017", "faculty": "FCIM", "major": "FAF", "valid_until": "2027-06-30" },
      "validation_status": "forged",
      "problems": ["Student ID FAF231017 was never issued to this person"]
    },
    {
      "document_id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e",
      "type": "enrollment_confirmation",
      "fields": { "name": "Ion Popescu", "student_id": "FAF231017", "academic_year": "2026-2027", "year": 2, "issued_at": "2026-09-01" },
      "validation_status": "forged",
      "problems": ["The confirmation number does not exist"]
    }
  ]
}
```

**Usage.** Only for services. Players must never get this, or the game would be trivial. `404 APPLICANT_NOT_FOUND` if the applicant does not exist.

##### Message queue events

**Published:**

- `applicant.initialized` - consumed by Applicant Service, University Record Service  
  Same payload as in Applicant Service, with `"initialized_by": "credential-service"`. Sent only when Credential is the first service contacted, through its own `POST /api/v1/applicants/next`.

**Consumed:**

- `applicant.initialized` - published by Applicant Service or University Record Service  
  Creates the applicant's documents from `claimed`. Where `claimed` and `actual` differ, the documents that support the false claim are marked `forged`. Honest applicants never get forged documents, but depending on `difficulty`, some of their documents may be `expired`, `inconsistent` or `incomplete`. Events where `initialized_by` is `credential-service` are ignored.

#### Server Rules Service

##### Consumed API endpoints

None. Server Rules never calls other services. Everything it needs to evaluate an applicant arrives in the request.

##### Exposed API endpoints

Several endpoints below return the **ruleset object**:

```json
{
  "version": 7,
  "difficulty": 3,
  "rules": [
    { "rule_id": "only-faf-or-teachers", "kind": "admission", "description": "Only FAF students and FAF teachers may join" },
    { "rule_id": "no-previously-banned", "kind": "admission", "description": "Previously banned people cannot enter, whatever their documents say" },
    { "rule_id": "first-years-general-only", "kind": "channel", "description": "First-year students may access #general but not #dark-memes or #groapa" },
    { "rule_id": "teachers-channel", "kind": "channel", "description": "Teachers may access #teachers" }
  ],
  "created_at": "2026-09-01T00:00:00Z"
}
```

A rule of kind `admission` decides whether a person may join at all. A rule of kind `channel` decides which server channels they get once they are in. The exact condition of each rule is stored as JSONB inside the service and is not part of the contract.

###### `GET /api/v1/rulesets/current` - consumed by Server Moderation Session Service

**Description.** Returns the ruleset that new shifts of a given difficulty should use. A higher difficulty means more rules, and more complicated ones.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `difficulty` | integer 1-5 | yes | How hard the shift should be |

**Payload.** None.

**Response.** `200 OK` with the ruleset object. `422 INVALID_DIFFICULTY` if `difficulty` is missing or outside 1-5.

**Usage.** Rules may change between shifts, never during one. Session stores `version` when the shift starts, and every later call about that shift uses this version, even if a newer one appears in the meantime.

###### `GET /api/v1/rulesets/{version}` - consumed by Client

**Description.** Returns one ruleset version, so the players can read the rules of their shift.

**Payload.** None.

**Response.** `200 OK` with the ruleset object. `404 RULESET_NOT_FOUND` if the version does not exist.

###### `POST /api/v1/rulesets/{version}/evaluations` - consumed by Moderation Service

**Description.** Checks an applicant's verified facts against one ruleset version. It answers the question "may this person join, and which server channels may they enter?". It does not make the final decision.

**Payload.**

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "facts": {
    "university_status": "faf_student",
    "major": "FAF",
    "year": 1,
    "years_enrolled": 1,
    "currently_enrolled": true,
    "previously_banned": false
  }
}
```

**Response.** `200 OK`

```json
{
  "ruleset_version": 7,
  "admitted": true,
  "violated_rules": [],
  "allowed_channels": ["general"]
}
```

An applicant who breaks an admission rule gets `"admitted": false`, the broken rules in `violated_rules` (for example `[{ "rule_id": "only-faf-or-teachers", "description": "Only FAF students and FAF teachers may join" }]`) and an empty `allowed_channels`.

**Usage.**

- The facts describe what the university records **prove**, not what the applicant claims. Moderation Service builds them before calling this endpoint. If the claims were checked instead, every liar would pass.
- Server Rules stores nothing about the applicant. `applicant_id` is only used in logs.
- Errors: `404 RULESET_NOT_FOUND`, `422 INVALID_FACTS`.

##### Message queue events

None. Server Rules neither publishes nor consumes events.

#### University Record Service

##### Consumed API endpoints

None. University Record never calls other services. It learns about applicants and sessions from events.

##### Exposed API endpoints

###### `POST /api/v1/applicants/next` - consumed by: no service yet

**Description.** Creates a new applicant, starting from the university's own records (for example, a real student taken from the enrollment list). University Record stores the records, publishes `applicant.initialized` and returns the new `applicant_id`.

**Payload.** Same as in Applicant Service: `{ "session_id": "...", "difficulty": 3 }`.

**Response.** `201 Created`, same as in Applicant Service: `{ "applicant_id": "...", "session_id": "...", "created_at": "..." }`.

**Usage.** Like the same endpoint in Credential Service, this lets University Record be the first service to meet a new applicant, as the topic allows. No service calls it yet.

###### `GET /api/v1/records/{category}` - consumed by Client

**Description.** A Junior Moderator searches one record category, for example "is student ID FAF231017 on the enrollment list?". A player can only search the categories assigned to them in the current session.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `session_id` | UUID | yes | The session the player is playing in |
| `q` | string | yes | What to look for: a name, student ID, email or course code |
| `limit`, `offset` | integer | no | Pagination, as in the API conventions |

**Payload.** None.

**Response.** `200 OK`. Example for `enrollment` with `q=FAF231004`:

```json
{
  "category": "enrollment",
  "academic_year": "2026-2027",
  "items": [
    { "student_id": "FAF231004", "name": "Ana Rusu", "major": "FAF", "group": "FAF-231", "year": 2, "enrolled_since": "2025-09-01", "status": "enrolled" }
  ],
  "total": 1
}
```

Fields of one record in each category:

| Category | Fields |
| --- | --- |
| `enrollment` | `student_id`, `name`, `major`, `group`, `year`, `enrolled_since`, `status` (`enrolled`, `graduated`, `expelled`); the response also has `academic_year` |
| `email-groups` | `email`, `name`, `groups` (for example `faf-students`, `faf-231`, `teaching-assistants`, `staff`) |
| `courses` | `course_code`, `title`, `semester`, `schedule[] { day, time, room }`, `registered_student_ids[]` |
| `fcim-logs` | `message_id`, `author_name`, `author_email`, `channel`, `content`, `sent_at` |

**Usage.**

- The calling player must have `category` in their `record_scopes` for this `session_id` (received with `session.started`). Otherwise the answer is `403 CATEGORY_NOT_ASSIGNED`. The Moderator has no categories.
- After `session.ended`, every request for that session gets `403 SESSION_ENDED`.
- An empty `items` list is a valid answer: it means the records know nothing about what was searched, which is often the clue.
- Errors: `403 CATEGORY_NOT_ASSIGNED`, `403 SESSION_ENDED`, `422 UNKNOWN_CATEGORY`.

###### `GET /api/v1/applicants/{applicant_id}/records` - consumed by Moderation Service

**Description.** Returns, across all categories at once, what the university records say about the identity the applicant claims (their student ID, email and name). Moderation Service uses it to spot lies and to build the verified facts it sends to Server Rules.

**Payload.** None.

**Response.** `200 OK`

```json
{
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "academic_year": "2026-2027",
  "enrollment": [],
  "email_groups": [],
  "courses": [
    { "course_code": "PAD", "title": "Distributed Applications Programming", "exists": true, "registered": false },
    { "course_code": "ELSE-NET", "title": null, "exists": false, "registered": false }
  ],
  "fcim_logs": []
}
```

The lists hold the same records a junior would find by searching, but for every category at once. Empty lists mean the university knows nothing about the claimed identity. In this example, that is how Moderation sees that the "FAF student" is really an outsider. For each claimed course, `courses` says whether the course exists and whether the claimed student is registered for it.

**Usage.** This endpoint gives full read access to all categories, so it is only for services (see the note on University Record access above). `404 APPLICANT_NOT_FOUND` if the applicant does not exist.

##### Message queue events

**Published:**

- `applicant.initialized` - consumed by Applicant Service, Credential Service  
  Same payload as in Applicant Service, with `"initialized_by": "university-record-service"`. Sent only when University Record is the first service contacted.

**Consumed:**

- `applicant.initialized` - published by Applicant Service or Credential Service  
  Creates the university's records from `actual`, the truth. An outsider gets no enrollment record, and someone who lies about their year has their real year on record. This is how the juniors can find the lie. Events where `initialized_by` is `university-record-service` are ignored.
- `session.started` - published by Server Moderation Session Service  
  Stores the `record_scopes` of every junior for this session. From now on, their searches are checked against these scopes.
- `session.ended` - published by Server Moderation Session Service  
  Closes access for that session, so players cannot read records after the shift.

#### Moderation Service

##### Consumed API endpoints

- `GET /api/v1/sessions/{session_id}` - available in Server Moderation Session Service  
  Checks that the session is active, that the calling player is its Moderator and that the applicant is the current one, and reads the shift's `ruleset_version`.
- `GET /api/v1/applicants/{applicant_id}` - available in Applicant Service  
  Reads what the applicant claims about themselves.
- `GET /api/v1/applicants/{applicant_id}/documents/validation` - available in Credential Service  
  Reads every document with its validation status.
- `GET /api/v1/applicants/{applicant_id}/records` - available in University Record Service  
  Reads what the university records say about the claimed identity, across all categories.
- `POST /api/v1/rulesets/{version}/evaluations` - available in Server Rules Service  
  Checks the verified facts against the ruleset of the shift.

##### Exposed API endpoints

###### `POST /api/v1/decisions` - consumed by Client

**Description.** The Moderator submits a decision about the current applicant. Moderation Service gathers the data, works out what the correct decision would have been, compares the two, stores the result and replies straight away.

**Payload.**

```json
{
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "action": "accept",
  "granted_channels": ["general"]
}
```

`granted_channels` lists the server channels the Moderator lets the applicant into. It is required when `action` is `accept` and must be left out for the other actions.

**Response.** `201 Created`

```json
{
  "decision_id": "e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8",
  "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
  "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
  "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
  "action": "accept",
  "granted_channels": ["general"],
  "is_correct": false,
  "expected_action": "ban",
  "allowed_channels": [],
  "violated_rules": [
    { "rule_id": "only-faf-or-teachers", "description": "Only FAF students and FAF teachers may join" }
  ],
  "reasons": ["The student ID card is forged", "The university has no record of student ID FAF231017"],
  "penalty": 30,
  "ruleset_version": 7,
  "decided_at": "2026-09-10T18:14:00Z"
}
```

**Usage.** The steps behind one decision:

1. Call `GET /api/v1/sessions/{session_id}`. The session must be `active`, the calling player must be its `moderator_id`, and `applicant_id` must be its `current_applicant_id`.
2. If this applicant already has a decision, stop with `409 ALREADY_DECIDED`. A decision is never changed after it is written.
3. Call Applicant, Credential and University Record in parallel. At the same time, look up the claimed student ID in Moderation's own ban list.
4. Build the verified facts from the records (not from the claims) and send them to Server Rules with the shift's `ruleset_version`.
5. Work out the expected action. The rows are checked from top to bottom, and the first one that matches wins:

   | Situation | Expected action |
   | --- | --- |
   | A document is `forged`, or the records for the claimed student ID or email belong to a different person | `ban` |
   | Server Rules answers `"admitted": false` (for example, not a FAF student, or banned before), or a document is `expired` | `reject` |
   | A document is `inconsistent` or `incomplete`, so the claims cannot be confirmed | `flag` |
   | None of the above | `accept`, with `granted_channels` equal to `allowed_channels` |

6. Store the decision with a snapshot of the data behind it. If `action` is `ban`, add the claimed student ID and name to the ban list. Publish `decision.recorded` and reply.

Further rules:

- `flag` is a final decision like the others. The applicant does not come back later in the shift.
- An `accept` whose `granted_channels` differ from `allowed_channels` counts as incorrect.
- The penalty is 0 for a correct decision and grows with how harmful the mistake is. Letting in someone who should have been banned costs the most.
- Errors: `403 NOT_MODERATOR`, `404 SESSION_NOT_FOUND`, `404 APPLICANT_NOT_FOUND`, `409 SESSION_NOT_ACTIVE`, `409 NOT_CURRENT_APPLICANT`, `409 ALREADY_DECIDED`, `422 GRANTED_CHANNELS_REQUIRED`.

###### `GET /api/v1/decisions` - consumed by Client

**Description.** Lists recorded decisions, for example for the summary at the end of a shift.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `session_id` | UUID | no | Only decisions of this session |
| `applicant_id` | UUID | no | Only decisions about this applicant |
| `moderator_id` | UUID | no | Only decisions made by this Moderator |
| `limit`, `offset` | integer | no | Pagination, as in the API conventions |

**Payload.** None.

**Response.** `200 OK`: `{ "items": [ ... ], "total": 6 }`, where every item is a decision object shaped like the response of `POST /api/v1/decisions`.

###### `GET /api/v1/bans` - consumed by Client

**Description.** Checks whether someone was banned before. Any player can use it while investigating an applicant.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `q` | string | yes | A student ID or a name |
| `limit`, `offset` | integer | no | Pagination, as in the API conventions |

**Payload.** None.

**Response.** `200 OK`

```json
{
  "items": [
    {
      "student_id": "FAF231017",
      "name": "Ion Popescu",
      "banned_at": "2026-09-03T17:20:00Z",
      "decision_id": "e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8",
      "session_id": "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
    }
  ],
  "total": 1
}
```

**Usage.** The ban list is filled only by Moderation's own `ban` decisions, and entries are never removed. An empty `items` list means the person was never banned.

##### Message queue events

**Published:**

- `decision.recorded` - consumed by Server Moderation Session Service  
  A decision has been stored. Session uses it to update the score, the penalties and the counters.

  ```json
  {
    "decision_id": "e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8",
    "session_id": "3a7e9b1c-2d4f-4b6a-8c0e-1f2a3b4c5d6e",
    "applicant_id": "5d2c8e4a-7b1f-4c3d-9e6a-0b8f2d4c6e13",
    "moderator_id": "8c1f6a2e-5b7d-4e1a-9c3f-2d4b6a8e0f11",
    "action": "accept",
    "is_correct": false,
    "expected_action": "ban",
    "violated_rules": [{ "rule_id": "only-faf-or-teachers", "description": "Only FAF students and FAF teachers may join" }],
    "penalty": 30
  }
  ```

**Consumed:** none.

#### Discord DMs Service

##### Consumed API endpoints

None. Discord DMs never calls other services. Everything it needs about a session arrives with `session.started` and `session.ended`.

##### Exposed API endpoints

###### `GET /api/v1/ws` - consumed by Client (WebSocket)

**Description.** Opens the real-time chat connection of one player in one session. The HTTP request is upgraded to a WebSocket, and after that, JSON messages travel both ways.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `session_id` | UUID | yes | The session whose channels the player wants to use |

**Payload.** None for the upgrade request. After the connection is open, the messages look like this:

```json
{ "type": "message.send", "channel_id": "d4e5f6a7-b8c9-4d0e-a1f2-b3c4d5e6f7a8", "content": "FAF231017 is not on the enrollment list" }
```

```json
{ "type": "message.new", "message": { "message_id": "f6a7b8c9-d0e1-4f2a-b3c4-d5e6f7a8b9c0", "channel_id": "d4e5f6a7-b8c9-4d0e-a1f2-b3c4d5e6f7a8", "author_id": "b2d4f6a8-1c3e-4a5b-9d7f-0e2c4a6b8d10", "content": "FAF231017 is not on the enrollment list", "sent_at": "2026-09-10T18:12:30Z" } }
```

```json
{ "type": "error", "error": { "code": "CHANNEL_ACCESS_DENIED", "message": "You cannot write in #faculty-check" } }
```

The client sends `message.send`. The server stores the message and pushes `message.new` to every player who can see that channel, the sender included. It pushes `error` when a message is refused.

**Response.** `101 Switching Protocols` when the connection is accepted. `403 NOT_IN_SESSION` if the calling player is not a member of the session, and `409 SESSION_NOT_ACTIVE` if the shift has not started or is already over.

**Usage.** Discord DMs only moves messages; it never checks whether what players write is true. When `session.ended` arrives, the server closes every connection of that session.

###### `GET /api/v1/sessions/{session_id}/channels` - consumed by Client

**Description.** Lists the channels the calling player can see in this session.

**Payload.** None.

**Response.** `200 OK`

```json
{
  "items": [
    { "channel_id": "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7", "name": "general-mod-chat", "archived": false },
    { "channel_id": "d4e5f6a7-b8c9-4d0e-a1f2-b3c4d5e6f7a8", "name": "enrollment-check", "archived": false }
  ],
  "total": 2
}
```

**Usage.** Who can see which channel is worked out from `session.started`:

| Channel | Who can see it |
| --- | --- |
| `general-mod-chat` | everyone in the session |
| `enrollment-check` | the Moderator and juniors with the `enrollment` scope |
| `course-registration` | the Moderator and juniors with the `courses` scope |
| `faculty-check` | the Moderator and juniors with the `email-groups` or `fcim-logs` scope |

`403 NOT_IN_SESSION` if the calling player is not a member of the session.

###### `GET /api/v1/channels/{channel_id}/messages` - consumed by Client

**Description.** Returns the message history of a channel, so a client that reconnects can catch up.

**Query params.**

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `limit` | integer | no | How many messages to return, 50 by default |
| `offset` | integer | no | How many of the newest messages to skip |

**Payload.** None.

**Response.** `200 OK`: `{ "items": [ ... ], "total": 120 }`, where every item has the shape of `message` in `message.new` above. The newest message comes first. `403 CHANNEL_ACCESS_DENIED` if the calling player cannot see the channel.

**Usage.** History stays readable after the shift ends, because the channels are archived, not deleted.

##### Message queue events

**Published:** none.

**Consumed:**

- `session.started` - published by Server Moderation Session Service  
  Creates the four channels of the session and the access mapping of every player, using `moderator_id` and each junior's `record_scopes`.
- `session.ended` - published by Server Moderation Session Service  
  Archives the channels of the session (they become read-only) and closes its WebSocket connections.

---

## Branch management

### Main branches

- `main` - production code, deployed on each release
- `dev` - branch that serves as a target for features, bug resolves, staging

### Branch protection rules

Branches are protected by following rules:

1. Protect main and dev - No direct push in `main` and `dev`. PR required. Branches cannot be deleted,
   updated or force pushed without the user being in bypass list
2. Enforce branch naming - We follow a standardized naming pattern for all feature branches:

```
type/issueID-short-description
```

### Branch Types

| Prefix      | Purpose                   | Example                           |
| ----------- | ------------------------- | --------------------------------- |
| `features/` | New functionality         | `features/23-user-authentication` |
| `bugs/`     | Bug fixes                 | `bugs/15-header-alignment`        |
| `hotfix/`   | Critical production fixes | `hotfix/18-server-crash`          |
| `chore/`    | Maintenance tasks         | `chore/9-dependency-updates`      |

### Naming Guidelines

- Use lowercase letters and hyphens
- Keep descriptions concise but descriptive
- Always include the related issue number

## Merge requirements

## Merging Strategy

**Strategy**: Squash and Merge

Benefits:

- Clean, linear commit history
- Combines all commits from a feature branch into a single commit
- Easier to track features and revert if necessary
- Reduces noise in the main branch history

Process:

1. Create feature branch from `dev`
2. Make commits with your work
3. Open Pull Request to `dev`
4. After approval, squash and merge
5. Delete feature branch after merge

## Pull Request Requirements

Every Pull Request must include:

### Required Information

- **Clear description** of what changed and why
- **Issue reference** (e.g., "Closes #42", "Fixes #18")
- **List of specific changes** made
- **Testing instructions** or results
- **Screenshots** for UI changes
- **Breaking changes** (if any)

### PR Template

We use the following template (located at `.github/PULL_REQUEST_TEMPLATE.md`):

```markdown
Closes #(issue)

# Changes

1.
2.
3.

## Additional Notes
```

## Testing Standards

- All new functions should have corresponding tests
- Existings tests will run as a githook
- Manual testing steps must be documented in PR
- GitHub Actions to be configured for automatic testing
- All PRs must pass automated tests before merging

## Versioning Strategy

We follow **Semantic Versioning (SemVer)**: `MAJOR.MINOR.PATCH`

### Version Types

- **MAJOR** (e.g., 1.0.0 → 2.0.0): Breaking changes that require user action
- **MINOR** (e.g., 1.0.0 → 1.1.0): New features that are backward compatible
- **PATCH** (e.g., 1.0.0 → 1.0.1): Bug fixes and small improvements

### Release Process

1. Choose the new version number using the rules above
2. Create release notes documenting changes
3. Tag release in GitHub: `git tag v1.0.0`
4. Create GitHub Release with changelog
5. Deploy to production

### Release Notes Format

```markdown
## [1.2.0] - 2026-09-09

### Added

- User authentication system
- Dashboard analytics

### Changed

- Improved login flow UX
- Updated API endpoints

### Fixed

- Header alignment on mobile devices
- Memory leak in data processing

### Security

- Updated dependencies with security patches
```

## Workflow Summary

1. **Create Issue**: Document the feature/bug with clear requirements
2. **Create Branch**: Use proper naming convention from `dev` branch
3. **Develop**: Make commits with clear, descriptive messages
4. **Test**: Verify functionality and pass the tests
5. **Create PR**: Follow template and provide complete information
6. **Review**: Address feedback and get required approvals
7. **Merge**: Squash and merge to `dev`
8. **Deploy**: Regular releases from `dev` to `main`
