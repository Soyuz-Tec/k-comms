# ADR-0068: Reclaim an instant room's whiteboard when the room expires

- **Status:** Accepted
- **Date:** 2026-08-02
- **Owners:** Collaboration, Conversations, Privacy, and Operations
- **Reviewers:** Security, Release and Quality
- **Related requirements:** FR-COL-001, FR-SYNC-001, ADR-0049, ADR-0063, ADR-0065

## Context

ADR-0065 gave self-service instant rooms a durable whiteboard and made `/` the
public front door for creating them. It bounded what a guest can *write* — a
cluster-wide `instant_room_whiteboard` fixed-window bucket permitting 240
committed batches per minute — and it ends every REST and realtime path to a
board the moment a room expires.

It did not bound what a guest leaves *behind*.

Room expiry archives. `EphemeralRooms.Lifecycle.expire` marks the room
`:expired`, sets `archived_at` on the conversation, revokes admissions,
memberships, guest links, and call access. No whiteboard row is touched. Three
mechanisms could have reclaimed the board afterwards and none does:

- **Retention** enqueues only `target_type: :message`. It never enqueues a
  conversation, so an archived instant-room conversation is never collected.
- **Governance erasure** does delete boards, but only when executing a
  `DeletionRequest`. Nobody files one for an abandoned public room.
- **The foreign key** from `whiteboards` to `conversations` is
  `on_delete: :delete_all`, which is correct and never fires, because the
  conversation row is never deleted outside governance.

The result is unbounded durable residue on the most public endpoint in the
product. Per board the ADR-0063 caps still apply — 100,000 operations, 200
elements and 512,000 bytes per update — but the *number* of boards grows with
every visitor who draws and walks away.

ADR-0063 stated the underlying premise: "A board is a persistent document rather
than a message-age stream." That is right for a member conversation and wrong for
an instant room, and ADR-0065 inherited the assumption without revisiting it.

## Decision

An expiring instant room's whiteboard is reclaimed inside the same transaction
that ends access to it. `Lifecycle.expire_locked!` calls
`Whiteboards.discard_for_expired_room/3` after guest sessions, memberships,
links, and call access are revoked and the conversation is archived, and before
the room is marked expired. A failure rolls the whole expiry back.

Reclamation is a distinct entry point from governance erasure, not a reuse of
it. The two are mechanically identical — both delete the operation log and the
board row scoped by tenant and conversation — and semantically different.
Governance erasure answers a legal deletion request and carries audit evidence
proving a compliance obligation was met. This answers room expiry and is routine
lifecycle reclamation. One shared entry point would leave audit queries unable
to distinguish a compliance deletion from a housekeeping one.

Scope is unchanged in every other respect. Durable conversation boards remain
persistent documents, reachable only by governance. `discard_for_expired_room/3`
refuses to run outside a transaction, because reclaiming after the expiry commit
would leave a window in which the rows outlive the authority to read them, and a
crash inside that window would leak them permanently.

The expiry event now carries `whiteboards_discarded` and
`whiteboard_operations_discarded` so reclamation is observable rather than
silent.

This decision covers rooms expiring from now on. Boards belonging to rooms that
have **already** expired are untouched and require a separate reconciliation
decision, because that would delete existing tenant content.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Extend retention to archived conversations | Reuses an existing scheduled path | Retention is message-age based; ADR-0063 explicitly rejected treating a board as a message-age stream, and this would sweep durable member conversations too | Wrong mechanism and far wider blast radius than the problem |
| A separate sweeper worker for expired rooms | Keeps expiry unchanged; batches the deletes | Leaves a window where an expired room's rows outlive its authority, and a missed job leaks silently forever | The atomicity is the point |
| Call `erase_for_governance/4` from expiry | No new function; least code | Audit evidence could no longer distinguish compliance deletion from routine expiry | Conflates a legal obligation with housekeeping |
| Retain boards indefinitely and cap room creation instead | No deletion semantics to reason about | Caps the front door the product deliberately opened; residue still grows within the cap | Treats the symptom and damages the feature |
| Grace period before reclamation | Tolerates late conversion of a room | ADR-0065 conversion happens on an active room, never after expiry | Protects against a path that does not exist |

## Consequences

### Positive

- Durable storage from public instant rooms is now bounded by live rooms rather
  than by cumulative visits.
- Reclamation cannot half-apply: it shares the expiry transaction.
- Expiry telemetry reports what was reclaimed.

### Negative and accepted trade-offs

- An expired room's canvas is unrecoverable. This matches the room's own
  lifecycle — access already ended irreversibly at expiry — but it is now data
  loss rather than inaccessible data.
- Expiry does slightly more work inside its transaction. It is two scoped
  deletes against indexed tenant and conversation columns.
- Instant-room boards and member-conversation boards now have different
  lifecycles. That divergence is intentional and must stay documented, or a
  later change will "unify" them and reintroduce this leak.

### Operational consequences

No migration. No schema change. Storage for expired rooms stops growing from the
next expiry onward. Rooms that expired before this change still hold their
boards; the count of orphaned boards should be measured before deciding on a
backfill.

### Security and privacy consequences

Guest-authored content stops outliving the guest's access. Reclamation is scoped
by tenant *and* conversation, so it cannot reach another tenant's board — this is
covered by a dedicated regression test rather than left to review. Governance
erasure, legal holds, and deletion-request evidence are unchanged; this path is
additional to them, never a substitute.

## Validation

- Core tests cover a board created in an instant room being gone after expiry,
  and another tenant's board surviving that same expiry untouched.
- The existing governance suite continues to prove conversation erasure and user
  neutralization, confirming the new path did not disturb them.
- The governance boundary test continues to pass: `Conversations` reaches
  `Whiteboards` through its facade, never through its schemas.
- Verified: 7/7 ephemeral-room lifecycle tests, 40/40 across whiteboards,
  governance boundary and ephemeral rooms, 2/2 lifecycle worker tests.

## Revisit triggers

- Instant rooms gain conversion to a durable conversation *after* expiry, which
  would need a grace period before reclamation.
- A backfill for already-expired rooms is approved, requiring its own decision
  about deleting existing tenant content.
- Whiteboards gain images, attachments, or other external objects whose blobs
  would also need reclaiming rather than only rows.
- Durable-conversation boards are given an expiry policy, at which point the two
  lifecycles should be reconciled deliberately rather than by drift.
