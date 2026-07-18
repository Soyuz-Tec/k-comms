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
