# ADR-0027: Keep messages and attachments in one conversation-content boundary

- **Status:** Accepted
- **Date:** 2026-07-16
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0005, ADR-0011, ADR-0026

## Context

Messages and attachments use one transactional lifecycle. A message claims only
clean, tenant-matching, unclaimed attachments; failure rolls the message
transaction back. Attached-file authorization also depends on the linked
message's conversation. The database enforces the relationship through
`attachments.message_id`. Treating these capabilities as separate bounded
contexts would turn one invariant into a synchronous cross-context protocol.

The implementation nevertheless had bidirectional Ecto associations,
cross-schema arguments, released adapters receiving schemas, and a five-file
compiled dependency cycle.

## Decision

Keep Messaging and Attachments under the single `conversation_content` owner.
Messaging orchestrates publication and may claim attachments through
`Attachments.attach_ready/4` using message and tenant IDs. Attachments must not
import Messaging schemas or implementation modules.

Ecto child-to-parent relationships use foreign-key ID fields where the reverse
association is not consumed. Public callers receive `MessageView`,
`ReactionView`, `AttachmentView`, and `ScanAttemptView` projections. Database
tables, foreign keys, object-storage behavior, scanning, and transaction
boundaries remain unchanged.

## Consequences

- Message publication and attachment claiming remain atomic.
- The internal dependency direction is explicit and validator-enforced.
- Web and worker adapters no longer pattern-match content persistence schemas.
- The existing database model requires no migration.
- Governance's separate retention/deletion reach-through remains tracked debt
  and is not addressed by this decision.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Separate Messaging and Attachments contexts | Their publication and authorization invariants are transactional and inseparable in the current product. |
| Move attachments into a new umbrella application | Adds build fragmentation without creating a valid business boundary. |
| Keep bidirectional Ecto associations | Preserves an avoidable dependency cycle and leaks persistence contracts. |
| Add a shared-kernel model | Hides ownership instead of defining it. |

## Validation

- `mix xref graph --format cycles` contains no Messaging/Attachments cycle.
- Architecture validation forbids `CommsCore.Attachments` from depending on
  `CommsCore.Messaging`.
- Released adapters import the public projections, not the four persistence
  schemas.
- Messaging, attachment safety, worker, controller, and full umbrella tests
  remain green.
