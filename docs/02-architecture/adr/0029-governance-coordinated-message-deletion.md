# ADR-0029: Coordinate legal-hold-aware message deletion in Governance

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0027

## Context

Messaging owned the message update and outbox append but called Governance to
check legal holds. Governance also depends on ConversationContent to execute
approved erasure requests. Moving erasure writes behind the Messaging facade
therefore exposed a direct runtime cycle between the two modules.

Passing an Ecto `Message` schema to Governance would also make persistence
details a cross-context contract.

## Decision

Governance owns the public legal-hold-aware delete use case through
`CommsCore.Governance.delete_message/2`.

Messaging contributes the content mutation to that existing transaction. It
passes a `CommsCore.Messaging.MessageDeletionCandidate` containing only message,
tenant, conversation, and sender identifiers to a policy callback. After the
callback succeeds, Messaging owns the message update and transactional outbox
append and returns `MessageView`.

Released adapters call Governance for message deletion. ConversationContent
does not depend on TrustGovernance.

## Consequences

- Legal-hold policy and content persistence have one-way dependency direction.
- Governance never receives or pattern-matches a Message Ecto schema.
- Message locking, authorization, update, and outbox behavior remain in
  ConversationContent and one database transaction.
- Internal callers must not bypass the Governance facade with a permissive
  policy callback.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep the bidirectional facade calls | Retains a concrete runtime cycle. |
| Pass the Message schema into Governance | Leaks persistence as a contract. |
| Add a new service or database | Unnecessary distributed architecture for an in-process policy decision. |
| Replicate legal holds into a new content table now | Adds migration and projection complexity before user validation. |

## Validation

- Architecture tests reject a Messaging import of Governance.
- The message controller calls `Governance.delete_message/2`.
- Legal-hold and message lifecycle tests exercise the same transaction path.
- `mix xref graph --format cycles` does not report a Governance/Messaging
  two-file cycle.
