# Ordering, Idempotency, and Replay

## Ordering

A monotonically increasing `conversation_sequence` defines canonical order. The allocation mechanism must be benchmarked against hot-conversation workloads and must never depend on a single global process.

## Idempotency

Scope the client key by `(tenant_id, sender_device_id, client_message_id)`. Store enough canonical response data to return the same message ID and sequence on retry.

## Replay

Clients persist the highest fully applied sequence. The server returns messages with a greater sequence, in ascending order, with an opaque continuation cursor when the page is truncated.

The creation sequence is not a mutation cursor: editing, deleting, or reacting
does not advance it. After reconnect, the member web client separately rereads
the entire loaded message window through authorized history pages of at most
200 rows. It preserves older loaded pages and later sends. Messages changed by
a socket event during that read retain their newer local state and trigger a
follow-up reconciliation. Failed reads retry with bounded backoff and never
replace the visible window with an incomplete result. See
[ADR-0081](../02-architecture/adr/0081-client-recovery-and-retrieval.md).

## Gap behavior

If the server detects that requested history is no longer available because of retention, it returns an explicit reset boundary and a state-snapshot procedure rather than silently skipping data.
