# ADR-0031: Own service-message workflows in ConversationContent

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0013, ADR-0026, ADR-0027, ADR-0030

This ADR records the Proof Point 10 graph snapshot. ADR-0032 subsequently
selects the remaining IdentityAccess-to-NotificationDelivery edge and defines
the next boundary cut.

## Context

`CommsCore.ServiceAccounts` owns service identity and authorization, but it also
orchestrated message history, message creation, message search, and the
service-message attachment policy through `CommsCore.Messaging`.

That convenience facade created an IdentityAccess to ConversationContent
dependency. ConversationContent already depends on IdentityAccess for service
authorization, so the reverse edge kept ConversationContent inside the
remaining six-context business cycle.

## Decision

ConversationContent owns all service-message content workflows through:

- `CommsCore.Messaging.list_service_history/3`;
- `CommsCore.Messaging.accept_service_message_with_status/3`; and
- `CommsCore.Messaging.search_for_service/3`.

These owner APIs call `CommsCore.ServiceAccounts.authorize_service/3` for
service scope, active identity, and conversation-membership authorization.
Message creation repeats that authorization inside the existing Messaging
transaction. Authenticated tenant, conversation, user, and device identifiers
override caller input, and service attachments remain prohibited.

`CommsCore.ServiceAccounts` retains service identity, credential lifecycle,
authorization, and conversation-directory access. It must not depend on
`CommsCore.Messaging` or `CommsCore.Attachments`. Web adapters call the
ConversationContent owner for message operations and continue to receive
`MessageView` projections.

## Consequences

- The IdentityAccess to ConversationContent edge is removed.
- The business strongly connected component shrinks from six contexts to five:
  Calls, Conversations, IdentityAccess, NotificationDelivery, and
  TenantAdministration.
- The dependency direction is now ConversationContent to IdentityAccess for
  service authorization.
- Scope checks, tenant and membership isolation, idempotent replay,
  transaction-time authorization, search behavior, and the no-attachments
  policy are preserved.
- No database migration, read-model exception, shared kernel, new deployment,
  or audio/video change is introduced.
- IdentityAccess still reads Conversation and Membership persistence for
  service authorization and conversation listing. That separate
  IdentityAccess to Conversations debt remains tracked.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Remove IdentityAccess to NotificationDelivery first | It also shrinks the cycle, but spans account and recovery transactions with security-sensitive notification and revocation semantics. |
| Move orchestration into web controllers | Adapters would own business policy and duplicate authorization behavior. |
| Add an owner-neutral workflow module | The extra pseudo-boundary is unnecessary because message content already has a natural owner. |
| Use events for synchronous service-message commands | Message creation, idempotency, and authorization require an immediate result and existing transaction semantics. |
| Grant a read-model exception | The edge includes a write workflow and is not a read-only projection. |

## Validation

- `CommsCore.ServiceAccounts` contains no Messaging or Attachments dependency.
- Service message and search controllers call the Messaging facade.
- Core tests prove scope denial, active membership, tenant isolation, archived
  conversation filtering, authenticated sender identity, attachment rejection,
  and idempotent replay.
- The architecture validator enforces the namespace direction and records 13
  undeclared edge fingerprints instead of 14.
- The SCC fingerprint records exactly the five remaining members and all 16
  internal edges.
