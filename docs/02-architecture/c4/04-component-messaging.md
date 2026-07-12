# C4 Level 3 — Messaging Components

```mermaid
flowchart TB
    Submit[Submit Message Command]
    Validate[Schema and Policy Validation]
    Idem[Idempotency Lookup]
    Sequence[Conversation Sequence Allocation]
    Persist[Message Persistence]
    Outbox[Job / Outbox Persistence]
    Commit[Transaction Commit]
    Ack[Canonical Acknowledgment]
    Broadcast[Live Broadcast]

    Submit --> Validate --> Idem
    Idem -->|new| Sequence --> Persist --> Outbox --> Commit
    Idem -->|duplicate| Ack
    Commit --> Ack
    Commit --> Broadcast
```

The transaction boundary includes sequence allocation, message persistence, attachments/mentions, audit, and durable work requests. Live broadcast occurs after commit.
