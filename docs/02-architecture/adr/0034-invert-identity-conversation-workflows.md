# ADR-0034: Invert identity-to-conversation workflows

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0013, ADR-0026, ADR-0031, ADR-0033

## Context

After the conversation-admission cut, the principal business-context SCC
contains Calls, Conversations, IdentityAccess, and TenantAdministration with
eleven directed relationships. `identity_access -> conversations` is produced
by two source modules:

- `CommsCore.Accounts` directly invokes Conversations while creating and
  retrieving the initial General channel during interactive and release
  bootstrap; and
- `CommsCore.ServiceAccounts` delegates conversation listing and directly
  joins the foreign Conversation and Membership schemas for service
  authorization.

The bootstrap writes are deliberately synchronous and transactional. Tenant,
owner identity, device, General channel, owner membership, session, and audit
must either commit together or roll back together. The release bootstrap also
uses a transaction-scoped advisory lock and must remain idempotent.

Service message writes have a separate security invariant. The durable service
identity and scope are checked before the command and again inside the message
transaction; active membership and non-archived conversation state must be
checked at both points without exposing Conversations persistence to
IdentityAccess.

## Decision

The two workflows use separate, narrowly named mechanisms.

### Initial-conversation bootstrap

IdentityAccess owns three Ecto-schema-free contracts:

- `CommsCore.Accounts.InitialConversationCommand`;
- `CommsCore.Accounts.InitialConversationReceipt`; and
- `CommsCore.Accounts.ConversationBootstrapPort`.

The port adds the initial-channel operation to the existing `Ecto.Multi` and
requires an active repository transaction for direct release create/fetch
operations. `CommsCore.Conversations` implements the port, persists its own
Conversation and Membership rows, and returns an IdentityAccess-owned receipt
containing only the initial channel's scalar projection fields. The port
validates that a create receipt matches the original command and rejects
malformed or incomplete success values before the caller transaction can
commit.

An idempotent release retry accepts existing state only when exactly one
unarchived General channel has an active owner membership for the expected
tenant and owner. Missing, departed, non-owner, archived, or ambiguous state
fails as `:bootstrap_identity_conflict`.

The composition root binds exactly one implementation through
`identity_conversation_bootstrap_adapter`. CI fixes the binding, provider,
caller set, and adapter exclusion so runtime dispatch cannot become an
unreviewed service locator. The manifest records the runtime collaboration,
operations, transaction requirement, binding, result contract, control-flow
direction, and opposite compile-dependency direction separately from the
static context graph.

### Service conversation access

`CommsCore.ServiceAccounts.authorize_service/2` validates only the durable
service identity and requested scope.

`CommsCore.Conversations.list_for_service/1` owns service directory listing.
`CommsCore.Conversations.authorize_service_access/3` combines the public
IdentityAccess scope decision with an owner-local Membership/Conversation
query. Missing, malformed, cross-tenant, departed, or archived targets all
fail as `:forbidden`.

ConversationContent calls this owner API before service reads/writes and uses
it again as the existing in-transaction authorization callback. Idempotent
message replay therefore remains authorization-gated.

## Consequences

- Accounts and ServiceAccounts no longer reference the Conversations facade,
  contracts, schemas, implementation namespaces, or source tables.
- Conversation directory and membership/archive decisions reside in
  Conversations; service credential and scope decisions reside in
  IdentityAccess.
- Interactive bootstrap remains one `Ecto.Multi` transaction. Release
  bootstrap remains one advisory-locked transaction and remains sessionless
  and idempotent; incomplete or ambiguous release state now fails closed.
- The compiled `identity_access -> conversations` relationship is removed.
  The already-declared `conversations -> identity_access` direction remains.
- The principal SCC still contains four contexts, but its internal
  relationships decrease from eleven to ten. Its expected fingerprint is
  `75826183c4276dbe`.
- The tracked baseline is expected to fall from 99 to 95 findings: two
  undeclared-edge and two foreign-schema fingerprints disappear.
- No table, migration, event, outbox flow, deployment unit, audio/video code,
  or NotificationDelivery eligibility read changes.

The bootstrap port is an explicit synchronous runtime collaboration. This ADR
does not claim that tenant bootstrap stopped involving Conversations; it
records that ownership and compiled dependency direction are now controlled
without leaking the owner implementation into IdentityAccess. Static SCC
counts describe compiled context references; the manifest separately exposes
the reviewed runtime control flow.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep direct Conversations facade calls from Accounts | It preserves the undeclared reverse dependency and allows the workflow surface to grow by convention. |
| Put bootstrap in an asynchronous event | It breaks the required all-or-nothing tenant bootstrap and release idempotency semantics. |
| Move all bootstrap orchestration into Conversations | Conversations does not own tenant or identity lifecycle; this would invert ownership for the wrong reason and broaden the change. |
| Add one catch-all port for bootstrap, listing, and membership | Those are unrelated capabilities and would hide service conversation ownership behind a generic runtime gateway. |
| Leave membership SQL in ServiceAccounts as a read exception | Business contexts cannot receive source-table grants; Conversation and Membership are owner-internal schemas. |
| Cut `conversations -> identity_access` instead | That direction represents genuine identity eligibility/display needs and would split current owner-local joins while leaving the reverse workflow debt. |

## Validation

Completion requires:

- no IdentityAccess production reference or raw-table access to Conversations;
- one exact bootstrap adapter binding and one production port caller;
- Conversations as the port implementation and owner of service directory and
  membership/archive decisions;
- preserved bootstrap rollback, release idempotency, scope, tenant isolation,
  archived/departed membership, and in-transaction reauthorization behavior;
- no command or port reference from released adapters; the bootstrap presenter
  may consume only the scalar `InitialConversationReceipt`;
- removal of fingerprints `4f44767efee5184f`, `20f498850eb580eb`,
  `3c6d68b4f4a50a0d`, and `de5e0182434764c8`; and
- replacement of cycle fingerprint `127209a1d6c0c922` with
  `75826183c4276dbe`.
