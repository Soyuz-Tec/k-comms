# Domain Model

**Status:** Draft

## Bounded contexts

| Context | Principal aggregates | Authoritative rules |
|---|---|---|
| Identity and Tenancy | Tenant, User, Device, Session, Service Account | Identity state, tenant status, session revocation, service credential lifecycle and scopes |
| Conversations | Conversation, Membership, Role | Visibility, membership lifecycle, permission assignment |
| Messaging | Message, Mention, Thread, Revision, Reaction, Read Cursor | Ordering, idempotency, explicit recipients, canonical reply roots, edit/delete policy, durable history |
| Attachments | Attachment, Variant | Ownership, scan state, availability, retention |
| Notifications | Preference, Notification Intent | Recipient policy, suppression, provider delivery state, user-owned in-app read/dismiss state |
| Integrations | Webhook Endpoint, Subscription, Secret Version, Delivery | Destination policy, secret rotation, retries, replay |
| Administration | Tenant Settings, Admission Quota, Invitation, Audit Event | Lifecycle, atomic capacity admission, role assignment, privileged evidence |
| Moderation | Case, Action | Reporting, assignment, reason-coded resolution |
| Governance | Retention Policy, Legal Hold, Deletion Request | Policy precedence, preservation, reconciled deletion |
| Integrations | Application, Webhook Endpoint, Delivery | Scope, signatures, retries, quotas |
| Administration | Policy, Moderation Case, Audit Event | Privileged actions and compliance evidence |

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
- A service account owns a dedicated internal user/device identity, but its
  credential authenticates only service routes; scopes never replace active
  tenant/conversation membership.
- Raw service-account secrets are transient outputs. Persistence contains only
  a hash plus a non-secret credential prefix/hint, expiry, rotation, revocation,
  version, and last-use evidence.
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
