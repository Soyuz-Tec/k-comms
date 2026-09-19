# ADR-0079: Persist retention work atomically and page its exclusions

Status: Accepted

## Context

A retention policy could commit before its initial scan was inserted. Recurring
workers ignored returned scheduling errors. Each scan loaded every historical
message deletion request before selecting a nominally bounded batch.

## Decision

Insert scan work in the same transaction as policy creation/update and its audit.
An idempotent policy replay also ensures scan work is scheduled. Oban insertion
enforces job uniqueness; failed recurrence scheduling causes a retryable worker
error instead of success.

An hourly authorized reconciler pages across active policies and tenant defaults,
at most 100 tenant IDs per invocation. It preserves available, scheduled, running,
and retryable scans, and repairs only missing work under a tenant advisory lock.
Continuation cursors prevent an unbounded sweep; retries are idempotent. The
Administration owner exposes only bounded IDs through the existing retention
reader. The reconciler also repairs historical orphaned policies after deployment.

The content owner selects at most 100 messages in stable `(inserted_at, id)`
order. The governance owner queries exclusions only for that bounded ID set,
using a concurrent partial index. Persist the next cursor in the successor job,
including when all candidates already have deletion work. At the end of a pass,
the next daily scan starts from the beginning so changed policy or newly eligible
older content is reconsidered. A failed deletion enqueue fails the page instead
of advancing past the failed candidate. Cursor validation and tenant filters remain
server-owned. Existing facade arities remain compatible.

## Consequences and alternatives

This eliminates application allocations proportional to deletion-request history
without allowing the messaging context to query governance-owned schemas. A
cross-context SQL anti-join was rejected because it weakens ownership. Policy and
conversation-scope inventory still scales with the tenant's current scopes and
is not claimed constant-memory. Keyset scans may defer newly eligible rows behind
the cursor until the next full daily pass. Failed/exhausted jobs remain visible
through Oban operations. Discarded chains are repaired on the next hourly sweep;
this does not replace queue monitoring or investigation of repeated failures.

## Validation and rollout

PostgreSQL regressions inject initial/update scheduling failures, verify policy
and audit rollback, repair an idempotent replay, page across 100 already-requested
messages to later eligible work, and preserve tied-timestamp ordering and tenant
isolation. Worker tests verify persisted cursors, daily reset, recurrence failure,
and idempotent repair without duplicating existing scheduled work. Run the
governance/messaging/worker suites and architecture checks.
The index is built concurrently and repairs an invalid interrupted build using
the existing repository helper. Deploy as a compatible forward migration;
application rollback retains the additive index and requires no data reversal.
