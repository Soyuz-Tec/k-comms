# Offline Synchronization

## Client state

- Last applied sequence per active conversation
- Last global inbox/activity cursor where provided
- Stable device ID
- Pending local commands and idempotency keys

## Reconnect algorithm

1. Reauthenticate or refresh session.
2. Join relevant topics with last durable cursors.
3. Fetch missing pages until current.
4. Apply events idempotently in sequence order.
5. Reconcile pending commands by idempotency key.
6. Resume live processing.

## Required tests

- Disconnect between commit and broadcast.
- Duplicate broadcast after replay.
- Reconnect to a different node.
- Membership removal while offline.
- Retention boundary crossed while offline.
- Client clock far ahead or behind server time.
