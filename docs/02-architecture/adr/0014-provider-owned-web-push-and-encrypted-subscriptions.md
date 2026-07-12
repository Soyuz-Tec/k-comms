# ADR-0014: Provider-owned Web Push and encrypted browser subscriptions

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, security, client, and operations
- **Related requirements:** FR-NOTIF-001, ADR-0011

## Context

Browser Web Push requires a capability-bearing endpoint, `p256dh` and `auth`
keys, a service worker, and a VAPID key pair. The existing generic notification
provider can dispatch email or push requests, but it cannot obtain browser
permission or create a `PushManager` subscription. Persisting the subscription
JSON in a notification intent, job, log, or ordinary API response would expose
credentials that authorize delivery to that browser.

## Decision

The browser requests notification permission only after an explicit user
action. It subscribes with a runtime-provided VAPID public key and registers the
result against the current authenticated device. K-Comms validates HTTPS and
bounded base64url key material, stores only an endpoint hash and hostname hint
in plaintext, and encrypts a versioned canonical subscription JSON with a
dedicated AES-256-GCM keyring. Associated data binds ciphertext to purpose, key
ID, tenant, subscription ID, and subscription version.

Notification intents and Oban arguments contain subscription ID and version,
never the endpoint or Web Push keys. The notification worker rechecks the
active human user and non-revoked device, decrypts the exact version immediately
before dispatch, and passes the destination to the generic provider only in
worker memory. Revocation, expiry, provider staleness, key rotation, and
re-registration advance or terminate the version so stale work cannot disable
or revive a newer registration.

The configured notification provider owns the VAPID private key and actual Web
Push protocol delivery. K-Comms receives only the matching public key. A direct
VAPID adapter requires a later decision and is not part of this release.

## Consequences

### Positive

- Browser permission remains user initiated and browser controlled.
- Subscription capabilities are absent from normal rows, jobs, logs, audits,
  and read APIs.
- Existing durable notification retry and provider-observability machinery is
  reused without importing provider private keys into the application.

### Negative and accepted trade-offs

- The notification provider must support the normalized Web Push destination
  contract and retain the matching VAPID private key.
- Encryption-key rotation requires retaining old key IDs until registrations
  are re-encrypted or expire.
- A device-revocation race can still allow a provider request already in flight;
  state is rechecked immediately before dispatch and all later work fails closed.

## Validation

- Fresh migration and composite tenant/user/device constraint tests.
- HTTPS, base64url key, expiry, cross-tenant, idempotency, and at-rest redaction tests.
- Capture-provider proof that only the worker receives the decrypted destination.
- Provider outage/retry, generation CAS, revocation, stale endpoint, and key-rotation tests.
- Browser permission denial, unsupported browser, module service-worker mode,
  safe same-origin click-through, and desktop/mobile Settings tests.

## Revisit triggers

- The selected provider cannot accept the normalized Web Push destination.
- Native mobile push requires APNs/FCM registration semantics beyond this browser model.
- Regulation requires provider or subscription credentials to use an external vault per row.
