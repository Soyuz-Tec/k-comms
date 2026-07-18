# ADR-0017: Enforce tenant admission quotas in PostgreSQL transactions

**Status:** Accepted

## Context

Tenant administrators need predictable controls over identity, conversation,
and membership growth. UI-only checks, independent count-then-insert queries,
or per-node locks can over-admit during concurrent requests and cannot safely
coordinate a settings reduction with a create or rejoin.

The first release also needs useful capacity visibility without retroactively
deleting existing resources when an administrator lowers a limit. Direct
conversations intrinsically require two members. Attachment admission already
has a per-file byte limit and request rate limiting, but K-Comms does not yet
have the reservation and reconciliation model required for a correct total
stored-byte quota.

## Decision

`tenant_settings` owns three versioned limits:

- `max_active_users`, default 500, range 1 through 1,000,000;
- `max_active_conversations`, default 2,000, range 1 through 10,000,000;
- `max_conversation_members`, default 250, range 2 through 100,000.

`CommsCore.AdmissionQuotas` is the single admission boundary. Every mutating
check runs inside the caller's database transaction and takes a PostgreSQL
transaction-scoped advisory lock derived from the tenant ID. Limit updates take
the same lock before reading or changing settings. This serializes admissions
and limit changes within one tenant while unrelated tenants remain independent.

The active-identity count includes human and service users with `status =
'active'`; suspended and deleted identities do not consume identity capacity.
The active-conversation count includes only rows without `archived_at`.
Conversation membership capacity counts same-tenant membership rows without
`left_at` in a non-archived conversation. Identity status and membership state
remain separate lifecycle dimensions.

The boundary is enforced for:

- direct user creation, invitation acceptance or suspended-user reactivation,
  admin unsuspend, and service-account creation;
- every conversation creation, including its initial member set;
- add-member, public self-join, and rejoin of a left membership.

Reducing a limit below current usage is allowed and never deletes data. The
admin API and UI expose current usage, configured limits, per-dimension
`at_capacity` (`current == limit`), and `over_limit` (`current > limit`) state.
At-capacity and over-limit dimensions reject only new admissions with stable
409 error codes; reads, leaves, archives, suspensions, and revocations continue.

K-Comms does not implement a total-storage quota in this increment. The bounded
storage-admission controls are the tenant `max_attachment_bytes` per-file limit
plus authenticated request rate limiting. Object-store capacity, lifecycle,
and cost remain operational signals. A future total-storage quota requires
atomic reservations, upload completion reconciliation, deletion crediting, and
provider inventory drift handling under a separate decision.

## Consequences

- Concurrent requests cannot over-admit a tenant when all admission paths use
  the centralized boundary.
- A very busy tenant serializes admission decisions, but ordinary messaging and
  reads do not take the lock.
- A settings reduction has deterministic ordering relative to admissions.
- Admins can distinguish an exact full boundary from an already over-limit
  tenant without destructive remediation.
- New identity, conversation, or membership entry points must call this context
  in their existing transaction before persisting the admission.

## Alternatives considered

- **Application-process locks:** rejected because they do not coordinate across
  replicas or deployment roles.
- **Row locks only:** rejected because settings rows may not exist yet and
  membership admissions span many rows; lock ordering would be inconsistent.
- **Database triggers:** rejected for the MVP because authorization-aware error
  semantics and lifecycle replay behavior remain clearer in the domain context.
- **Reject limit reductions below usage:** rejected because safe administrative
  policy correction should not require deleting or reactivating resources in a
  particular order.
- **Total stored-byte quota now:** deferred until reservation and object-store
  reconciliation semantics can prevent both over-admission and stranded quota.

## Validation

- Migration `20260712000400` is exercised down and up against a disposable
  PostgreSQL database and its constraints reject unsafe values.
- Concurrent identity, conversation, and membership tests prove only the
  available capacity is admitted.
- Lifecycle tests cover service identities, invitation reactivation, admin
  unsuspend, archive release, left-membership release, self-join, and rejoin.
- HTTP tests assert usage payloads and stable quota error codes.
- Accessible client tests assert over-limit and exact-capacity announcements.
