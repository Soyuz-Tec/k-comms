# REST API

## Resource groups

- `/api/v1/bootstrap`, `/api/v1/sessions`, and `/api/v1/me`
- `/api/v1/users`
- `/api/v1/conversations`
- `/api/v1/channels/discover`, `/api/v1/channels/{channel_id}/join`, and `/api/v1/channels/{channel_id}/membership`
- `/api/v1/conversations/{conversation_id}/members`
- `/api/v1/conversations/{conversation_id}/messages`
- `/api/v1/conversations/{conversation_id}/messages/{message_id}/thread`
- `/api/v1/conversations/{conversation_id}/call` and
  `/api/v1/conversations/{conversation_id}/calls` for unified audio/video
  lifecycle and participant admission
- `/api/v1/in-app-notifications` and its user-owned read/dismiss operations
- `/api/v1/attachments`
- `/api/v1/search`
- `/api/v1/me/push-subscriptions/config` and `/api/v1/me/push-subscriptions`
- `/api/v1/admin/audit-events` and `/api/v1/admin/audit-events/export`
- `/api/v1/admin/service-accounts` for step-up-authenticated lifecycle management
- `/api/v1/admin/tenant` for versioned policy, admission limits, and live usage
- `/api/v1/moderation/cases` and `/api/v1/admin/retention-policies`, `/api/v1/admin/legal-holds`, and `/api/v1/admin/deletion-requests`
- `/api/v1/admin/webhooks`, `/api/v1/admin/webhook-deliveries`, and `/api/v1/admin/attachment-safety`
- `/api/v1/ops` and the content-free `/api/v1/platform/ops` operator view;
  both snapshots include the validated immutable `release_revision` used for
  revision-bound operational runbook links
- `/api/v1/service/conversations`, `/api/v1/service/conversations/{conversation_id}/messages`, and `/api/v1/service/search` for scope-bound automation

## Mutation input and replay rules

The canonical OpenAPI file defines every implemented mutation body. Profile
updates change `display_name` and do not use a resource version. For compatibility,
clients may echo `email` only when it normalizes to the current recovery
address; a different value returns `email_change_requires_verification` and is
not persisted.
Password changes require `current_password` and `new_password`. Conversation
updates require `version` plus an optional `title` or `visibility`; archive,
member-role changes, member removal, and public-channel leave also require the
current resource or membership `version`. Missing versions return 428 and stale
versions return 409.

Moderation, invitation, retention-policy, legal-hold, and deletion-request
creation may carry an `Idempotency-Key`. A new resource returns 201; a replay
returns 200 and never reissues a one-time token or secret. Versioned governance
transitions use their explicit reason field: `reason` for invitation and user
lifecycle operations, `release_reason` for legal-hold release, and
`transition_reason` for deletion approval, rejection, or cancellation.

Invitations enroll only new human identities. Creation or acceptance conflicts
with an existing tenant email in any lifecycle state. Suspended users retain
their password and use the step-up-authenticated, versioned admin lifecycle
operation for an audited reactivation.

Webhook create/update bodies contain only the endpoint name, HTTPS URL, status,
and subscribed event types. Secret rotation and delivery replay have no request
body. Operational retry accepts `{resource_type, id}`, where `resource_type` is
`notification`, `webhook`, or `attachment_scan`.

## Audio and video calls

`GET /api/v1/conversations/{conversation_id}/call` returns the one active,
non-expired call of either media kind or `null`. `POST
/api/v1/conversations/{conversation_id}/calls` requires `{ "media_kind":
"audio" }` or `{ "media_kind": "video" }`. An active call of the requested
kind is idempotently returned with a newly authorized short-lived participant
credential; a different requested media kind conflicts and never mutates a
live room's grants.

Current active members join through `POST
/api/v1/conversations/{conversation_id}/calls/{call_id}/join`. The starter,
conversation owner, or moderator ends the room through `POST
/api/v1/conversations/{conversation_id}/calls/{call_id}/end`. A local leave is a
client/provider operation and does not end the durable call. Every response
includes immutable `media_kind`; provider room names and identities are never
public fields.

