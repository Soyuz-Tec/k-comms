# ADR-0015: Explicit mentions, canonical threads, and durable in-app notification state

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, messaging, web, and security
- **Related requirements:** FR-MSG-001, FR-NOT-001, NFR-SEC-001, NFR-DUR-001

## Context

Users need to direct a message to selected conversation members, follow a
reply chain without reconstructing it in the browser, and act on notification
state across sessions. Parsing `@text` is ambiguous and spoofable. Walking
arbitrary reply ancestry on every read is expensive and allows clients to
disagree about the root. Treating in-app notices as transient delivery attempts
does not preserve read or dismissed state.

## Decision

Mentions are an explicit `mentioned_user_ids` command field, limited to 50 raw
IDs. The messaging transaction locks the conversation, validates every
deduplicated ID as an active member in the same tenant and conversation, and
persists tenant-safe unique `message_mentions` rows. Message text is never
parsed to infer authorization or notification recipients. Service identities
and the sender are not offered by the reference picker; notification fanout is
limited to active human recipients and drops the sender.

Every reply keeps its immediate `reply_to_message_id` and stores the canonical
top-level `thread_root_message_id`. Existing replies are backfilled. Composite
tenant/conversation foreign keys prevent cross-boundary roots. A physical root
deletion clears only reply/root references; normal product deletion remains a
soft-deleted tombstone so thread context is durable. Thread reads return the
root, ascending replies, a reply count, and bounded backward pagination.

In-app notifications remain notification intents with durable `read_at` and
`dismissed_at` state that is valid only for the `in_app` channel. Read,
dismiss, bulk-read, list, and unread-count operations are always scoped to the
authenticated tenant and user. Dismiss implies read. Account-recovery intents
remain excluded. Browser availability events carry IDs, event type, and unread
count only; they never carry message or notification copy. Click-through URLs
are restricted to the `/app` product boundary, while conversation and message
IDs are validated before client navigation.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Parse `@display-name` from message text | Familiar authoring syntax | Ambiguous names, edits change recipients, spoofing risk | Recipient identity must be explicit and authorized |
| Reconstruct a thread by recursively walking `reply_to_message_id` | No new column | Expensive reads and inconsistent roots | Canonical root is a durable domain fact |
| Store in-app notices only in browser memory | Minimal backend state | Lost across devices/reloads and no auditable state | Read and dismiss are user-owned durable state |
| Broadcast notification title/body on the user topic | Immediate rich UI | Content leaks through a broad inbox topic | User-topic events remain content free |

## Consequences

### Positive

- Mention recipients cannot be forged through message text.
- Nested replies converge on one indexed thread root.
- Notification state is consistent across browser sessions and devices.
- Realtime user-topic signals remain safe for broad inbox refresh.

### Negative and accepted trade-offs

- Sending a message with mentions performs membership validation and mention
  inserts in the message transaction.
- Reply rows duplicate the canonical root ID and require a backfill migration.
- The first-release notification center loads a bounded recent window rather
  than an unbounded archive.

### Security and privacy consequences

Composite foreign keys enforce tenant ownership at the database boundary.
Human-only picker/fanout behavior avoids promising delivery to service
identities. Notification presentation uses fixed generic copy and allowlisted
IDs; arbitrary payload keys and external or administrative action URLs are not
exposed.

## Validation

- Transaction, idempotency, inactive/nonmember, cross-tenant, and maximum-count
  mention tests.
- Nested-thread, pagination, tombstone, physical-root deletion, and
  authorization tests.
- User-scoped read/dismiss/bulk-read/unread-count and database-constraint tests.
- Content-free realtime event and safe click-through tests.
- Web tests for human-only selection, failed-send retry, realtime thread merge,
  deleted-root rendering, and notification action failures.
- Migration up/down/up proof and OpenAPI/AsyncAPI mirror validation.

## Revisit triggers

- Federated or guest identities require a broader mention eligibility policy.
- Thread volume requires cursor pagination beyond conversation sequence.
- Notification retention or archive requirements exceed the bounded center.
