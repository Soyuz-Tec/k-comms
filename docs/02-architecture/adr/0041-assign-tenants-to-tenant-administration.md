# ADR-0041: Assign tenants to TenantAdministration

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0032, ADR-0035, ADR-0036

## Context

The manifest assigned `tenants` to TenantAdministration while the only Ecto
schema was still named `CommsCore.Accounts.Tenant`. IdentityAccess schemas
associated directly with it, and Accounts, ServiceAccounts, and password
recovery queried tenant persistence. The public PasswordRecovery facade also
contained IdentityAccess persistence and notification-port implementation.

This made table ownership truthful only in documentation and left tenant
persistence compiled through IdentityAccess.

## Decision

`CommsCore.Administration.Tenant` is the only schema for `tenants`.
`CommsCore.Accounts.Tenant` is removed without a compatibility module.
IdentityAccess schemas keep tenant identity as scalar UUID fields; existing
database foreign keys remain unchanged.

TenantAdministration publishes `active_tenant/1` and
`active_tenant_by_slug/1`. Both return an Ecto-free `TenantView`, and malformed,
missing, suspended, or deleting tenants all fail closed as
`{:error, :tenant_unavailable}`. Accounts, ServiceAccounts, and recovery use
those owner queries rather than tenant persistence.

`CommsCore.PasswordRecovery` remains the released facade. IdentityAccess
persistence, audit, and notification orchestration move to the internal
`CommsCore.Accounts.PasswordRecovery`; the facade contributes the existing
Calls revocation callback to the reset transaction. The declared notification
port caller is therefore the internal owner implementation, not the adapter
facade. Successful resets return the Ecto-free `PasswordRecoveryResult`
contract containing revoked session IDs; neither the User schema nor a generic
map crosses the public facade.

Calls and the transitional Authorization database policy are outside this
tranche. Their references are mechanically redirected to the new canonical
Tenant schema with no behavior change. The four schema fingerprints and one
edge fingerprint are exact replacements of existing Calls/authorization
deferrals and remain separately mapped to the Calls removal conditions.

## Consequences

- The `tenants` table has one declared owner and one canonical schema.
- IdentityAccess no longer imports TenantAdministration persistence.
- Password-recovery persistence remains internal while web and worker adapters
  retain the stable public facade.
- No table, migration, deployment unit, or database behavior changes.
- The reviewed baseline changes from 46 to 32 findings: nineteen old
  fingerprints are removed, five mechanical Calls/authorization replacements
  are added, and no unrelated debt is admitted.

## Validation

- Schema discovery finds exactly one `tenants` mapping and no compatibility
  schema.
- IdentityAccess schema tests require scalar tenant IDs and no Tenant schema
  imports.
- Tenant owner tests cover active projections and uniform fail-closed results.
- Password-recovery tests protect the public/internal split, equalized request
  path, typed result, notification transaction, and Calls rollback behavior.
- Architecture tests require the exact notification-port caller and the exact
  reviewed baseline transition.
