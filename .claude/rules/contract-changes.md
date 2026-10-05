# Contract changes

`README.md` "Communication Contract" is the source of truth for cross-service behavior. A contract
change is any change to:

- an endpoint under "Endpoints": path, query params, payload, response, status or error codes
- an event in the "Event catalog": `event_type`, envelope, payload, producer or consumers, or the "Event delivery" rules
- "Shared values", "Identity model", "Shared identifiers", "Gateway" or "API conventions"
  (authentication, errors, task timeout and concurrent limit included)

## Before changing

1. Find every consumer: the endpoint's "consumed by" line, the event catalog's "Pushed to"
   column and the "Every arrow in the diagram" table. Check Moderation Service first; it calls
   five services.
2. Classify the change. Breaking: a field removed, renamed or retyped, a new required field, a
   changed meaning, status or error code. Anything else is additive.
3. Breaking change with a consumer you do not own: draft an issue for its owner (see
   `submodule-management.md`, write scope).

## When changing

- Update the README section in the CPR PR that bumps the submodule pointer.
- Update `docs/<SERVICE>.md` and the Postman collection.
- Bump the image version within the lab's `N.x.y` (README "Versioning Strategy"): MINOR for
  additive, PATCH for a fix. A breaking change waits for the next lab's MAJOR, or needs the whole
  team's agreement and every affected consumer shipping in the same lab.
- Breaking event payload change: bump the envelope `version` of that event by one. Consumers
  reject versions they do not know.
- Identity model changes apply to Applicant, Credential and University Record together;
  `REFERENCE_YEAR` stays identical in all three.

## Divergences

- When the code differs from the contract, do not edit the contract to match the code. Record the
  divergence in `docs/<SERVICE>.md` and as a README note next to the affected section ("Not yet
  wired", "Known gap").
- Endpoints no other service or client flow depends on are beyond the contract: document them in
  `docs/<SERVICE>.md` only, with a README pointer (as Player Service does).
