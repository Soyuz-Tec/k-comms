# System Acceptance Criteria

## MVP and staging-package gate

- Bootstrap/login, access-token validation, single-use refresh rotation, logout, and revocation tests pass.
- Tenant substitution, membership removal, and session/device mismatch tests fail closed.
- Direct/group creation, ordered idempotent send, edit/delete, reaction, read cursor, search, and replay tests pass.
- Concurrent retries create one message, audit event, outbox event, and canonical sequence.
- The web client passes lint, type checking, and production build checks.
- OpenAPI, AsyncAPI, JSON Schema, documentation, release, OCI, Compose, and Kustomize checks pass.
- The OCI release starts against disposable dependencies and passes bootstrap, authenticated send, replay, and readiness smoke checks.

## Production gate

- Critical functional requirements have passing automated tests.
- Approved SLOs are met at expected peak plus headroom.
- Single application-node and single-zone failures preserve acknowledged messages.
- Tenant-isolation and session-revocation suites pass.
- Backup restore and regional recovery procedures are demonstrated.
- Production deployment and rollback are rehearsed.
- Critical alerts route to on-call and reference valid runbooks.
- No unresolved critical security findings remain.

Passing the MVP gate does not imply that the production gate has passed.
