# Scope and Non-goals

## First production scope

- Tenant, user, device, and session management
- Direct and group conversations
- Channels, membership, and roles
- Durable messages, edits, deletions, reactions, mentions, and replies
- Presence, typing indicators, read cursors, and unread state
- One-to-one and group audio/video calls with explicit capture controls and
  screen sharing through an external media-plane boundary
- Attachments through object storage
- Push/email notification pipeline
- Search over authorized content
- Administration, moderation, audit, and retention
- Public API and outbound webhooks
- Multi-zone production deployment and disaster-recovery procedure

## Proposed non-goals for the first release

- Active-active multi-region writes
- Built-in custom audio/video transport, recording, transcription, SIP, and
  arbitrary media egress; calls use the separately operated LiveKit boundary
- General-purpose workflow automation engine
- Cross-organization federation
- Client-side end-to-end encryption unless explicitly approved before build
- Unlimited historical import formats
- Per-message blockchain or distributed-ledger storage

Non-goals must be reviewed with product leadership before detailed estimation.
