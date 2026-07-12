# Domain Model

**Status:** Draft

## Bounded contexts

| Context | Principal aggregates | Authoritative rules |
|---|---|---|
| Identity and Tenancy | Tenant, User, Device, Session | Identity state, tenant status, session revocation |
| Conversations | Conversation, Membership, Role | Visibility, membership lifecycle, permission assignment |
| Messaging | Message, Revision, Reaction, Read Cursor | Ordering, idempotency, edit/delete policy, durable history |
| Attachments | Attachment, Variant | Ownership, scan state, availability, retention |
| Notifications | Preference, Notification Intent | Recipient policy, suppression, provider delivery state |
| Integrations | Application, Webhook Endpoint, Delivery | Scope, signatures, retries, quotas |
| Administration | Policy, Moderation Case, Audit Event | Privileged actions and compliance evidence |

## Aggregate rules

- Every tenant-owned aggregate carries an explicit tenant identifier.
- Conversation membership is evaluated at command time, not only socket-join time.
- A message acknowledgment is emitted only after its transaction commits.
- Client idempotency is scoped by tenant, sender device, and client message ID.
- A conversation sequence is monotonically increasing and determines canonical order.
- Search, unread counts, and analytics are derived projections.
- Presence is not an aggregate and is never evidence of durable receipt.

## Domain event naming

Use past-tense, versioned names such as:

- `message.created.v1`
- `message.revised.v1`
- `conversation.membership_removed.v1`
- `attachment.ready.v1`
- `notification.requested.v1`

Events contain identifiers and policy-safe data. Sensitive content is included only where explicitly required and authorized.
