# ADR-0038: Contain Conversations persistence

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0033, ADR-0034, ADR-0035, ADR-0037

## Context

Conversations owns conversation and membership lifecycle, but its Ecto schemas
associated directly with TenantAdministration's Tenant schema and
IdentityAccess's User schema. The Conversations facade also queried
`Accounts.User` to validate members, add members, validate mentions, and list
member identities. Its projector pattern-matched User persistence and called
the internal `Accounts.Projector`.

Those paths did not write a foreign table, but they made another context's
persistence shape part of Conversations compilation. The web broadcast adapter
also retained an unscoped `active_member_ids/1` query after the tenant-scoped
owner API was introduced.

## Decision

`Conversation.tenant_id`, `Conversation.created_by_user_id`,
`Membership.tenant_id`, and `Membership.user_id` are scalar `Ecto.UUID`
fields. The Membership-to-Conversation association remains because both
schemas belong to Conversations. Existing database foreign keys remain
authoritative; this decision requires no migration.

IdentityAccess publishes two ID-scoped directory operations through
`CommsCore.Accounts`:

- `resolve_active_user_ids/2` returns deterministic scalar IDs for requested,
  active, exact-tenant human or service identities.
- `resolve_user_views/2` returns deterministic, exact-tenant
  `%Accounts.UserView{}` projections for existing identities, including
  suspended or erased identities needed to display retained memberships.

Conversations queries only its own membership rows, calls those owner APIs, and
composes its `MembershipView`. Its projector may depend on the public
`UserView` contract but must not import `Accounts.User` or call
`Accounts.Projector`. Active-user validation remains required for conversation
creation, membership addition, and mentions; listing retains the existing
lifecycle-status display behavior.

`active_member_ids/2` is the only member-fanout query. It requires both tenant
and conversation IDs, returns ordered scalar user IDs, and exposes no
membership schema. `CommsWeb.Broadcast` and every caller pass the tenant ID;
the unscoped `/1` API is removed.

ADR-0034's bootstrap inversion remains unchanged. IdentityAccess owns
`ConversationBootstrapPort`, `InitialConversationCommand`, and
`InitialConversationReceipt`; Conversations implements the configured,
transaction-required operations without returning persistence structs.
Conversations also retains its intentional one-way dependencies on
IdentityAccess facade contracts and TenantAdministration capability and quota
facades. Calls-related dependencies and their explicitly deferred cycle are
outside this containment decision.

## Consequences

- Conversations production code no longer imports or pattern-matches a foreign
  Ecto schema or another context's internal projector.
- Tenant isolation, active human and service membership, mention validation,
  display-name ordering, suspended-member display, and public user projection
  behavior remain explicit owner contracts.
- Removing Ecto associations does not remove database referential integrity or
  authorize foreign-table writes.
- The six corresponding foreign-schema fingerprints are removable. The
  intentional business-context edges and Calls-driven cycle do not disappear.
- Member listing composes two owner-scoped reads rather than one cross-context
  schema join; callers still receive stable DTOs.
- Broadcast fanout cannot query a conversation without an explicit tenant
  scope.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep read-only User and Tenant associations | Read-only reach-through still couples compilation and queries to foreign persistence. |
| Duplicate identity fields on Membership | It creates synchronization and ownership ambiguity and requires unnecessary schema changes. |
| Add a second conversation-specific identity DTO | `Accounts.UserView` already preserves the released member-directory contract without exposing Ecto persistence. |
| Move membership or user tables between contexts | Each table already has one coherent owner; containment needs APIs, not table reassignment. |
| Remove all IdentityAccess or TenantAdministration dependencies | Conversations legitimately consumes identity eligibility, tenant policy, and quota decisions through stable one-way facades. |

## Validation

- Architecture regressions reject `Accounts.User`, `Accounts.Tenant`, and
  `Accounts.Projector` anywhere in the Conversations production namespace.
- Conversation and Membership schemas expose foreign identity only as scalar
  UUID fields while retaining their internal association.
- Identity directory tests cover exact-tenant filtering, active human and
  service identities, suspended views, deterministic ordering, and
  persistence-free results.
- Conversation tests cover suspended and cross-tenant create/add rejection,
  member projection and ordering, owner/version behavior, and quota behavior.
- Mention tests reject suspended, departed, nonmember, and cross-tenant users.
- Broadcast and notification fanout tests use the tenant-scoped `/2` query and
  exclude unrelated or departed memberships.
- Bootstrap-port transaction, rollback, idempotency, and receipt tests remain
  unchanged and passing.
