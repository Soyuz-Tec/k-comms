# WebSocket Protocol

## Connection

An authenticated HTTPS client first creates a socket ticket with
`POST /api/v1/socket-tickets`. The returned random ticket is short lived,
stored only as a hash, bound to tenant/user/device/session, and consumed exactly
once during the WebSocket handshake. Access and refresh tokens are never placed
in the WebSocket URL. Every reconnect obtains a new ticket before replaying from
the last contiguous durable cursor.

The active session and conversation membership are revalidated for every
command and outbound event. Revocation disconnects the session socket.

## Topic namespaces

```text
user:<user_id>
conversation:<conversation_id>
whiteboard:<conversation_id>
call:<call_id>
```

Only the authenticated user may join `user:<user_id>`. That topic carries
content-free conversation activity/membership and notification-availability
signals for inbox refresh. It does not carry message or notification bodies.
Conversation topics require active membership.
Whiteboard topics require current whiteboard authorization. Workspace humans
must hold active membership. A conversation-only human or guest must hold an
active membership in that exact active or idle instant room; an ordinary guest
link is denied. The server rechecks this boundary on join, inbound pointer or
selection commands, and outbound event interception.
Call topics require an active admitted call participant and the exact
conversation ID. The server rechecks session, membership, call state, and
admission before every hand/reaction command and before every outbound event.

## Join payload

```json
{
  "protocol_version": 1,
  "after_sequence": 48291,
  "client_capabilities": ["message_revisions", "attachment_v2"]
}
```

## Command envelope

```json
{
  "command_id": "device-generated-idempotency-key",
  "type": "message.send.v1",
  "payload": {"body": "Example message"},
  "client_time": "optional-iso-time"
}
```

Commands are sent with the Phoenix event name `command`. Supported command
types are `message.send.v1`, `conversation.read.v1`, `typing.start.v1`, and
`typing.stop.v1`.

## Durable event payload

```json
{
  "id": "message-id",
  "conversation_id": "opaque-id",
  "conversation_sequence": 48292,
  "client_message_id": "device-generated-idempotency-key",
  "reply_to_message_id": null,
  "thread_root_message_id": null,
  "thread_reply_count": 0,
  "mentioned_user_ids": [],
  "body": "Example message",
  "status": "active",
  "inserted_at": "server-time"
}
```

The content-free `notification.available.v1` user-topic payload contains only
`notification_id`, `event_type`, optional conversation/message IDs, and the
current unread count. Clients fetch the authenticated notification-center REST
resource before presenting copy or navigating.

Conversation topics also carry content-free `call.started.v1` and
`call.ended.v1` events. Their payload identifies the call, conversation,
immutable `media_kind`, lifecycle status/times, and current caller end
capability. Clients reconcile through `GET
/api/v1/conversations/{conversation_id}/call`; they never exchange provider
credentials, participant state, camera/screen state, SDP, ICE, RTP, or SRTP over
Phoenix, except for the explicitly opted-in one-to-one audio negotiation below.

The call topic accepts `call.hand.set.v1` with a boolean `raised` field and
`call.reaction.v1` with one allowlisted emoji. It emits `call.hand.v1`,
`call.reaction.v1`, `call.participant_muted.v1`, and
`call.participant_removed.v1`. Raised-hand state is durable Calls-owned state;
reactions are bounded, rate-limited, and ephemeral. These payloads contain user
or participant IDs only and never provider rooms, provider identities, track
SIDs, credentials, signaling, or media.

For an active audio call in a direct conversation, a client may add
`direct_audio: true` to the call-topic join. When the feature is enabled and the
session remains admitted, the join response contains an unpredictable
connection-scoped `peer_id` and a public STUN-only `ice_servers` list.
`call.direct.peers.v1` carries only the active direct peer IDs and their user
IDs. `call.direct.signal.v1` accepts a target peer ID and one allowlisted
offer, answer, ICE candidate, microphone-state, or fallback signal. The server
re-authorizes each command, requires the target to be a different present user,
bounds SDP to 16 KiB and candidates to 2 KiB, and limits a call session to 240
signals per minute. These events are ephemeral: they are not replayed,
persisted, audited, placed in the outbox, or logged. RTP and SRTP media never
traverse Phoenix.

Conversation topics emit `message.delivery.v1` after an authorized device
advances its delivery/read cursor. The payload is a content-free cursor
projection with a conversation-scoped hashed device reference. Clients always
reconcile receipts through REST after reconnect.

The whiteboard topic carries durable `whiteboard.operation_applied.v1` notices
and ephemeral bounded `whiteboard.presence.v1` pointer/selection state. Clients
replay canonical operations over their authorized member or server-scoped guest
REST route after reconnect or a sequence gap. Phoenix does not own scene
durability, canonical ordering, or authorization state.

## Rules

- Unknown event fields must be ignored.
- Unknown event types must not crash clients.
- Durable events carry stable IDs and sequence positions.
- Ephemeral events such as typing do not carry durability promises.
- A reconnect always reconciles against durable state rather than assuming no messages were missed.
- Session revocation or membership removal stops further commands and events.
