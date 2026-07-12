# Message Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Received
    Received --> Rejected: invalid / unauthorized / rate limited
    Received --> Duplicate: existing idempotency key
    Received --> Validated
    Validated --> Committed: database transaction succeeds
    Validated --> Failed: transaction fails
    Duplicate --> Acknowledged
    Committed --> Acknowledged
    Committed --> BroadcastAttempted
    Committed --> SideEffectsQueued
    BroadcastAttempted --> [*]
    SideEffectsQueued --> [*]
```

## Commit transaction

- Allocate conversation sequence.
- Insert message and associated metadata.
- Validate and attach ready attachments.
- Insert mentions and audit event.
- Insert job/outbox records.

The live broadcast and external side effects execute only after the transaction is known to have committed.
