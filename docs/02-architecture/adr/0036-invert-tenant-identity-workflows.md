# ADR-0036: Invert TenantAdministration identity workflows

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0033, ADR-0035

## Context

TenantAdministration owned invitation policy, quota policy, and tenant locking,
but `Administration` and `Administration.Invitations` called IdentityAccess
directly. `AdmissionQuotas` also counted `Accounts.User` rows. Together with
IdentityAccess calls into TenantAdministration, those references created a
compiled business-context cycle and let tenant code depend on identity
persistence.

## Decision

TenantAdministration owns three Ecto-free ports:

- `Administration.IdentityAccessPort` resolves an access grant through the
  configured `CommsCore.Accounts` implementation;
- `Administration.AuthorizationActorPort` resolves exact, verified
  authorization-denial attribution through a Tenant-owned DTO; and
- `Administration.InvitationIdentityPort` authorizes invitation acceptance,
  validates a password, checks identity availability, and enrolls an invited
  identity through the configured `CommsCore.Accounts` implementation.

Every invitation-port operation requires the caller's active repository
transaction. Invitation policy, the tenant admission lock, the invitation
mutation, identity enrollment, and audit write therefore remain atomic.
TenantAdministration passes an immutable admission policy in its enrollment
command; IdentityAccess owns the active-user count and capacity check.

`Accounts.PlatformAccess` now owns platform-grant projection logic so
`Accounts.Projector` no longer calls the `Accounts` facade.

## Consequences

- TenantAdministration no longer imports an IdentityAccess schema or facade.
- IdentityAccess remains the only owner of user persistence and active-user
  counts.
- Runtime dependencies are explicit, bound in application configuration, and
  checked against exact callers, operations, result contracts, and transaction
  policies.
- The compiled Accounts/Administration cycle is removed without moving a
  table, splitting the deployment, or weakening transactionality.
- `Administration` and `Administration.Invitations` may still form an
  owner-internal file cycle; that is separate low-level xref debt.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep direct Accounts calls | It preserves the business-context cycle and makes persistence ownership conventional. |
| Move invitation persistence to IdentityAccess | Invitations and tenant admission policy belong to TenantAdministration. |
| Use callbacks or a generic service locator | It would hide the runtime dependency and permit an unbounded operation surface. |
| Duplicate the user count in TenantAdministration | It would recreate foreign user-table ownership. |

## Validation

- `Administration.Invitations` and `AdmissionQuotas` contain no Accounts or
  User-schema reference.
- Every invitation-port operation fails closed outside a transaction or with a
  mismatched configuration binding.
- The access and authorization-actor ports reject malformed or mismatched
  provider results, including a changed request correlation id.
- Invitation acceptance, quota enforcement, identity creation, and audit
  recording pass their behavioral tests.
- The architecture validator reports no compiled
  TenantAdministration-to-IdentityAccess edge.
- `mix xref graph --format cycles --label compile-connected` reports no cycle.
