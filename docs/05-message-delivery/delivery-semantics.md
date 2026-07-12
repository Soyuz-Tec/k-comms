# Message Delivery Semantics

**Status:** Draft protocol baseline

| Capability | Guarantee | Mechanism |
|---|---|---|
| Message acceptance | Durable after successful response | PostgreSQL transaction commit |
| Sender retries | Effectively once for a stable idempotency key | Unique constraint and canonical replay |
| Conversation order | Strict order by server sequence | Per-conversation sequence allocation |
| Live socket delivery | Best effort / at most once | Phoenix channel broadcast |
| Offline recovery | At least once from durable history | Cursor-based synchronization |
| Presence and typing | Eventual and ephemeral | Presence diff and expiry |
| Search visibility | Eventual | Rebuildable projection |
| Notifications/webhooks | At-least-once work execution | Durable jobs, retries, delivery ledger |

## Invariants

1. No success acknowledgment before commit.
2. Duplicate sender commands return the first canonical result.
3. Conversation order is determined by the server sequence, not client clocks.
4. Clients deduplicate events by stable event or message ID.
5. Reconnection starts from the last durable cursor and tolerates repeated events.
6. A failed broadcast never invalidates an accepted message.
