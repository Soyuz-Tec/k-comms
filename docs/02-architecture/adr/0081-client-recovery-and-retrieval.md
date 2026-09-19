# ADR-0081: Client recovery and precise retrieval

## Status

Accepted, 2026-09-19.

## Context

Creation-order message replay cannot recover offline changes to existing
messages. Local storage may reject draft writes, and file search must reach a
particular result outside the first recent-files page.

## Decision

- Keep the existing message API and creation cursor. On reconnect, reread the
  loaded message range in authorized, sequential pages of at most 200 rows,
  bounded by the existing 500-page safety limit. Apply a completed read only
  to unchanged loaded rows. Keep later sends/history pages and retry rows that
  changed during the read. Cancel stale reconciliation after conversation
  changes or another disconnect, and retry failed reads with bounded backoff.
- Keep failed draft writes in tenant/user-scoped tab memory, including empty
  tombstones after sends, and clear that fallback on sign-out. Only successful
  persistent writes may produce a saved-on-device assurance. Tab memory does
  not survive reload, and the composer says so.
- File search opens the exact authorized source message using the existing
  message/sequence deep link. Legacy files links apply their conversation
  filter, allow paginated lookup, and focus a matched row. Category filtering
  remains limited to loaded pages and explicitly describes that scope until
  all pages have been read.

## Consequences and alternatives

There is no new service, public API, durable message-mutation cursor, or storage
authority. Reconnect adds reads proportional to the already loaded window;
the safety limit remains visible through retry/error behavior. A separate
mutation feed or server file-category filter can be evaluated against measured
workloads rather than introduced for this repair. Failed draft persistence
still requires sending before closing the tab. Downloads remain separately
authorized and scan-gated.

## Validation

Regression tests cover offline edits/deletes/reactions, multiple loaded pages,
later events, retry after failure, full storage with conversation switching,
sign-out cleanup, exact file source links, older-page category matches, and
missing legacy targets. Physical-device and live two-client qualification are
separate release checks; these deterministic tests do not establish them.
