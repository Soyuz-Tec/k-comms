# Data Retention and Deletion

## Required policy dimensions

- Tenant-default retention period
- Conversation-specific override
- Legal hold
- User account deletion
- Tenant termination
- Attachment and generated-variant retention
- Whiteboard operation history, including operations before a collaborative
  clear. A board is a persistent document rather than a message-age stream:
  legal hold blocks governance erasure, user erasure neutralizes that user's
  authored scene updates, and conversation erasure removes the board and its
  operations. Automated history compaction or a separate age policy requires
  a snapshot-preserving follow-up design.
- Audio/video call lifecycle and participant-admission retention after completed
  eviction; pending/enforcing eviction state must not be removed early
- Audit-record retention
- Backup expiration and deletion lag
- Instant-room aggregate, link/admission evidence, idempotency digests, and
  durable presence-lease retention for the configured public tenant

The baseline has no retention period for live audio, camera, screen-share,
recording, transcript, snapshot, SDP, ICE, RTP/SRTP, or participant token data
because K-Comms must not persist it. Enabling provider recording, egress,
transcription, or media-derived analytics requires a separate ADR, data-purpose
approval, consent model, deletion contract, and retention schedule before use.
- Search-index and cache removal

## Deletion workflow

1. Validate authority and legal-hold state.
2. Record an auditable deletion request.
3. Remove or tombstone authoritative rows according to policy.
4. Enqueue deletion for object storage and derived projections.
5. Reconcile completion across systems.
6. Produce evidence without retaining deleted content.

Deletion semantics must be defined before selecting partitioning and archival strategies.

### Derived-content completion

[ADR-0078](../02-architecture/adr/0078-complete-derived-content-erasure.md) binds
completion to removal of message content from outbox and webhook copies, terminal
delivery state, and invalidation of user-erased whiteboard snapshots. A bounded
webhook send that already started finishes before erasure commits; canceled or
abandoned claims cannot start a later send. Previously delivered third-party
copies remain subject to the receiver's deletion contract.

The minute `ErasureReconcilerWorker` repairs at most 100 previously completed
requests per run. It processes only completed, already-approved erasures missing
`evidence.derived_erasure_version = 1`. Repair timestamps and audit records contain
no erased content. Failed jobs remain retryable and the request is not marked
repaired until all owner contributions commit. One request can cover many records,
so operators must also watch transaction duration and worker queue age.

After upgrade, verify the reconciler has completed and no completed request lacks
the version marker before declaring historical copies removed. Read-only evidence
query for a controlled operator session:

```sql
SELECT count(*) AS remaining_derived_erasure_repairs
FROM deletion_requests
WHERE status = 'completed'
  AND coalesce(evidence->>'derived_erasure_version', '') <> '1';
```

Release tests use synthetic data; a zero count from those tests is not evidence
about staging or production. Backups retain their separately governed expiration.

## Instant-room lifecycle and retention

An instant room becoming idle or expired is an authorization transition, not a
content-deletion shortcut.

- Guest-owned rooms expire after 3,600 seconds of authoritative inactivity;
  registered-owner rooms expire after 86,400 seconds. Presence renews every 30
  seconds, leases for 90 seconds, and has a 90-second reconnect grace.
- Expiry ends active instant admissions and memberships, revokes derived guest
  sessions and call authority, and leaves durable deletion to each data owner.
- Messages and revisions remain under ConversationContent retention. Call
  lifecycle remains under Calls retention. Audit, moderation, legal holds,
  deletion evidence, backups, and derived projections retain their existing
  owner policies. Legal hold never restores access to an expired room.
- Replay authority ends after ten minutes. The minute reconciler erases
  expired create-response ciphertext, nonce, tag, and key identifier in bounded
  batches, while its non-secret digest/fingerprint/erasure tombstone remains
  with room evidence to prevent key reuse from creating another room. Human
  join receipts remain conflict tombstones for twenty-four hours after replay
  expiry and are then pruned in bounded batches; guest-join digest/fingerprint
  evidence follows its admission retention but cannot replay after expiry.
  Terminal presence leases are pruned after reconnect grace plus a one-hour
  incident window. Capsule plaintext and raw keys are never persisted. These
  metadata classes may not retain plaintext connection identifiers, email
  addresses, client IPs, message content, or media identifiers.
- Room/link/admission lifecycle evidence is retained long enough to explain
  access, expiry, abuse decisions, and erasure outcomes. Governance then
  coordinates deletion or tombstoning with the owning contexts.
- Optional self-service account creation preserves the same user identifier and
  communication history. The submitted email is not a verified-email claim;
  production remains disabled until an approved verification provider and
  retention contract are operating.

Feature disablement blocks create, preview, join, and instant-room account
conversion but does not delete existing rows or stop presence/lifecycle
convergence for existing rooms. Before rollback to code that predates instant
rooms, operators must prove there are no incompatible conversation-only
identities, ephemeral-room rows, guest-link purpose values, or active lifecycle
jobs, or select a compatible bridge/roll-forward release. Direct schema
rollback or widening retained identities to workspace scope is prohibited.
