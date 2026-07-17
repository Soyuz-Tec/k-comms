# Proof Point 13: Identity and conversation owner direction

Status: complete and verified.

This is the repository-effective thirteenth proof point. It implements the
request-numbered Proof Point 11 without overwriting the existing Proof Point 11
and 12 records.

## Executive outcome

The selected relationship is:

```text
IdentityAccess -> Conversations
```

It was the highest-leverage safe non-audio cut because the reverse relationship
represented two misplaced workflows in only two IdentityAccess modules:

- Accounts coordinated the initial General channel through direct
  Conversations facade calls; and
- ServiceAccounts delegated conversation listing and directly queried foreign
  Conversation and Membership schemas.

Bootstrap now uses a narrow IdentityAccess-owned synchronous port implemented
by Conversations. Service directory and membership/archive decisions now live
in the Conversations facade. The port preserves the existing caller
transaction, validates a typed scalar receipt before commit, and does not make
bootstrap asynchronous or conceal a source-table read.

## Coupling inventory and priority

| Priority | Location | Former relationship | Classification | Resolution |
|---:|---|---|---|---|
| 1 | `service_accounts.ex` foreign Membership/Conversation join | IdentityAccess decided foreign membership and archive policy | True reverse dependency and schema leakage | Move decision to `Conversations.authorize_service_access/3` |
| 2 | `service_accounts.ex` conversation list delegation | IdentityAccess exposed an owner directory workflow | Read-through workflow | Move to `Conversations.list_for_service/1` |
| 3 | `accounts.ex` redundant `Conversations.project/1` | IdentityAccess re-projected an existing owner view | Projection reach-through | Pass the owner projection through unchanged |
| 4 | `accounts.ex` interactive/release bootstrap calls | IdentityAccess compiled directly against a same-transaction owner command | Workflow orchestration edge | Invert through the narrow bootstrap port |

All four sub-edges had to move for the aggregate relationship to disappear.
Moving only the direct schema query would have improved encapsulation but left
the SCC relationship intact.

The opposite `conversations -> identity_access` direction remains declared.
Conversations still has legitimate identity eligibility and member-display
needs; this proof point does not hide or baseline those as resolved.

## Exact implementation sequence

1. Capture the interactive and release bootstrap transaction boundaries.
2. Capture service scope, active membership, tenant isolation, archive, and
   in-transaction message reauthorization behavior.
3. Add Ecto-schema-free initial-conversation command and typed scalar receipt
   contracts.
4. Add an IdentityAccess-owned port whose create and fetch operations require
   the caller's active repository transaction.
5. Bind Conversations as the sole provider and make it persist its own
   Conversation and Membership rows.
6. Remove the redundant Accounts projection and every direct Conversations
   call.
7. Restrict ServiceAccounts to durable identity and capability validation.
8. Move service directory and active-membership/archive policy into
   Conversations.
9. Route Messaging preflight and its existing in-transaction callback through
   the Conversations owner API.
10. Update controller, behavior, architecture, manifest, baseline, ADR, and
    regression tests.
11. Make release retry reject archived, membership-incomplete, or ambiguous
    initial-channel state.

## Implementation by file

### IdentityAccess contracts and bootstrap

- `apps/comms_core/lib/comms_core/accounts/initial_conversation_command.ex`
  carries only generated IDs and the owner join timestamp.
- `apps/comms_core/lib/comms_core/accounts/initial_conversation_receipt.ex`
  defines the complete scalar result shape; it cannot wrap an Ecto schema or
  arbitrary provider term.
- `apps/comms_core/lib/comms_core/accounts/conversation_bootstrap_port.ex`
  adds the command to the existing `Ecto.Multi`, rejects direct work outside a
  transaction, validates create/fetch receipts, and dispatches through one
  reviewed composition-root binding.
- `apps/comms_core/lib/comms_core/accounts.ex` uses only those owned contracts.
  Tenant, user, device, channel, membership, session, and audit still commit or
  roll back together. Release bootstrap retains its advisory lock and
  idempotent fetch.

### Conversations ownership

- `apps/comms_core/lib/comms_core/conversations.ex` implements the bootstrap
  port and maps its owner-local row to the scalar receipt. Existing release
  state is accepted only when exactly one matching unarchived channel has an
  active owner membership.
- `Conversations.list_for_service/1` validates the
  `conversations:read` capability through IdentityAccess and runs the existing
  active owner-local listing.
- `Conversations.authorize_service_access/3` validates the requested
  capability through IdentityAccess, then checks same-tenant active Membership
  and non-archived Conversation state locally. Malformed IDs fail closed.

### Service and content call sites

- `apps/comms_core/lib/comms_core/service_accounts.ex` no longer imports
  Conversations, Conversation, or Membership. `authorize_service/2` verifies
  only durable service identity and scope.
