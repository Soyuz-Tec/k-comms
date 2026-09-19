# ADR-0083: Bound whiteboard scenes and recover capacity with clear epochs

- **Status:** Accepted
- **Date:** 2026-09-19
- **Owners:** Collaboration, Web client
- **Related:** ADR-0069, ADR-0070, ADR-0077, ADR-0078

## Context

Per-update limits did not bound a scene accumulated over many updates. The
100,000-operation lifetime limit also rejected `board.clear`, permanently
preventing recovery. Removing operation history to reset this counter would
bypass retention and legal holds.

## Decision

Under the existing board row lock, validate the merged scene against 5,000
distinct element IDs and 2 MiB of JSON encoded as `{"elements": [...]}`. Count
deleted elements too: their tombstones suppress stale client resurrection.
Replacement versions retain the established version/nonce winner and paint
order. Rejected mutations consume neither a sequence nor an idempotency key.

Reuse the latest clear's sequence as an epoch boundary. Allow at most 100,000
scene updates since that clear; an authorized clear is always permitted. Clear
appends a new operation and immediately materializes an empty snapshot. It never
resets the canonical sequence or deletes operation history, including under a
legal hold. Old client retries remain idempotent, and a scene update based on an
earlier epoch remains rejected.

Capacity checking reuses a current snapshot and streams its remaining epoch in
batches of ten operations into a bounded element index. After invalidation it
starts after the latest clear, never at a prior epoch. Snapshot creation reuses
this checked projection. Clear does not load an old snapshot's payload or fold
old operations, so a legacy oversized scene can recover explicitly. Existing
oversized scenes are not silently trimmed; they remain available to read/export
and reject further drawing until an authorized participant clears them.

The existing `whiteboard_capacity_exceeded` HTTP 409 now directs the user to
Clear. The browser stops automatic retries for this condition and retains its
unsynced recovery batches. Failed clear preserves them; an acknowledged local
or remote clear removes obsolete batches and resumes normal writes. Reload may
attempt one retained batch to discover whether capacity has changed.

## Consequences and alternatives

Scene storage and projection memory are bounded for new successful updates.
Projection costs CPU on each write; normal replay is at most the configured
snapshot interval, while invalidation may stream up to 100,000 operations in the
current epoch. This is a correctness bound, not a measured throughput target.
Legacy oversized snapshots can still be read until explicit clear. Operation
history can grow across epochs and remains governed by the existing retention
and legal-hold policy; these limits are not a tenant storage quota.

Silently deleting tombstones/history could restore old data or violate holds.
Automatically clearing would discard a shared scene without participant intent.
Persisting a new per-element table would add migrations and another erasure
contribution before throughput data demonstrates that need. The present change
adds no schema, facade operation, or response shape.

## Validation

Synthetic PostgreSQL tests exercise count and cumulative byte limits, same-ID
replacement, duplicate retries, legacy capacity recovery, holds, monotonically
increasing sequences, snapshot invalidation across epochs, and two authors on
separate connections competing for the final element slot. Browser tests cover
capacity retry suppression, failed-clear preservation, and successful recovery.
Existing snapshot, erasure-race, controller, and whiteboard tests remain required.
