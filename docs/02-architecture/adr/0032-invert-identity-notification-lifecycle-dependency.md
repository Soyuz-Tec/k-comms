# ADR-0032: Invert the identity-notification lifecycle dependency

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0018, ADR-0026, ADR-0028, ADR-0031

## Context

IdentityAccess currently enters NotificationDelivery through two synchronous
paths:

- `CommsCore.Accounts` disables browser-push subscriptions when a device or a
  user's access is revoked; and
- `CommsCore.PasswordRecovery` creates the recovery notification intent and
  disables browser-push subscriptions during access revocation.

Those calls run inside IdentityAccess-owned database transactions. Recovery
request creation, notification intent creation, notification job insertion, and
the correlated audit write must commit or roll back together. Device and
user-access revocation must not commit while an eligible push subscription
remains active.

Direct calls to `CommsCore.Notifications` preserve those invariants but create an
`identity_access -> notification_delivery` business edge. NotificationDelivery
already reads IdentityAccess state for delivery eligibility and consumes the
recovery materialization API. Some of those reverse reads still use
IdentityAccess persistence schemas and remain tracked debt. The reverse call
therefore keeps both contexts in the principal business cycle.

## Decision

IdentityAccess owns an Ecto-free notification lifecycle contract:

- `CommsCore.Accounts.NotificationCommand` describes the recovery-intent and
  push-revocation operations without exposing notification persistence;
- `CommsCore.Accounts.NotificationReceipt` returns only the stable identifier
  needed to correlate a recovery audit entry; and
- `CommsCore.Accounts.NotificationPort` defines and dispatches the
  transaction-required operation.

`CommsCore.Notifications` implements that port. The umbrella composition root
binds the implementation explicitly:

```elixir
config :comms_core,
  identity_notification_adapter: CommsCore.Notifications
```

Accounts and PasswordRecovery depend only on the IdentityAccess-owned command,
receipt, and port. They do not import, alias, pattern-match, or call the
NotificationDelivery facade or its persistence schemas.

The Notifications implementation requires an active repository transaction and
performs the existing owner-internal work on that transaction. It reuses the
existing notification intent, Oban job, and push-subscription persistence
paths. A failed port operation aborts the caller's IdentityAccess transaction.

This is synchronous dependency inversion, not asynchronous integration.
No domain event, outbox record, table, migration, deployment unit, or retry
boundary is added or changed.

## Consequences

- The aggregate `identity_access -> notification_delivery` edge is removed.
- The remaining compile direction is
  `notification_delivery -> identity_access`. The new lifecycle contribution
  uses the owner-declared port contract; pre-existing eligibility schema reads
  remain separately tracked and are not legitimized by this decision.
- Recovery request, notification intent, notification job, and audit
  correlation retain their single-transaction all-or-nothing behavior.
- Device and user-access revocation retain immediate, same-transaction push
  revocation.
- Public IdentityAccess contracts remain free of Ecto schemas and notification
  persistence details.
- `CommsCore.Notifications` remains the sole NotificationDelivery facade; the
  port implementation does not create a second notification API for general
  callers.
- Runtime indirection can hide coupling if left unconstrained. The composition
  root binding and validator regression are therefore part of the decision, not
  optional wiring.

After baseline regeneration, the expected principal SCC contains Calls,
Conversations, IdentityAccess, and TenantAdministration with 12 internal edges
and fingerprint `d900c7783f86b39a`. The expected tracked-boundary total is 102
instead of 104, with 11 rather than 13 undeclared-edge fingerprints. Those
numbers are acceptance targets, not verification claims in this ADR.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Publish an asynchronous lifecycle event through the outbox | It changes the timing and failure semantics of push revocation and separates the recovery request from its notification intent, job, and audit correlation. |
| Add a neutral workflow or shared-kernel module | It introduces a pseudo-boundary for two narrow owner interactions and obscures ownership. |
| Declare a bidirectional context dependency | It legitimizes the business cycle rather than removing it. |
| Move notification tables or logic into IdentityAccess | NotificationDelivery already has one coherent owner and facade; changing table ownership is unnecessary. |

## Validation

Completion must demonstrate all of the following:

- Accounts and PasswordRecovery contain no production dependency on
  `CommsCore.Notifications` or NotificationDelivery persistence modules.
- The composition root has exactly one explicit identity notification adapter
  binding, and the bound module implements `NotificationPort`.
- Port execution outside an active transaction fails closed.
- Adapter failure rolls back recovery creation and access revocation rather
  than committing a partial identity lifecycle change.
- Existing recovery creation, device revocation, password reset, and user
  lifecycle tests retain immediate notification behavior.
- The architecture validator reports no
  `identity_access -> notification_delivery` edge.
- Baseline regeneration removes only the two affected undeclared-edge
  fingerprints and replaces the five-context SCC fingerprint with the expected
  four-context fingerprint.
