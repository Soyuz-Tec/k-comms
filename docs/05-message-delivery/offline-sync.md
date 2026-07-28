# Offline Synchronization

## Client state

- Last applied sequence per active conversation
- Last global inbox/activity cursor where provided
- Stable device ID
- Pending local commands and idempotency keys

These synchronization records describe application reconciliation, not a
service-worker data cache. The install-scoped PWA worker stores only the fixed
offline document and revisioned static application assets. It must not cache
sessions, tokens, API responses, sockets, messages, drafts, contacts,
attachments, signed URLs, invitation material, call state, or media.

K-Comms does not currently provide an offline send queue or background message
sync. A disconnected installed client shows the fixed offline state and
reconciles from the authoritative server after connectivity returns.

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
