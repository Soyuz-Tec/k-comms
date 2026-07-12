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
```

Only the authenticated user may join `user:<user_id>`. That topic carries
content-free conversation activity/membership and notification-availability
signals for inbox refresh. It does not carry message or notification bodies.
Conversation topics require active membership.

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

## Rules

- Unknown event fields must be ignored.
- Unknown event types must not crash clients.
- Durable events carry stable IDs and sequence positions.
- Ephemeral events such as typing do not carry durability promises.
- A reconnect always reconciles against durable state rather than assuming no messages were missed.
- Session revocation or membership removal stops further commands and events.
