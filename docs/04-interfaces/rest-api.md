# REST API Draft

## Resource groups

- `/v1/tenants`
- `/v1/users` and `/v1/devices`
- `/v1/conversations`
- `/v1/conversations/{conversation_id}/members`
- `/v1/conversations/{conversation_id}/messages`
- `/v1/sync`
- `/v1/attachments`
- `/v1/search`
- `/v1/webhooks`
- `/v1/admin/*`

## Message creation example

```http
POST /v1/conversations/{conversation_id}/messages
Idempotency-Key: device-generated-value
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "client_message_id": "01J...",
  "body": "Example message",
  "reply_to_message_id": null,
  "attachment_ids": []
}
```

A successful response includes the canonical message ID, conversation sequence, server timestamp, and normalized representation.

## Sync query

```http
GET /v1/conversations/{conversation_id}/messages?after_sequence=48291&limit=200
```

The response must make gaps, truncation, and terminal cursor state explicit.
