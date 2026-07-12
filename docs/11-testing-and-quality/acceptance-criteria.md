# System Acceptance Criteria

## Communication-platform and staging-package gate

- Bootstrap/login, access-token validation, single-use refresh rotation, logout, and revocation tests pass.
- Tenant substitution, membership removal, and session/device mismatch tests fail closed.
- Direct/group creation, ordered idempotent send, edit/delete, reaction, read cursor, search, and replay tests pass.
- Public-channel browse/join/leave/rejoin, threads, mentions, in-app notifications, and inactive-inbox tests pass.
- Invitation, lifecycle, last-owner, role, admission-quota, account-recovery, and device/session administration tests pass.
- Moderation, retention, legal-hold, deletion, audit, and neutralized bounded CSV-export tests pass.
- Version-bound attachment upload/download, checksum, scan/quarantine, stale-intent, and deletion tests pass.
- Service-account scope/expiry/rotation/revocation and webhook/push provider safety tests pass.
- Concurrent retries create one message, audit event, outbox event, and canonical sequence.
- The user, tenant-admin, and platform-operations web surfaces pass unit,
  accessibility-oriented component, desktop/mobile browser, lint, typecheck, and
  production build checks.
- OpenAPI, AsyncAPI, JSON Schema, documentation, release, OCI, Compose, and Kustomize checks pass.
- The OCI release starts against disposable dependencies and passes bootstrap, authenticated send, replay, and readiness smoke checks.
- The staging release bootstrap is sessionless, idempotent for the same tenant identity, and fails closed for a different identity.
- Main and bootstrap Kustomizations render with HTTP bootstrap disabled and a 32 MiB ingress budget for the 25,000,000-byte application limit.
- A fresh database applies every migration, rolls back the release migration
  window, reapplies it, and passes the full warnings-as-errors suite.
- Local staging proves backup/isolated restore, migration-before-rollout,
  product acceptance, bounded load, edge and worker replacement, old-image
  rollback, current-image roll-forward, and browser journeys without data loss.

## Production gate

- Critical functional requirements have passing automated tests.
- Approved SLOs are met at expected peak plus headroom.
- Single application-node and single-zone failures preserve acknowledged messages.
- Tenant-isolation and session-revocation suites pass.
- PostgreSQL and object-storage backup restore plus regional recovery procedures are demonstrated.
- Production deployment, rollback, and return-to-current roll-forward are rehearsed from retained approved manifests.
- Critical alerts route to on-call and reference valid runbooks.
- No unresolved critical security findings remain.

Passing the communication-platform and local staging gate does not imply that
external production infrastructure or organizational launch approvals have
passed.
