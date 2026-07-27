# Data Retention and Deletion

## Required policy dimensions

- Tenant-default retention period
- Conversation-specific override
- Legal hold
- User account deletion
- Tenant termination
- Attachment and generated-variant retention
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
