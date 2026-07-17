# ADR-0033: Own conversation admission and compose quota usage

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0017, ADR-0026, ADR-0032

## Context

The principal business-context SCC contains Calls, Conversations,
IdentityAccess, and TenantAdministration. It is a complete directed four-node
graph, so removing one relationship cannot remove a member; it can reduce the
cycle from twelve to eleven internal edges.

The smallest non-audio reverse relationship is
`tenant_administration -> conversations`. It is created only by
`CommsCore.AdmissionQuotas`, which imports the Conversation and Membership
Ecto schemas to count active records. Its administrative `usage/1` query also
reads the `conversations` and `conversation_memberships` tables directly.

Conversation admission is transaction-sensitive. The tenant advisory lock must
be acquired before counts are observed, and the count, decision, and owner
write must remain in one transaction.

## Decision

TenantAdministration owns the admission limits and shared advisory lock.
`CommsCore.Administration.AdmissionPolicy` is its Ecto-free policy contract.
`CommsCore.AdmissionQuotas.locked_policy/1` acquires the existing lock and
returns that contract.

Conversations owns all active-conversation and active-membership queries. Its
creation, join, rejoin, add, and re-add workflows:

1. acquire the locked tenant policy;
2. observe Conversation and Membership rows locally;
3. pass scalar counts to the TenantAdministration policy decision; and
4. perform the existing write in the same caller-owned transaction.

`CommsCore.Conversations.admission_usage/1` publishes only
`CommsCore.Conversations.AdmissionUsage`. It does not expose Ecto schemas.

The existing tenant-admin HTTP usage response is a cross-owner read model.
`CommsCore.Operations.tenant_admission_usage/1` composes the exact public
queries for tenant policy, active IdentityAccess count, and Conversations
usage, returning `CommsCore.Operations.TenantQuotaUsage`. The web controller
invokes Administration for the owner operation and Operations for the read
projection. No business context depends on Operations, and Operations gains no
new source-table access.

## Consequences

- `CommsCore.AdmissionQuotas` no longer imports, queries, or writes
  Conversation or Membership persistence.
- The aggregate `tenant_administration -> conversations` business edge is
  removed. The existing `conversations -> tenant_administration` policy
  direction remains explicit.
- The SCC still has four members, but its internal relationships decrease from
  twelve to eleven. Its expected fingerprint is `127209a1d6c0c922`.
- Conversation quota failures, advisory-lock ordering, and transaction
  rollback semantics remain unchanged.
- The admin API retains its fields, authorization, limits, and capacity flags.
  The reporting view is observational across exact owner queries; it is not an
  admission decision or a guaranteed multi-owner point-in-time snapshot.
- The settings command commits before the adapter reads the composed usage
  projection. A database failure during that post-commit read cannot roll back
  an accepted settings change; a client receiving an uncertain response must
  refetch the tenant resource. This CQRS-style failure boundary is accepted
  instead of making TenantAdministration depend on a read-model context.
- The existing TenantAdministration read of the canonical User schema remains
  tracked debt. NotificationDelivery eligibility reads and every audio/video
  edge remain unchanged.
- No table, migration, deployment unit, event, or outbox behavior changes.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Hide Conversations behind a configured callback or runtime `apply` | It removes a static reference without correcting persistence ownership. |
| Approve raw Conversation table reads in AdmissionQuotas | Business contexts cannot receive source-table grants; that would weaken the validator. |
| Move the aggregate query wholesale into Operations SQL | It would add new cross-owner source-table grants instead of using owner projections. |
| Cut an IdentityAccess or Calls relationship | Identity edges span more workflows; Calls edges are explicitly deferred audio/video work. |

## Validation

Completion requires:

- no production reference from AdmissionQuotas to the Conversations facade or
  its schemas;
- owner-local conversation and membership counting after the shared advisory
  lock is acquired;
- exact Operations read-model contracts and facade-query declarations;
- no business-context dependency on Operations;
- passing concurrent creation, join, rejoin, add, archive, API-contract, and
  single-snapshot usage, and architecture tests;
- removal of fingerprints `4db8a73cb32f6c26`, `9b52042529f538d5`, and
  `c5d9102ad275959c`; and
- replacement of cycle fingerprint `d900c7783f86b39a` with
  `127209a1d6c0c922`.
