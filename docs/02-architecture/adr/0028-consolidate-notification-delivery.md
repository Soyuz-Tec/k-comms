# ADR-0028: Consolidate notification delivery behind one facade

Status: Accepted

Follow-up: ADR-0032 resolves the remaining IdentityAccess-to-
NotificationDelivery edge through an IdentityAccess-owned, transaction-required
notification lifecycle port. The facade and ownership decision in this ADR
remain unchanged.

## Context

Notification preferences, durable intents, delivery attempts, in-app read state,
and browser-push subscriptions already share one table owner and one delivery
lifecycle. Separate top-level `InAppNotifications` and `PushSubscriptions`
modules made internal capabilities look like independently owned contexts and
caused adapters to consume notification Ecto schemas.

## Decision

`notification_delivery` has one public facade: `CommsCore.Notifications`.
In-app state and browser-push implementation remain owner-internal modules under
`CommsCore.Notifications`. Public reads and writes return explicit views;
delivery workers receive a claim-scoped, inspect-redacted `Delivery` command;
availability callbacks receive a content-free `Availability` signal.

The notification tables and database layout do not change. Push destination
decryption remains just-in-time, tenant- and version-scoped, and delivery
recording continues to compare both claim token and claim generation while
holding the intent lock.

## Consequences

- The former top-level satellite modules are retired and rejected by CI.
- Web and worker adapters cannot import notification persistence schemas.
- Recovery destinations and push capability material remain absent from public
  views, job arguments, audit metadata, and struct inspection.
- At acceptance, the existing IdentityAccess/NotificationDelivery synchronous
  dependency remained tracked. ADR-0032 subsequently replaces the direct calls
  with an owner-declared synchronous port because asynchronous identity events
  would weaken the existing recovery and revocation transaction semantics.

## Validation

Facade contract tests cover preferences, in-app state, push subscriptions,
delivery claims, stale claims, recovery secrecy, and HTTP compatibility. The
architecture validator checks the single facade, owner-only schemas, public
contracts, retired modules, and released-adapter schema imports.
