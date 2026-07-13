# ADR-0020: Require expiring platform-role grants

- **Status:** Accepted
- **Date:** 2026-07-13
- **Owners:** Identity, security, and platform
- **Related requirements:** FR-OPS-001, NFR-SEC-001

## Context

Platform operations are intentionally separate from tenant administration, but
the original nullable role on `users` remained valid until a manual revoke.
That made an abandoned grant a durable privilege and did not satisfy the
approval-and-expiry boundary in ADR-0012. A regrant of the same role also must
not revive an established WebSocket subject minted for an earlier approval.

## Decision

Platform authority is an explicit row in `platform_role_grants`, keyed one to
one to a human user and containing a random per-approval identifier, the role,
and exact UTC expiry. Console grants require an active human target and a TTL
from 300 through 28,800 seconds. Every grant or renewal replaces the prior row
with a fresh random identifier; revocation deletes the grant and remains
available for inactive or non-human identities so unsafe residual state can be
removed. Grant, revoke, user-version increment, and reason-bearing audit
evidence commit in one database transaction.

HTTP and socket-ticket subjects carry the approval identifier, effective role,
and exact expiry. The approval identifier is internal authorization state and
is not exposed in public user or session JSON.
Every platform authorization re-reads the grant, requires it to be unexpired,
and requires all three subject values to match the persisted grant. Expiry
therefore takes effect on the next authorization check, and renewing the same
role cannot authorize a subject from an earlier grant even if the role and
deadline happen to be identical.

The original `users.platform_role` column is retained as an always-null
rollback-compatibility field and constrained accordingly. A previous binary
therefore sees no platform operators and its legacy grant command fails closed
after this migration. Existing roles receive one bounded eight-hour transition
grant during migration. The local-proof bootstrap convenience also issues only
bounded grants and remains prohibited in production.

## Consequences

- Platform access requires deliberate renewal at least once per eight-hour
  shift and cannot silently become permanent.
- Operator clocks and PostgreSQL time must be synchronized and monitored.
- Expired rows may remain as non-authorizing state until renewal or revoke;
  audit events remain the durable history.
- Rolling back application code keeps platform access unavailable. Operators
  must roll forward before issuing another grant.

## Alternatives considered

- **Keep a permanent role and rely on reviews:** rejected because review does
  not fail closed when a revoke is missed.
- **Store role and expiry together on `users`:** rejected because an older
  binary ignores the new expiry and could revive an expired privilege after an
  application rollback.
- **Encode expiry only in access tokens:** rejected because established
  sessions and sockets require current authoritative revocation state.

## Validation

- Fresh migration plus grant and legacy-column constraint validation.
- Exact TTL boundary, expiry-equality, revoke, audit, and exact-deadline tests.
- HTTP and established-subject denial after expiry or same-role renewal,
  including an intentionally reproduced role/deadline collision.
- Kustomize validation of the short-lived operation Secret and Job.
