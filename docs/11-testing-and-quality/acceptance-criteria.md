# System Acceptance Criteria

## MVP and staging-package gate

- Bootstrap/login, access-token validation, single-use refresh rotation, logout, and revocation tests pass.
- Tenant substitution, membership removal, and session/device mismatch tests fail closed.
- Direct/group creation, ordered idempotent send, edit/delete, reaction, read cursor, search, and replay tests pass.
- Concurrent retries create one message, audit event, outbox event, and canonical sequence.
- The web client passes lint, type checking, and production build checks.
- OpenAPI, AsyncAPI, JSON Schema, documentation, release, OCI, Compose, and Kustomize checks pass.
- The OCI release starts against disposable dependencies and passes bootstrap, authenticated send, replay, and readiness smoke checks.
- The staging release bootstrap is sessionless, idempotent for the same tenant identity, and fails closed for a different identity.
- Main and bootstrap Kustomizations render with HTTP bootstrap disabled and a 32 MiB ingress budget for the 25,000,000-byte application limit.

## Production gate

- Critical functional requirements have passing automated tests.
- Approved SLOs are met at expected peak plus headroom.
- Single application-node and single-zone failures preserve acknowledged messages.
- Tenant-isolation and session-revocation suites pass.
- PostgreSQL and object-storage backup restore plus regional recovery procedures are demonstrated.
- Production deployment, rollback, and return-to-current roll-forward are rehearsed from retained approved manifests.
- Critical alerts route to on-call and reference valid runbooks.
- No unresolved critical security findings remain.

Passing the MVP gate does not imply that the production gate has passed.
