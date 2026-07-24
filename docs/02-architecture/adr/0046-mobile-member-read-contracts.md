# ADR-0046: Add owner-projected mobile member read contracts

- **Status:** Accepted
- **Date:** 2026-07-24
- **Owners:** Architecture, IdentityAccess, Conversations, ConversationContent,
  Calls, and Web
- **Related decisions:** ADR-0025, ADR-0027, ADR-0038, ADR-0040, ADR-0043,
  ADR-0045

## Context

The responsive member experience needs searchable people, one-action direct
conversation start, authorized file discovery, and a Calls destination. The
existing released APIs are either unbounded (`GET /api/v1/users`), scoped to one
resource (`GET /api/v1/attachments/:id` and conversation call endpoints), or
return a duplicate-direct conflict instead of idempotently resuming an existing
direct conversation.

Implementing these screens with browser-side fan-out or web-owned database joins
would leak owner persistence, weaken tenant authorization, and make cursors
unstable. Existing call persistence records room lifecycle and credential
admission. It does not prove ringing, answer, missed/declined outcome, or
per-user duration, so the product must not infer those states.

## Decision

Add four bounded contracts while keeping source tables and dependency directions
unchanged:

1. IdentityAccess exposes a cursor-based active-human directory through
   `CommsCore.Accounts.DirectoryPersonView`. Search, tenant, status, account type,
   and caller exclusion are enforced by the owner. Literal case-insensitive
   substring search uses PostgreSQL `pg_trgm` with a partial active-human GIN
   index so the existing search behavior remains indexable.
2. Conversations exposes an atomic get-or-create-direct operation. Concurrent or
   repeated requests return the same `ConversationView` plus whether the
   operation created it.
3. ConversationContent exposes `CommsCore.Attachments.FileView` and a stable
   cursor query. It may join owner-local message and attachment tables only
   through a Conversations-owned composable active-membership authorization
   projection. File projections carry source conversation, message, sequence,
   safety, ownership, and timestamps but no object-storage identity, checksum,
   or presigned URL.
4. Calls exposes `CommsCore.AudioCalls.CallSessionView` and a stable cursor query
   over room-lifecycle records joined to the same Conversations-owned
   authorization projection. The projection may state modality,
   active/ending/ended state, room-session timestamps/duration, and `can_end`.
   It must not state ringing, answered, missed, declined, scheduled, or
   per-user duration.

The shared authorization projection is supported by a partial
`conversation_memberships (tenant_id, user_id, conversation_id)` index for
active memberships (`left_at IS NULL`). Consumers still join through the
Conversations facade and do not acquire membership table ownership.

The web adapter adds:

```text
GET  /api/v1/directory/users
POST /api/v1/direct-conversations
GET  /api/v1/files
GET  /api/v1/calls
```

All list endpoints use bounded limits and opaque stable cursors. The legacy
`GET /api/v1/users` remains temporarily for compatibility. Attachment downloads
continue through the existing authorized endpoint, and call start/join/end
continue through conversation-scoped commands.

The source-message navigation contract is:

```text
/app?conversation=<id>&search_message=<id>&search_sequence=<n>
```

The client fetches a bounded message window when the source is not already
loaded.

## Consequences

- Mobile lists avoid unbounded client fan-out and unbounded in-process
  authorization identifier materialization; dependent owners join the
  Conversations projection in the database.
- Web composes and serializes Ecto-free projections only.
- Direct-message quick actions are idempotent without weakening quota,
  membership, or direct-key uniqueness rules.
- Files remain message-owned for authorization, retention, moderation, and
  audit purposes.
- The Calls destination is intentionally a room-session view. Authoritative
  incoming, ringing, missed, and declined calling remains a separate future
  decision requiring Calls-owned invitations and signed provider facts.
- No new service, shared kernel, database, or deployment unit is introduced.

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| Load every user, message, file, and call then filter in React | Unbounded, slow, and easy to authorize incorrectly. |
| Let `CommsWeb` join owner tables | Violates the strict modular-monolith boundary and leaks persistence. |
| Add duplicate mobile read-model tables immediately | Creates new consistency and repair obligations before query load proves the need. |
| Treat ended room rows as missed or answered calls | The current data cannot prove those user outcomes. |
| Split Directory, Files, or Calls into services | There is no independent deployment requirement; distribution would weaken current transactions. |

## Validation

- Core tests cover cursor ordering, malformed cursors, active-human filtering,
  idempotent/concurrent direct creation, file visibility and safety, call-session
  truthfulness, cross-tenant/cross-conversation denial, index validity, and
  authorization-predicate query-plan selection.
- Controller tests cover limits, filters, suspended/service identities,
  archived/left/deleted sources, and response redaction.
- OpenAPI declares all four routes and projection schemas.
- `context-boundaries.yaml` declares the new public contracts without adding
  context dependencies or table ownership.
- The strict architecture validator, deterministic report, mutation tests, and
  both `comms_core` xref cycle gates remain green.
