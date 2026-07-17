# ADR-0040: Contain ConversationContent persistence

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0027, ADR-0035, ADR-0039

## Context

Messaging and Attachments already form one `conversation_content` boundary, but
their Ecto schemas still associated directly with TenantAdministration,
IdentityAccess, Conversations, and device persistence. Tenant settings were
also exposed through a broad capability map, and the release restore workflow
passed attachment persistence structs to an external verifier.

These paths did not establish duplicate table ownership, but they made foreign
persistence shapes and unrelated tenant settings part of ConversationContent's
compiled contract. Thirteen foreign-schema fingerprints remained in the
architecture baseline.

## Decision

Foreign identifiers in `Message`, `MessageMention`, `MessageRevision`,
`Reaction`, `Attachment`, and `ScanAttempt` are scalar UUID fields. Associations
within the single ConversationContent owner may remain where they are used.
Existing database constraints remain authoritative; no migration is required.

TenantAdministration publishes the Ecto-free
`ConversationContentPolicy` projection containing only tenant ID, message edit
window, and maximum attachment bytes. Messaging and Attachments consume that
projection instead of the broad member-capability map.

Attachments owns the restore-remap use case behind
`Attachments.remap_restored_attachment_versions/2`. The verifier receives a
`RestoreCandidate` and returns a `RestoredObjectIdentity`; the operation accepts
a `RestoreContext` and returns a `RestoreReport`. All are Ecto-free contracts.
`CommsCore.Release` calls the Attachments facade and does not import the
owner-internal `RestoreRemap` implementation.

Messaging remains the message-publication transaction owner.
`Attachments.attach_ready/4` is an owner-contributed write that refuses to run
outside the caller's active repository transaction, preserving atomic message
creation and attachment claiming.

## Consequences

- ConversationContent schemas no longer compile against foreign Ecto schemas.
- Tenant policy and disaster-recovery integration shapes are explicit,
  minimal, persistence-neutral contracts.
- Same-owner message and attachment lifecycle behavior is unchanged.
- The thirteen reviewed foreign-schema fingerprints are removed with no new
  finding, edge, exception, table, or migration.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep read-only foreign associations | Read-only reach-through still couples the owner to foreign persistence. |
| Split Messaging and Attachments | Attachment claiming and authorization are part of message lifecycle; splitting would add coordination without clearer ownership. |
| Keep generic maps at the policy and restore seams | Broad maps hide contract growth and make persistence leakage easier. |
| Move or rewrite the database | Scalar schema fields preserve the existing keys and constraints without data movement. |

## Validation

- Architecture regressions require scalar foreign IDs and reject foreign-schema
  findings in the six affected schemas.
- Messaging and Attachments must use `ConversationContentPolicy`, not
  `member_capabilities/1`.
- Restore verification receives DTOs, and Release may call only the Attachments
  facade.
- Attachment claiming is transaction-required and has rollback coverage.
- The reviewed baseline transition is exactly 59 to 46 findings with no
  additions and exactly thirteen removals.
