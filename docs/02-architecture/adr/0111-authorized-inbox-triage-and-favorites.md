# ADR-0111: Authorized Inbox previews and personal favorites

- Status: Accepted
- Date: 2026-10-06
- Decision owners: K-Comms architecture and domain engineering

## Context

Inbox rows identify a conversation but do not show the latest message or an
unfinished draft. Members need durable favorites and useful previews to choose
their next conversation. Excerpts expand disclosure and must follow the same
current identity and membership boundaries as the underlying messages.

## Decision

The REST conversation list optionally composes `Messaging.inbox_summaries/2`
with the existing Conversations projection. ConversationContent owns message
and draft reads; Conversations retains membership and favorite persistence.
No foreign schema or direct cross-owner table read is introduced.

The Messaging operation accepts at most 500 authorized candidate conversation
IDs and performs batched reads, selecting the latest main-timeline message and
only the requesting user's unexpired main draft. SQL bounds each excerpt to
200 characters. It returns no attachment names, URLs, private encrypted content,
thread reply bodies, deleted or moderated bodies, or guest-admission history.
Retained sender labels use IdentityAccess's existing privacy-minimal projection.
Authorization is derived again from the current human workspace grant before
final disclosure; departed, archived and unavailable ephemeral conversations
remain excluded. The adapter uses the first 500 current conversations; other
rows remain usable without an excerpt. This is not a full-history retrieval API.

`Conversations.put_favorite/3` changes only the current active member's boolean
preference. It retains current content-write authority and updates the authorized
membership row atomically. The idempotent PUT uses last writer wins for this
reversible private preference; it does not mutate membership role, version,
conversation activity timestamps or anyone else's favorite. The migration adds
a non-null boolean with a false default to the existing membership owner table.
Old runtimes ignore the additive column, leaving the value intact during image
rollback; no new confidential record, release rollback hazard or retention
obligation is introduced. Existing membership fingerprint and erasure paths
continue to own the row.

The browser scopes conversation state and asynchronous responses to current
workspace, account, device and credential authority. Membership events remove
revoked rows immediately, invalidate older snapshots and clear excerpts before
refresh. Failed refreshes drop cached previews. A successful favorite write
invalidates in-flight list responses. Local draft previews reuse the existing
identity-scoped draft store and prioritize a local clear over an older server
preview. They add no new plaintext browser persistence.

Calls and Phone keep their existing owner facades. Call-history filters apply
exact conversation/initiator and time criteria before authorized pagination;
Phone filters use other-party number, direction and UTC range. Voicemail caller
numbers come only from authorized same-tenant call records and are not verified
caller identity. The meeting agenda extends across calendar months using the
existing bounded query; personal calendar export is not attendee invitation.

## Qualification

Exercise current membership, cross-tenant, private-mode, deleted/moderated,
expired-draft and suspended-user exclusions through the real owner and REST
paths. Verify preference persistence, stale list responses, account changes,
local draft priority, filter controls and browser interactions. Validate the
exact facade snapshot and unchanged strict dependency baseline, contracts,
forward migration, build and regression gates.

Local evidence does not establish licensed competitor parity, real carrier,
calendar or native-device acceptance. The intentionally offline staging VM and
independent production approval remain external release gates.
