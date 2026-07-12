# REST API

## Resource groups

- `/api/v1/bootstrap`, `/api/v1/sessions`, and `/api/v1/me`
- `/api/v1/users`
- `/api/v1/conversations`
- `/api/v1/conversations/{conversation_id}/members`
- `/api/v1/conversations/{conversation_id}/messages`
- `/api/v1/attachments`
- `/api/v1/search`

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
  "attachment_ids": []
}
```

The `Idempotency-Key` header is the client message identifier. A successful
response includes the canonical message ID, conversation sequence, server
timestamp, and normalized representation. Retrying the same key returns the
same canonical record and does not create another audit or outbox event.

## Sync query

```http
GET /api/v1/conversations/{conversation_id}/messages?after_sequence=48291&limit=200
```

The response includes `page.has_more`, `page.next_after_sequence`, and
`page.reset_required`, making truncation and reset boundaries explicit.
