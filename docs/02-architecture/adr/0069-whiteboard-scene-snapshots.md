# ADR-0069: Materialise whiteboard scenes so joining is not O(history)

- **Status:** Accepted
- **Date:** 2026-08-02
- **Owners:** Collaboration, Web, and Operations
- **Reviewers:** Security, Release and Quality
- **Related requirements:** FR-COL-001, FR-SYNC-001, ADR-0063, ADR-0065, ADR-0068

## Context

ADR-0063 made the operation log authoritative and deferred compaction: "A board
is a persistent document rather than a message-age stream; automatic history
compaction requires a later snapshot-preserving decision." This is that decision.

A fresh join replays every operation since the last clear, paged 500 at a time.
Cost grows with the board's whole life, not with its content. A board holding a
few dozen shapes but twenty thousand operations — ordinary for a long-lived
design conversation, because every drag commits — costs forty round trips and a
large transfer before anything renders. Reconnects are frequent on mobile, so the
cost is paid repeatedly, and boards are capped at 100,000 operations, so the
worst case is five times worse again.

Nothing about this is a correctness problem. It is latency and payload, and it
degrades monotonically with board age.

## Decision

Each board keeps one materialised scene in `whiteboard_snapshots`: the projected
elements, the sequence they were folded through, and the clear generation they
belong to.

**Maintenance is inline, not scheduled.** `Commands.append/3` rematerialises when
enough operations have accrued, inside the transaction that already holds the
board row `FOR UPDATE`. That lock is what makes it safe — the snapshot is written
against exactly the sequence the caller allocated, so it can never describe an
operation another writer has not committed. A background job would need its own
locking and could lag arbitrarily behind.

**Rebuilds are incremental.** The existing snapshot plus operations since it is
folded forward, so cost is proportional to the delta rather than to history. A
snapshot from a superseded generation is discarded and rebuilt from the clear.

**Serving is opt-in.** `list_operations/3` returns a snapshot only when the
caller passes `snapshot: true` *and* is doing a fresh replay. An older client
that does not ask receives the full replay exactly as before, so a rolled-back
application image still serves a complete scene. An incremental caller is never
handed one: it already holds a scene, and replacing it wholesale would discard
edits it applied locally but has not read back.

**A snapshot is not an operation.** It is returned in its own field rather than
synthesised as a `scene.update`. A synthetic operation would need an actor and an
idempotency key it does not have, and inventing them would corrupt exactly the
audit trail the log exists to provide.

**The log is not truncated.** See below.

## Log truncation is deliberately excluded

The original finding proposed snapshots *and* truncation. Truncation is withheld,
and not for effort reasons.

Whiteboard operations sit inside the same governance envelope as other Restricted
content. Legal holds are evaluated per conversation in the deletion workflow;
retention, deletion evidence, and audit all assume the log is intact. Truncating
it is therefore a *retention policy* decision — what history must survive, for
how long, and under which holds — not an engineering optimisation. Making that
call inside a performance change would quietly narrow a compliance guarantee.

Snapshots deliver the latency and payload win on their own, which is what the
finding actually cost. Bounding storage is a separate decision with a separate
owner.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Background snapshot worker | Keeps append fast; batches work | Needs its own locking, can lag arbitrarily, and a missed job silently restores the O(history) join | The board lock in `append` is already exactly the right barrier |
| Snapshot as a synthetic `scene.update` | No contract change; unmodified clients benefit | Requires fabricating an actor and idempotency key | Corrupts the audit meaning of an operation |
| Rewrite the log: replace folded operations with one compaction operation | Bounds storage as well as latency | Destroys history that may be under legal hold | Retention policy decision, not an engineering one |
| Client-side cache of the last scene | No server change | Does not help a first join, a new device, or a cleared cache | Solves the easy half of the problem |
| Always serve the snapshot when one exists | Simpler; no opt-in flag | A rolled-back image would serve partial scenes | Breaks the roll-forward/rollback guarantee ADR-0063 relies on |

## Consequences

### Positive

- A fresh join costs snapshot plus recent tail, independent of board age.
- Rebuild cost is proportional to the delta, not to history.
- The operation log stays authoritative and complete; snapshots are a cache that
  can be dropped and rebuilt at any time.

### Negative and accepted trade-offs

- One additional row per board, holding a second copy of the current scene.
- Every `@rebuild_interval`-th append does extra work inside its transaction.
  Interval is configurable because the right value differs between a member
  conversation and a public instant room.
- **Storage still grows with history.** Truncation is deferred, so this ADR
  addresses latency only.
- Both the member and guest clients now pass `snapshot=true` unconditionally.
  They do not reason about when a snapshot is available; the server decides and
  returns `null` when it is not, keeping that rule in one place.

### Operational consequences

Additive migration; older images ignore the table entirely. No backfill: boards
materialise on their next qualifying append, and until then serve full replays.
Snapshots may be deleted wholesale at any time with no loss — they rebuild.

### Security and privacy consequences

A snapshot holds the same Restricted content as the operations it summarises, in
the same tenant and conversation scope, with the same composite foreign keys and
cascade behaviour. Governance erasure and ADR-0068 expiry reclamation both
cascade to it through `whiteboard_id`. It creates no new read path: serving is
behind the same `authorize_use_whiteboard/2` check as replay.

## Validation

- A snapshot reconstructs exactly what a full replay would, over a log where the
  outcome depends on the version/nonce merge rule rather than accumulation.
- The snapshot is withheld unless the caller opts in.
- An incremental caller is never handed one.
- A clear invalidates the snapshot rather than resurrecting the cleared scene.
- A snapshot taken after a clear covers only the new generation.
- Client tests cover starting from a snapshot and continuing with the operations
  after it, a snapshot with no operations at all, replaying normally when the
  field is absent, paint order surviving the snapshot, and a snapshot-plus-tail
  producing the same scene as a full replay.
- Verified: 9/9 whiteboard core tests, 27 backend tests across core and web with
  no regression, 19 client tests, typecheck and lint clean, contract validation
  passing across both OpenAPI mirrors.

## Revisit triggers

- A retention policy for whiteboard history is agreed, enabling truncation.
- Join latency is measured against the pre-snapshot baseline on a board with
  substantial history, confirming the win in practice rather than by argument.
- Boards routinely exceed the operation cap, suggesting the cap rather than the
  join is the binding constraint.
- Snapshot rebuild cost becomes visible in append latency, suggesting the
  interval or the incremental strategy needs revisiting.
