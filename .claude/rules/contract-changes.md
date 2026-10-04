# Contract changes

`README.md` "Communication Contract" is the source of truth for cross-service behavior. A contract
change is any change to:

- an endpoint under "Endpoints": path, query params, payload, response, status or error codes
- an event in the "Event catalog": routing key, envelope, payload, publisher or consumers
- "Shared values", "Identity model", "Shared identifiers" or "API conventions"

## Before changing

1. Find every consumer: the endpoint's "consumed by" line, the event catalog's "Consumed by"
   column and the "Every arrow in the diagram" table. Check Moderation Service first; it calls
   five services.
2. Classify the change. Breaking: a field removed, renamed or retyped, a new required field, a
   changed meaning, status or error code. Anything else is additive.
3. Breaking change with a consumer you do not own: draft an issue for its owner (see
   `submodule-management.md`, write scope).

## When changing

- Update the README section in the CPR PR that bumps the submodule pointer.
- Update `docs/<SERVICE>.md` and the Postman collection.
- Bump the image version: MAJOR for breaking, MINOR for additive.
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
