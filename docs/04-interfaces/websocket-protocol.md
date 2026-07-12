# WebSocket Protocol

## Connection

A short-lived access token identifies tenant, user, device, and session. The
session and conversation membership are revalidated for every command.

## Topic namespaces

```text
user:<user_id>
device:<device_id>
conversation:<conversation_id>
tenant:<tenant_id>:announcements
call:<call_id>
```

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
  "body": "Example message",
  "status": "active",
  "inserted_at": "server-time"
}
```

## Rules

- Unknown event fields must be ignored.
- Unknown event types must not crash clients.
- Durable events carry stable IDs and sequence positions.
- Ephemeral events such as typing do not carry durability promises.
- A reconnect always reconciles against durable state rather than assuming no messages were missed.
- Session revocation or membership removal stops further commands and events.
