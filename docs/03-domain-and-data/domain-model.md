# Domain Model

**Status:** Accepted implementation baseline for K-Comms 0.3.0

## Bounded contexts

| Context | Principal aggregates | Authoritative rules |
|---|---|---|
| Identity and Tenancy | Tenant, User, Device, Session, Service Account, Platform Role Grant | Identity state, tenant status, session revocation, bounded platform authority, service credential lifecycle and scopes |
| Conversations | Conversation, Membership, Role | Visibility, membership lifecycle, permission assignment |
| Calls | Call (`audio_calls` storage), Media Kind, Participant Admission, Eviction | Bounded audio/video lifecycle, current join authorization, opaque media identity, durable revocation, and provider-removal progress |
| Messaging | Message, Mention, Thread, Revision, Reaction, Read Cursor | Ordering, idempotency, explicit recipients, canonical reply roots, edit/delete policy, durable history |
| Attachments | Attachment, Variant | Ownership, scan state, availability, retention |
| Notifications | Preference, Notification Intent | Recipient policy, suppression, provider delivery state, user-owned in-app read/dismiss state |
| Integrations | Application, Webhook Endpoint, Subscription, Secret Version, Delivery | Scope, destination policy, secret rotation, signatures, retries, replay, quotas |
| Administration | Tenant Settings, Admission Quota, Invitation, Audit Event | Lifecycle, atomic capacity admission, policy and role assignment, privileged evidence |
| Moderation | Case, Action | Reporting, assignment, reason-coded resolution |
| Governance | Retention Policy, Legal Hold, Deletion Request | Policy precedence, preservation, reconciled deletion |

## Aggregate rules

- Every tenant-owned aggregate carries an explicit tenant identifier.
- Conversation membership is evaluated at command time, not only socket-join time.
- A message acknowledgment is emitted only after its transaction commits.
- Client idempotency is scoped by tenant, sender device, and client message ID.
- A conversation sequence is monotonically increasing and determines canonical order.
- Mention recipients are explicit active same-conversation members; message text is never parsed to infer recipients.
- Every nested reply retains its immediate parent and resolves to one canonical top-level thread root.
- In-app notification read and dismiss state is tenant/user scoped; dismiss always implies read.
- Search, unread counts, and analytics are derived projections.
- Presence is not an aggregate and is never evidence of durable receipt.
- A call has an immutable `media_kind` of `audio` or `video`; the one-active-call
  invariant applies across both kinds for each conversation.
- A participant admission persists the opaque provider identity and its
  tenant, call, conversation, user, device, and session bindings. The signed
  participant credential is transient and never part of the aggregate.
- Access loss invalidates matching call admissions and enqueues eviction in
  the same transaction, without provider I/O. Provider failure cannot restore
  authority; durable removal retries continue until the minimum enforcement
  horizon has elapsed and a removal succeeds at or after it.
- Call creation atomically schedules one unique durable expiry job for its
  eight-hour deadline. Expiry deletes the provider room before committing the
  normal ended lifecycle and admission revocation; provider failure retries,
  while stale jobs cannot end a newer replacement call.
- A service account owns a dedicated internal user/device identity, but its
  credential authenticates only service routes; scopes never replace active
  tenant/conversation membership.
- Raw service-account secrets are transient outputs. Persistence contains only
  a hash plus a non-secret credential prefix/hint, expiry, rotation, revocation,
  version, and last-use evidence.
- Platform authority is a separate five-minute-to-eight-hour grant with a
  random per-approval identifier. Every grant or renewal replaces the row with
  a fresh identifier. Every use matches its exact persisted identifier, role,
  and deadline so expiry, revoke, or renewal denies an earlier HTTP or WebSocket
  subject even if a later approval repeats the same role and deadline.
- Active identity, conversation, and membership admission uses the same
  tenant-scoped transaction lock as quota-setting changes. Exact capacity blocks
  the next admission; over-limit state never removes existing resources.

## Domain event naming

Use past-tense, versioned names such as:

- `message.created.v1`
- `message.revised.v1`
- `conversation.membership_removed.v1`
- `attachment.ready.v1`
- `notification.requested.v1`

Events contain identifiers and policy-safe data. Sensitive content is included only where explicitly required and authorized.
