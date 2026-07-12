# API Guidelines

## Principles

- Contracts are versioned, schema-defined, and backward compatible within a major version.
- Commands accept stable idempotency keys where retries are expected.
- Resource identifiers are opaque and globally unique.
- Tenant and actor context come from authenticated authorization, not untrusted body fields.
- Errors use stable machine codes plus safe human-readable detail.
- Pagination uses opaque cursors rather than page numbers for mutable collections.
- Rate-limit responses expose a stable error code and retry guidance.

## Compatibility

Safe changes are additive: optional fields, new event types, and new enum values only when consumers tolerate unknown values. Renames, semantic changes, and required fields require a new contract version or migration protocol.