- `apps/comms_core/lib/comms_core/messaging.ex` calls the Conversations owner
  policy before service reads/writes and again inside the existing message
  transaction. Duplicate idempotent replay remains authorization-gated.
- `apps/comms_web/lib/comms_web/controllers/service_conversation_controller.ex`
  calls the Conversations facade and continues presenting `ConversationView`.
- `apps/comms_web/lib/comms_web/presenter.ex` renders the typed initial-channel
  receipt without importing any persistence schema; its deferred audio branch
  is unchanged.
- `config/config.exs` contains the sole bootstrap provider binding.

### Tests and control plane

- `apps/comms_core/test/identity_conversation_bootstrap_port_test.exs` proves
  the transaction requirement, malformed-success rejection, interactive and
  release rollback, malformed fetch rejection, and fail-closed release retry
  for archived, membership-incomplete, or ambiguous state.
- `apps/comms_core/test/accounts_test.exs` composes its rollback proof through
  the new port.
- `apps/comms_core/test/service_accounts_test.exs` protects directory scope,
  tenant/membership/archive behavior, malformed IDs, sender identity,
  idempotency, and both message-write authorization checks.
- `apps/comms_web/test/service_account_controller_test.exs` protects the
  unchanged HTTP behavior.
- `scripts/test_validate_architecture.py` fixes the contract, binding,
  provider, caller set, service owner direction, adapter exclusion, removed
  fingerprints, runtime-collaboration declaration, and replacement cycle
  fingerprint.
- `docs/02-architecture/context-boundaries.yaml` publishes the three port
  contracts, declares the exact synchronous runtime collaboration, and forbids
  Accounts and ServiceAccounts from Conversations namespaces.

## Architecture delta

| Measure | Before | After |
|---|---:|---:|
| Tracked boundary findings | 99 | 95 |
| Foreign-schema findings | 81 | 79 |
| Undeclared-edge fingerprints | 10 | 8 |
| Principal SCC members | 4 | 4 |
| Principal SCC compiled relationships | 11 | 10 |

Removed fingerprints:

- `4f44767efee5184f` — Accounts -> Conversations;
- `20f498850eb580eb` — ServiceAccounts -> Conversations;
- `3c6d68b4f4a50a0d` — foreign Conversation schema; and
- `de5e0182434764c8` — foreign Membership schema.

The old SCC fingerprint `127209a1d6c0c922` is replaced by
`75826183c4276dbe`.

No other fingerprint changed. The audio presenter exception, all Calls-related
edges, and NotificationDelivery identity-eligibility debt remain tracked. The
manifest reports bootstrap runtime control flow separately so the compiled SCC
metric is not presented as the complete runtime interaction graph.

## Verification evidence

- [x] Focused Accounts, ServiceAccounts, and bootstrap-port tests pass on a
      fresh migrated database.
- [x] Focused service-controller tests pass on that database.
- [x] Architecture validator tests pass.
- [x] Architecture validation passes against exactly 95 tracked findings.
- [x] Full fresh-database umbrella suite passes: 315 tests.
- [x] Full warnings-as-errors compilation and format check pass.
- [x] Xref, documentation validation, and whitespace validation pass.

## Acceptance criteria

- [x] No IdentityAccess production module references a Conversations facade,
      contract, schema, implementation module, or raw source table.
- [x] Conversation and Membership persistence remain owned by Conversations.
- [x] Interactive and release bootstrap remain synchronous and transactional.
- [x] Malformed provider success cannot commit a partial bootstrap.
- [x] Release retry rejects archived, membership-incomplete, or ambiguous
      initial-channel state.
- [x] Service credential/scope policy remains in IdentityAccess.
- [x] Service membership/archive policy resides in Conversations.
- [x] Message writes retain preflight and in-transaction reauthorization.
- [x] Released adapters use the Conversations facade and public view.
- [x] No migration, event, outbox semantic, audio/video branch, or notification
      eligibility path changed.
- [x] The baseline contains the exact intended graph delta.

## Residual risks and temporary debt

- The bootstrap port is a synchronous runtime collaboration rather than proof
  that bootstrap no longer invokes Conversations. Its manifest declaration,
  two operations, composition binding, result contract, and sole caller are
  validator-enforced; adding unrelated operations would turn it into a hidden
  service locator.
- Service identity and membership are still two point-in-time owner queries.
  This proof point preserves the existing preflight plus in-transaction check;
  it does not claim linearizable authorization against every concurrent bulk
  revocation path.
- Provider exceptions still escape after the repository transaction rolls
  back. Normalizing unexpected implementation exceptions into a stable error
  is optional hardening; atomicity is preserved.
- Conversations still imports IdentityAccess schemas for eligibility and
  member projection. Those tracked findings belong to the retained direction,
  not this proof point.
- The four-context SCC remains. IdentityAccess still has separate Calls and
  TenantAdministration relationships, and all audio/video work remains
  deferred by this change.
