# ADR-0078: Complete derived-content erasure and serialize dispatch

- **Status:** Accepted
- **Date:** 2026-09-19
- **Owners:** Governance, Collaboration, Integrations
- **Related:** ADR-0004, ADR-0039, ADR-0069, ADR-0075

## Context

Completed deletion blanked authoritative messages but retained message bodies in
outbox/webhook payloads. User whiteboard erasure neutralized operations but left
materialized snapshots readable. A stale fanout or inline snapshot rebuild could
restore an erased copy. Returning an external request before erasure also allowed
a send to begin after governance completion.

## Decision

Governance coordinates transaction-required erasure contributions from the outbox
and webhook owners. Their rows retain only a content-erased marker; webhook work
becomes terminal, and neither replay nor stale event fanout can restore it. Fanout
and replay lock/reload the canonical outbox event before acquiring endpoint and
delivery locks. The new Governance-to-Webhooks edge is one-way and explicit in the
strict context manifest; no owner accesses another owner's persistence schemas.

The integrated review also includes [ADR-0079](0079-atomic-bounded-retention-work.md).
Its exact manifest transition combines this one-way dependency, the merged public
facade registry digest, and the bounded retention tenant-inventory read query.
This records the union of the two reviewed changes against the same protected
base, with no additional exceptions or owner access.

The worker invokes `Integrations.dispatch_delivery/2` with its provider callback.
The core owner keeps its endpoint/delivery row locks for the bounded request.
Erasure waits for a send already executing; abandoned claims hold no transaction
and are canceled immediately. A stale claim cannot dispatch or record a result
after erasure. The detached `delivery_request/1` is owner-internal, disallowed for
released adapters. Existing webhook bodies and signatures remain compatible.
Data delivered before erasure completion cannot be recalled from a third party.

User whiteboard erasure locks the author write fence and affected board rows,
neutralizes operations and deletes their snapshots in one transaction. Appends
take the same author fence and reauthorize before acquiring the board lock. This
serializes new author writes and inline reconstruction with erasure, while
unrelated authors/boards remain independent. Snapshot cache invalidation does not
truncate operation history or change legal holds.

Existing completed erasures are repaired by an authorized minute reconciler in
batches of at most 100 requests, using the same owner locks and APIs. A partial
concurrent index selects unfinished repair evidence. New completions immediately
record `derived_erasure_version: 1`; historical repairs additionally record a UTC
timestamp and content-free audit. The persisted version is the resumable cursor.
The repair repeats only already-approved completed erasure, not new deletion, and
does not repeat object-store destruction. A later hold cannot resurrect content
whose erasure already completed; it does not block removal of these stale copies.

## Consequences and alternatives

Provider requests occupy a database connection/row locks for their bounded
duration. This deliberate cost provides a completion fence; materializing outside
the transaction or only rejecting fresh claims leaves a send/erase race. Removing
all message content from every webhook would change consumers' existing contract
and is not part of this correction. Rebuilding snapshots without the board lock
can resurrect erased content; deleting all tenant snapshots is unnecessarily broad.

There is no blocking data backfill migration. Historical closure requires deployed
reconciler completion evidence, not merely a successful release. Rollback to an
older runtime can recreate the original defect and must not be used after repair
without an explicit forward-fix plan. The additive index may remain on rollback.

## Validation

Synthetic PostgreSQL tests cover complete erasure, holds, tenant isolation, stale
fanout/replay, abandoned claims, provider dispatch racing completion, idempotent
historical repair, and both orderings of snapshot reconstruction versus erasure.
The architecture gate remains strict with zero exceptions added. Provider calls
in race tests are controlled callbacks; no external webhook endpoints are used.
