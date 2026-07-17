# Database Schema Draft

**Status:** Conceptual

## Core tables

```text
tenants
tenant_settings
users
identities
devices
sessions
socket_tickets
password_recovery_requests
service_accounts
platform_role_grants
invitations

conversations
conversation_members
conversation_roles
conversation_sequences

audio_calls
audio_call_participants

messages
message_revisions
message_reactions
message_mentions
read_cursors

attachments
attachment_variants
attachment_scan_attempts

notification_preferences
notification_intents
notification_attempts
webhook_endpoints
webhook_subscriptions
webhook_secret_versions
webhook_deliveries

outbox_events
background_jobs
audit_events
retention_policies
legal_holds
deletion_requests
moderation_cases
moderation_actions
```

`tenant_settings` stores the versioned admission limits
`max_active_users`, `max_active_conversations`, and
`max_conversation_members`. Database checks keep them within reviewed bounds;
the member minimum is two so direct conversations remain possible. Admission
counts are evaluated under a tenant-scoped transaction advisory lock rather
than inferred from cached UI state.

`audio_calls` stores the authoritative bounded call lifecycle, immutable
`media_kind` (`audio` or `video`), exact `expires_at`, and an opaque,
server-derived provider room. The historical table name is retained as the
compatibility/migration boundary defined by ADR-0025. The one-active-call index
applies across both media kinds. Creating a call also
inserts one unique `CommsWorkers.AudioCallExpiryWorker` job, scheduled for that
deadline, in the same transaction; a committed call cannot exist without its
durable expiry work. `audio_call_participants` stores one opaque
provider identity and its tenant/call/conversation/user/device/session bindings,
credential issuance count and time, revocation reason/time, and durable eviction
state, attempts, enforcement horizon, and last-success evidence. It never stores
the signed participant JWT, API secret, SDP/ICE, or media. Composite foreign
keys preserve tenant ownership. No camera, screen, SDP/ICE, RTP/SRTP, recording,
or media-derived content is stored. The active call/session uniqueness boundary
prevents two live admissions for the same session, while provider identity is
unique per tenant. Pending/enforcing eviction indexes support the media worker.

`password_recovery_requests` is tenant/user scoped and stores only a reset-token
hash, expiry, consumption time, invalidation time, and timestamps. A new request
invalidates prior outstanding rows for the user. Raw tokens and action URLs are
never database fields; notification intents persist only the non-secret
recovery request UUID.

`service_accounts` is tenant scoped and references its dedicated internal user
and device. The linked `users.account_type` is `service`, its internal address
uses the non-routable `.invalid` namespace, and presenters never expose that
address. The account stores name, credential prefix/hint, a 32-byte SHA-256
secret digest, bounded scopes,
status, expiry, last-use, rotation/revocation timestamps, optimistic version,
and timestamps. Raw `kcsa_` credentials are never persisted. Composite foreign
keys keep tenant, user, and device ownership aligned; the credential prefix is
globally unique and active/expiry indexes support authentication.

`platform_role_grants` is a one-to-one, tenant/user-scoped authorization record
for a human operator. Its primary key is a random per-approval identifier, and
it stores the approved role, exact UTC expiry, and timestamps; the reason and
approving actor remain in immutable audit evidence. Grant and renewal replace
the row so the identifier cannot be reused by an older subject. The effective
grant must be unexpired and its identifier/role/deadline tuple must match the
authenticated subject. The legacy `users.platform_role` column is constrained
to null so application rollback fails closed instead of discarding expiry.

## Required key patterns

```sql
-- Idempotent sender retry
UNIQUE (tenant_id, sender_device_id, client_message_id)

-- Canonical order within a conversation
UNIQUE (conversation_id, conversation_sequence)

-- One membership per user per conversation
UNIQUE (conversation_id, user_id)

-- One explicit mention per user and message
UNIQUE (message_id, user_id)

-- A canonical thread root cannot cross tenant or conversation ownership
FOREIGN KEY (tenant_id, conversation_id, thread_root_message_id)
  REFERENCES messages (tenant_id, conversation_id, id)

-- A provider participant identity cannot be substituted across tenant state
UNIQUE (tenant_id, provider_identity)

-- One admitted provider identity per call and authenticated session
UNIQUE (audio_call_id, session_id) WHERE status = 'admitted'

-- One active call of either media kind per conversation
UNIQUE (tenant_id, conversation_id) WHERE status IN ('active', 'ending')
```

Replies retain the immediate `reply_to_message_id` and denormalize the
top-level `thread_root_message_id` for bounded indexed reads. Mention rows have
composite tenant/message and tenant/user foreign keys. `notification_intents`
stores `read_at` and `dismissed_at` only when `channel = 'in_app'`; dismissal
requires read state, and a partial tenant/user index serves unread counts.

## Indexing principles

- Lead tenant-scoped queries with `tenant_id` where useful for isolation and locality.
- Index synchronization by `(conversation_id, conversation_sequence)`.
- Index threads by `(conversation_id, thread_root_message_id, conversation_sequence)`.
- Index user inbox queries by membership/user and last activity.
- Keep partial indexes for active sessions, pending jobs, and live webhook deliveries.
- Avoid indexing large message bodies unless required by the selected search approach.

## Partitioning triggers

Evaluate message-table partitioning when one or more are true:

- Vacuum or maintenance windows threaten SLOs.
- Index working sets no longer fit expected memory budgets.
- Retention deletion requires large, frequent row-by-row operations.
- A tenant or time range must be isolated for residency or lifecycle reasons.

## Migration requirements

- Use expand-and-contract changes.
- Set lock-time and statement-time budgets.
- Backfill in bounded batches with resumable progress.
- Rehearse against production-scale staging data.
- Do not make a release depend on a long blocking migration.
