# Error Model

```json
{
  "error": {
    "code": "conversation.not_authorized",
    "message": "The requested operation is not permitted.",
    "request_id": "opaque-correlation-id",
    "retryable": false,
    "details": {}
  }
}
```

## Error families

- `authentication.*`
- `authorization.*`
- `validation.*`
- `rate_limit.*`
- `conflict.*`
- `not_found.*`
- `dependency.*`
- `internal.*`

Do not expose table names, stack traces, tokens, policy internals, or cross-tenant resource existence.
