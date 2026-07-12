# Functional Requirements

**Status:** Draft seed list

| ID | Requirement | Priority | Acceptance summary |
|---|---|---|---|
| FR-ID-001 | Authenticate users and bind sessions to devices. | Must | Revocation prevents further authenticated commands. |
| FR-TEN-001 | Isolate tenant data and policy. | Must | Cross-tenant access tests fail closed. |
| FR-CONV-001 | Create direct, group, public, and private conversations. | Must | Membership and visibility rules are enforced. |
| FR-MSG-001 | Send a durable message with a client idempotency key. | Must | Retries return the same canonical message. |
| FR-MSG-002 | Edit and delete messages according to policy. | Must | History/tombstone behavior matches retention rules. |
| FR-MSG-003 | Support replies, reactions, mentions, and threads. | Should | Events and projections remain ordered and recoverable. |
| FR-RT-001 | Deliver authorized live events to connected clients. | Must | Events include stable identifiers and sequence positions. |
| FR-SYNC-001 | Recover missed durable events after reconnect. | Must | Client resumes from a stored cursor without gaps. |
| FR-PRES-001 | Show approximate online/presence state. | Should | Stale state expires and never implies durable delivery. |
| FR-FILE-001 | Upload, scan, process, and download attachments. | Must | Unscanned objects cannot be downloaded as ready. |
| FR-NOTIF-001 | Generate push and email notifications from policy. | Must | Retries are idempotent where possible. |
| FR-SRCH-001 | Search only content visible to the requesting user. | Must | Permission changes remove unauthorized results. |
| FR-ADM-001 | Administer users, channels, policies, and moderation. | Must | Every privileged action creates an audit event. |
| FR-INT-001 | Expose versioned APIs and signed webhooks. | Should | Contracts are schema-validated and rate-limited. |
