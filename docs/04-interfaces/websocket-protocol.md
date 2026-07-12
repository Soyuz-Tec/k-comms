# WebSocket Protocol Draft

## Connection

A short-lived access token identifies tenant, user, device, session, and authentication assurance. Tokens are revalidated or refreshed without requiring indefinite trust in the initial connection.

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
  "command_id": "opaque-id",
  "type": "message.send.v1",
  "payload": {},
  "client_time": "optional-iso-time"
}
```

## Event envelope

```json
{
  "event_id": "opaque-id",
  "type": "message.created.v1",
  "occurred_at": "server-time",
  "conversation_id": "opaque-id",
  "conversation_sequence": 48292,
  "payload": {}
}
```

## Rules

- Unknown event fields must be ignored.
- Unknown event types must not crash clients.
- Durable events carry stable IDs and sequence positions.
- Ephemeral events such as typing do not carry durability promises.
- A reconnect always reconciles against durable state rather than assuming no messages were missed.
