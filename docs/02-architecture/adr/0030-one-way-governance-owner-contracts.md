# ADR-0030: Use one-way owner contracts for Governance coordination

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0029

## Context

IdentityAccess directly queried the Governance-owned `deletion_requests` table
when enforcing the last-active-owner invariant. Governance also read the
TenantAdministration-owned `tenant_settings` schema to obtain the default
retention period.

The first access created an IdentityAccess to TrustGovernance reverse
dependency. The second used a foreign persistence schema where a narrow
read-only owner contract is sufficient.

## Decision

TrustGovernance may depend one way on IdentityAccess and
TenantAdministration. Neither owner depends on TrustGovernance.

Governance supplies the approved or in-progress deletion exclusions to a
transaction-required IdentityAccess lifecycle command. IdentityAccess owns user
locking, last-owner evaluation, mutation, access revocation, and its returned
projection; it does not import `DeletionRequest`.

TenantAdministration publishes
`CommsCore.Administration.RetentionDefaults`. Governance uses that immutable
contract through the exact
`CommsCore.Administration.retention_defaults/1` query and does not import
`TenantSettings`. The manifest records this as a bounded read-only exception
with no other public-query or source-table access.

## Consequences

- The IdentityAccess to TrustGovernance edge is removed.
- TrustGovernance to TenantAdministration is explicit and one way.
- At the ADR-0030 snapshot, the business strongly connected component shrinks
  from seven contexts to six under the hardened detector; it is not yet
  eliminated. ADR-0031 subsequently reduces the current component to five.
- The owner lifecycle invariant remains synchronous and transactional.
- No database migration, new service, event bus, or replicated retention state
  is introduced.
- Root grouped aliases, canonical schema ownership, exact read queries, raw SQL
  writes, and exact SCC edges are now enforced instead of being parser blind
  spots.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Let Accounts call a Governance facade | Retains the reverse business dependency and cycle. |
| Copy deletion or retention state into new tables | Adds migrations, replication, and reconciliation for synchronous data already available in the monolith. |
| Query foreign schemas under a broad read exception | Makes persistence models cross-context contracts. |
| Split the workflow into services | Adds distributed failure modes without a deployment or scaling requirement. |

## Validation

- Accounts contains no reference to `CommsCore.Governance` or
  `DeletionRequest`.
- In the owner-lifecycle workflow, Governance receives only IdentityAccess
  projections and commands and reads retention defaults only as
  `RetentionDefaults`.
- The architecture validator rejects undeclared owner access and validates the
  explicit contract and query exception shape.
- The tracked IdentityAccess to TrustGovernance edge is removed, while the
  remaining six-context SCC and its exact internal edges stay visible in the
  baseline.

The earlier five-context estimate omitted ConversationContent because the old
parser did not expand root aliases such as `CommsCore.{Messaging}`. The
hardened detector corrects that inventory; it does not represent new production
coupling.
