# ADR-0109: Retain current authority for audit CSV disclosure

- **Status:** Accepted
- **Date:** 2026-10-05
- **Owners:** Architecture, TenantAdministration, IdentityAccess, Security
- **Related decisions:** ADR-0027, ADR-0035, ADR-0075, ADR-0082

## Context

Audit CSV contains private tenant evidence. A current authorization check before
an export transaction cannot authorize disclosure after an owner lock, audit
write, or serialization wait. The initiating session, persisted role and recent
step-up proof must remain valid when plaintext leaves the Core facade. A second
session for the same user cannot substitute for that initiating session.

## Decision

TenantAdministration extends its existing configured `IdentityAccessPort` with
exactly `lock_access/2`, implemented by the existing Accounts adapter and
returning the existing persistence-neutral `IdentityGrant`. This operation
requires a caller transaction and a caller-supplied absolute monotonic deadline.
It retains the canonical tenant admission fence, active tenant, user, device and
exact initiating session in that order, and requires an active human with
workspace scope. IdentityAccess owns every canonical identity query and lock.
There is no AuditExport dependency on Accounts, new dependency allowance,
validation exemption, configuration binding or persistence DTO.

The same port's `resolve_access/1` remains an independent read with its existing
semantics. The single collaboration descriptor remains `independent` to describe
that existing read; its condition states the transaction requirement specific
to `lock_access/2`. The descriptor's exact callbacks and callers, source guard,
negative outside-transaction regression and this decision express the mixed
operation semantics without claiming that the entire port requires a transaction.

AuditExport creates one 15-second absolute read deadline before preflight. A
bounded preflight transaction preserves existing authorization-denial audit
behavior. The export transaction then retains canonical identity authority
before reading audit evidence, preserves the existing audit permission roles
and current persisted step-up policy, and rechecks that same initiating authority
after its read-audit insert and CSV encoding, immediately before returning
plaintext. Every SQL wait and transaction checkout consumes the remaining same
deadline. Failure rolls back the successful export audit and returns the existing
error envelope, with no CSV. Filters, tenant isolation, 5,000-row maximum, CSV
formula neutralization and successful read-audit metadata remain unchanged.

The exact existing POST route has a private response-header pipeline before the
unchanged authenticated API pipeline. It sets `Cache-Control: no-store` and
`Pragma: no-cache` before authentication, acceptance and rate-limit checks as well
as the action and fallback response, including successful CSV, missing step-up,
persisted role denial and malformed input. Other routes and all authentication
and rate-limit rules remain unchanged.

## Verification and scope

Committed synthetic fixtures and independent PostgreSQL connections prove
actual owner-lock waits, initiating-session revocation despite a valid second
session, persisted role and workspace-scope withdrawal, and session/step-up
expiry during a real audit INSERT wait. No successful export audit may survive
those refusals. HTTP tests retain CSV and error goals while checking no-store.
The exact immutable-parent manifest transition and public operation inventory
bind only this owned extension; the boundary baseline and validator remain
unchanged. Both compiled and complete Core dependency graphs must remain acyclic.

This correction introduces no database schema, provider, worker, release
capability or new rollback inventory. Local synthetic qualification does not
establish protected CI, staging or production qualification.
