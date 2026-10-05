# Submodule management

The 8 service submodules are private. A person can read and write only their own two; the
professors can read all.

| GitHub handle | Submodules                                            |
| ------------- | ----------------------------------------------------- |
| DdimaPos      | `player-service`, `server-moderation-session-service` |
| IacovlevMaxim | `applicant-service`, `credential-service`             |
| dmracovit     | `moderation-service`, `discord-DMs-service`           |
| vvtttvv       | `server-rules-service`, `university-record-service`   |
| IacovlevMaxim | `gateway-service` (shared: the repository is Maxim's, every member contributes through PRs) |

The session owner is the git user; ask if it does not match a handle.

## Write scope

- Edit only submodules owned by the session owner.
- A change needed in someone else's service: describe it in chat or draft an issue for its
  owner. Never edit their directory.
- An empty submodule directory means no access, not an error.

## Delivery checklist

After a change in an owned submodule, check each item and report which are missing. Do not push
images, tags or commits unless asked.

1. Image version bumped per SemVer (README "Versioning Strategy"); MAJOR for a breaking contract
   change.
2. Image published to Docker Hub under that tag.
3. `docker-compose.yml` references the new tag.
4. README "Deployments" row current (image, host port, env vars).
5. `docs/<SERVICE>.md` reflects the change.
6. `postman/<service>.postman_collection.json` covers new or changed endpoints.
7. Submodule pointer in the CPR points to the delivered commit.
