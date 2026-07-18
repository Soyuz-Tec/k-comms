# ADR-0039: Contain TrustGovernance persistence

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0033, ADR-0035, ADR-0036, ADR-0038

## Context

TrustGovernance owns moderation cases and actions, retention policies, legal
holds, and deletion requests. Its Ecto schemas nevertheless associated directly
with TenantAdministration, IdentityAccess, Conversations, and
ConversationContent schemas. The Governance and Moderation facades also queried
foreign User, Conversation, Message, and Attachment schemas.

These reads were tenant-scoped and the erasure writes already used owner
facades, but foreign persistence shapes still compiled into TrustGovernance.
That made schema changes cross-context changes and left twenty-two
foreign-schema fingerprints in the architecture baseline.

## Decision

All foreign identifiers in `DeletionRequest`, `LegalHold`, `RetentionPolicy`,
`ModerationCase`, and `ModerationAction` are scalar `Ecto.UUID` fields.
`ModerationAction` may retain its association to `ModerationCase` because both
tables belong to TrustGovernance. Existing database foreign keys remain
authoritative; this decision adds no migration.

TrustGovernance obtains foreign facts only through owner facades:

- IdentityAccess validates governance users and moderation assignees, selects
  the retention actor, and performs the transaction-required, owner-safe
  erasure precondition.
- Conversations validates exact-tenant conversation references and publishes
  the ordered IDs eligible for retention evaluation.
- ConversationContent publishes Ecto-free `GovernanceImpact`,
  `RetentionScope`, `RetentionCandidate`, and `AttachmentDeletionObject`
  contracts. Messaging owns message-impact and retention queries; Attachments
  owns attachment object selection.

Governance continues to coordinate deletion in one transaction using the
existing owner-contributed write APIs. Tenant advisory locking, deletion-request
row locking, optimistic versions, legal-hold checks, deterministic
IdentityAccess user locking, last-owner protection, audit recording, and
transactional outbox behavior remain intact. TrustGovernance does not expose a
foreign persistence struct through its public facades.

The existing Calls interaction is unchanged and remains in its separately
deferred audio/video tranche. This decision neither changes audio/video code nor
changes the database.

## Consequences

- Governance and Moderation compile against stable owner facades and Ecto-free
  projections instead of foreign schemas.
- TrustGovernance schemas retain foreign identity as IDs without claiming
  foreign table ownership.
- The twenty-two corresponding `foreign_schema_import` fingerprints are
  removable without adding an edge, cycle, table, migration, or exception.
- Cross-owner reads may require more than one query, but their tenant scope,
  result shape, and ownership are now explicit and independently testable.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep read-only Ecto associations | Read-only reach-through still couples TrustGovernance to foreign persistence. |
| Move foreign tables into TrustGovernance | The tables already have coherent owners and do not share TrustGovernance lifecycle. |
| Add raw table queries to a shared helper | It would hide ownership rather than establish an owner contract. |
| Redesign deletion storage or split services | Neither is required to contain the current monolith boundary. |

## Validation

- Architecture regressions reject every foreign-schema finding under the
  Governance and Moderation production namespaces.
- TrustGovernance schema tests require scalar UUID foreign identifiers and
  retain only the internal moderation-case association.
- Owner API tests cover exact-tenant existence, moderation eligibility,
  retention ordering, transaction-required erasure safety, content impact,
  retention candidates, and attachment object projections.
- The boundary manifest declares every new public DTO.
- The reviewed baseline transition is exactly 81 to 59 findings, with no added
  fingerprint and exactly the twenty-two reviewed removals.
