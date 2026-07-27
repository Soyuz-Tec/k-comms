# ADR-0052: Retain message sender labels as an authorized history sidecar

**Status:** Accepted

## Context

Messages retain an immutable `sender_user_id`, while active participant lists
correctly exclude departed and expired guests. Resolving message authors only
from the active roster therefore loses the visible username after a reload.
Copying a display name into message content, metadata, or `message.created.v1`
would duplicate identity data across ownership boundaries, freeze stale names,
and complicate erasure, retention, legal hold, and contract compatibility.

## Decision

IdentityAccess publishes `RetainedSenderLabelView`, containing only `id`,
`display_name`, and the required boolean `redacted` marker. Its bounded,
tenant-scoped resolver accepts only user IDs
derived inside ConversationContent from an already authorized and
guest-history-clipped message page. It includes retained expired identities,
but always projects erased identities as `Deleted user`.

ConversationContent exposes an opt-in `include=sender_labels` sidecar on
durable history, thread, and search pages. It slices each authorized page
before batching sender IDs and never accepts caller-supplied label IDs. A
thread sidecar is limited to its authorized root and sliced replies; a search
sidecar is limited to the membership-filtered result page. The default
responses, message representation, realtime event payloads, AsyncAPI, and
closed message JSON Schemas remain unchanged. Active participant roster
semantics also remain unchanged.

An already-rendered window can refresh labels in bounded batches of at most
200 representative message IDs without replaying message content. Clients
select one loaded message per distinct sender. ConversationContent first
authorizes the conversation, applies the guest admission history floor, and
derives authors only from exact matching messages in that visible history
scope before invoking IdentityAccess. This preserves erasure reconciliation
for messages older than the newest history page without creating a
tenant-directory enumeration surface or scanning a conversation by guessed
identity IDs.

Clients cache the sidecar separately from messages and refresh only one
representative message for each departed sender in the current window. An
explicit `redacted: true` label is a sticky tombstone that outranks active and
stale identity caches; otherwise current active identity data takes precedence
over a retained label, with a neutral fallback last.
Internal UUIDs remain the authorization, de-duplication, and correlation keys;
display names are visible identifiers only.

## Consequences

- Departed or expired authors remain understandable anywhere their retained
  messages are authorized for display.
- A label lookup cannot enumerate a tenant directory or reveal email, role,
  lifecycle state, account type, or expiry.
- Erasure remains effective because future history reads resolve the current
  `Deleted user` projection rather than an immutable copied name. Clients do
  not infer erasure from that display string, so a legitimate user named
  `Deleted user` remains an ordinary, renameable identity when
  `redacted: false`.
- Sender labels follow the retained user and message policies. Legal hold can
  retain message content, but does not override identity erasure.
- The IdentityAccess public contract list grows by one narrow projection, and
  the cumulative reviewed manifest transition now cites this accepted ADR.

## Alternatives rejected

- Store a sender snapshot in message metadata or content: spoofable unless
  overwritten, duplicates identity data, and changes event/privacy semantics.
- Change the active member resolver: would make expired guests visible in the
  roster and widen an unrelated contract.
- Add one label endpoint per message: creates chatty access and enumeration
  risks without improving consistency.

## Validation

- Accounts tests cover tenancy, expiry, erasure, input bounds, and label-only
  output.
- Messaging and controller tests cover page-only batching, opt-in response
  shape, guest history clipping, and unchanged default responses.
- Web tests cover full reload, multi-page catch-up, active-roster precedence,
  sender refresh beyond a 200-message replay window, and safe fallbacks.
- OpenAPI and architecture validation must pass without modifying AsyncAPI or
  `message.created.v1`.