`allow_audio_calls` and `allow_video_calls` are separate versioned tenant
settings. Audio grants publish only microphone. Video grants publish only
microphone, camera, screen share, and screen-share audio; neither kind permits
data publication, metadata mutation, administration, recording, or arbitrary
provider sources. The public status resource reports both `audio_calls` and
`video_calls` capability booleans.

The historical `/audio-call` and `/audio-calls` routes remain deprecated audio
aliases for existing clients. New clients use the canonical call routes. Join
credentials are transient secrets: clients keep them in memory, never URLs or
durable storage, and discard them on failure, leave, end, or teardown.

## Message creation example

```http
POST /api/v1/conversations/{conversation_id}/messages
Idempotency-Key: device-generated-value
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "body": "Example message",
  "reply_to_message_id": null,
  "mentioned_user_ids": ["active-conversation-member-id"],
  "attachment_ids": []
}
```

The `Idempotency-Key` header is the client message identifier. A successful
response includes the canonical message ID, conversation sequence, server
timestamp, and normalized representation. Retrying the same key returns the
same canonical record and does not create another audit or outbox event.
`mentioned_user_ids` is an explicit, deduplicated list of at most 50 raw IDs.
Every ID must resolve to an active member in the same tenant and conversation;
the server never derives mentions from message body text.

Reactions use
`POST /api/v1/conversations/{conversation_id}/messages/{message_id}/reactions`
with an `emoji` body and
`DELETE /api/v1/conversations/{conversation_id}/messages/{message_id}/reactions/{emoji}`
for removal. The delete operation returns 204 and is documented independently
because the emoji is a path parameter.

## Canonical thread read

```http
GET /api/v1/conversations/{conversation_id}/messages/{message_id}/thread?limit=50&before_sequence=48291
```

The target may be a root or nested reply. The response returns the canonical
root, ascending replies, total reply count, and `page.has_more` plus
`page.next_before_sequence`. A normally deleted root is returned as a durable
tombstone. Authorization is re-evaluated against current conversation
membership.

## In-app notification center

`GET /api/v1/in-app-notifications` returns the current user's bounded,
non-dismissed in-app notices and `meta.unread_count`. `GET
/api/v1/in-app-notifications/unread-count` is the lightweight count endpoint.
`PATCH /api/v1/in-app-notifications/{id}/read` and `DELETE
/api/v1/in-app-notifications/{id}` are idempotent user-scoped read and dismiss
operations. `POST /api/v1/in-app-notifications/read-all` marks the current
visible user scope read and returns a freshly queried unread count. Recovery
intents and delivery-attempt administration are not exposed through this
center. Presented copy is generic, and optional action URLs are restricted to
the `/app` route boundary.

## Sync query

```http
GET /api/v1/conversations/{conversation_id}/messages?after_sequence=48291&limit=200
```

The response includes `page.has_more`, `page.next_after_sequence`, and
`page.reset_required`, making truncation and reset boundaries explicit.

## Public-channel discovery and self-membership

Authenticated users discover only non-archived `channel` conversations with
`tenant` visibility in their own tenant. `GET /api/v1/channels/discover`
supports a title query, bounded page size, and an opaque continuation cursor;
each result includes active member count plus the caller's joined state and
versioned membership summary when joined.

`POST /api/v1/channels/{channel_id}/join` is atomic and idempotent. A repeated
join returns the same active membership with `replayed: true` and does not emit
another audit or outbox event. `DELETE /api/v1/channels/{channel_id}/membership`
requires the membership `version`,
prevents removal of the last active owner, and is replay-safe after a successful
leave. Direct, group, private, archived, and cross-tenant resources cannot use
these self-service routes. Disabling tenant public channels blocks discovery and
new joins while still permitting existing members to leave.

