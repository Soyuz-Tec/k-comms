# ADR-0076: Use opaque cursor pagination for in-app notifications

## Context

The in-app notification feed is tenant-scoped but can grow without a practical
upper bound. Loading every notification for each refresh creates avoidable
latency and makes the mobile panel harder to use. The feed also needs a clear
way to show only unread notifications without leaking storage details into the
client contract.

## Decision

Keep the existing notification endpoint and response envelope, and add two
optional query parameters: `filter=all|unread` and an opaque `cursor`. The
server owns ordering, unread filtering, cursor encoding, and the `has_more` /
`next_cursor` page metadata. Clients retain the existing default (`all`, first
page) and may request subsequent pages with the returned cursor.

## Consequences

- Existing clients remain compatible because the default request and envelope
  are unchanged.
- The client can provide a compact unread view and load more records without
  knowing database keys or pagination rules.
- Cursor values are implementation details and must be treated as opaque;
  malformed or stale values are rejected through the normal API error path.
- Notification ordering and unread-count semantics remain server-authoritative.

## Validation

The controller and bounded-context tests cover all/unread filtering, cursor
continuation, malformed cursors, and the response metadata. The web client
typecheck, lint, focused notification tests, and responsive UI checks are part
of the release gate.