## Browser push subscriptions

Push registration is scoped to the current authenticated user and device.
`GET /api/v1/me/push-subscriptions/config` returns availability and the
provider's VAPID public key. `GET /api/v1/me/push-subscriptions` returns only
IDs, device ID, hostname hint, status, and timestamps; it never returns an
endpoint, `p256dh`, `auth`, ciphertext, or key metadata.

After an explicit browser permission grant, the client sends the standard
`PushSubscription` endpoint, optional millisecond expiration, and base64url
keys to `POST /api/v1/me/push-subscriptions`. Registration validates HTTPS and
key shapes, is idempotent for an unchanged endpoint, and advances the encrypted
generation on key change or explicit re-registration. `DELETE
/api/v1/me/push-subscriptions/{subscription_id}` can revoke only a subscription
owned by the current device. Revoking a device or user also revokes its active
subscriptions.

## Service-account boundary

Admin list/create/rotate/revoke operations use the normal human bearer token,
tenant-admin authorization, recent step-up, versions, and reasons. Create and
rotate return `credential` exactly once alongside the safe service-account
representation. The credential format is `kcsa_<uuid>.<secret>`; list and
subsequent reads return only `credential_prefix` and `secret_hint`.
If `expires_at` is omitted, the credential expires after 90 days; callers may
choose an earlier or later expiry up to an absolute maximum of one year.

Service calls send that credential as `Authorization: Bearer ...` to the
separate `/api/v1/service/*` routes. `conversations:read` lists only active
memberships; `messages:read` reads paginated history; `messages:write` sends
through the normal message transaction and requires `Idempotency-Key`; and
`search:read` searches only readable conversations. A service credential is
never valid for `/api/v1/me`, `/api/v1/admin/*`, platform operations, refresh,
or WebSocket authentication.

## Tenant admission limits

`GET /api/v1/admin/tenant` returns versioned settings plus `usage` for active
identities, active conversations, and the largest active conversation. The
usage object repeats the effective limits and exposes separate `at_capacity`
and `over_limit` flags for each dimension and for the tenant overall. Active
identity usage includes service identities and excludes suspended/deleted
users; archived conversations and left memberships do not consume their
respective capacity.

`PATCH /api/v1/admin/tenant` updates `max_active_users`,
`max_active_conversations`, and `max_conversation_members` with the normal
optimistic `version` and privileged authorization boundary. The minimum member
limit is two. Lowering a limit below usage is non-destructive and makes the
over-limit state explicit. New admissions return stable 409 codes:
`active_user_quota_exceeded`, `active_conversation_quota_exceeded`, or
`conversation_member_quota_exceeded`.

The first release intentionally has no total-storage quota. Attachment storage
admission remains bounded by the tenant `max_attachment_bytes` per-file policy
and authenticated endpoint rate limits. Object-store capacity and lifecycle are
operationally monitored; a future aggregate byte quota requires reservation and
reconciliation semantics.

## Audit evidence export

`POST /api/v1/admin/audit-events/export` accepts the same tenant-scoped evidence
dimensions used by the audit explorer: bounded free text, action, resource type,
actor user ID, request ID, and an `after`/`before` time window. The route requires
an eligible audit role and recent password step-up. It returns `text/csv` with an
attachment filename plus `X-Export-Row-Count` and `X-Export-Truncated` response
headers.

Exports default to 1,000 rows and cannot exceed 5,000 rows. Results are ordered
newest first and the cap is applied only after tenant and requested filters.
Every CSV cell is quoted, NUL bytes are removed, embedded quotes are escaped,
and cells that spreadsheet software could interpret as formulas are prefixed
with an apostrophe. Each successful export records an `audit.export` event with
the applied structured filters, returned count, cap, and truncation state; raw
free-text query content is deliberately not copied into audit metadata. The
interactive UI downloads the server-provided file and warns when the result was
truncated so an administrator can narrow the filter.
