# ADR-0011: Persist integrations and fail closed for attachment safety

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, security, and operations
- **Related requirements:** FR-FILE-001, FR-NOTIF-001, FR-INT-001

## Context

The MVP has provider adapter shells and validates object size and optional
client checksum. It does not persist tenant webhook configuration or provider
attempts, and it cannot make a malware verdict. Logging an attempted delivery
or accepting an uploaded object is not production delivery or file safety.

## Decision

Persist notification intents, webhook endpoints, subscriptions, delivery
attempts, secret versions, and terminal outcomes in PostgreSQL. Dispatch them
from durable jobs/outbox events with bounded exponential retry, idempotency,
dead-letter visibility, and authorized replay. Encrypt provider credentials and
webhook secrets outside ordinary application rows where the deployment offers a
secret manager; never return an existing secret after creation or rotation.

Treat every uploaded object as quarantined until a configured scanner records a
clean verdict for the exact object version. Missing scanner configuration,
scanner errors, timeouts, and suspicious verdicts remain quarantined. Download
authorization requires both normal ownership/membership policy and a clean,
current scan verdict. Development may use an explicit deterministic test
scanner; production may not silently use it.

Outbound HTTP destinations are validated against scheme, resolved address,
redirect, port, and tenant policy to prevent server-side request forgery.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Fire-and-forget provider calls | Minimal storage | Lost delivery state and unsafe retries | Does not meet durability or support requirements |
| Mark files ready after upload integrity checks | Fast availability | Integrity is not a malware verdict | Violates FR-FILE-001 |
| Permit downloads while scanner is unavailable | Better apparent availability | Delivers unverified content | Unsafe failure mode |

## Consequences

### Positive

- Tenants and operators can inspect, retry, and reconcile external delivery.
- Attachment availability has an explicit, auditable safety invariant.

### Negative and accepted trade-offs

- Additional tables, workers, provider adapters, and cleanup jobs are required.
- Attachments may remain unavailable during scanner outages.

### Operational consequences

Provider backlog, retry age, quarantine age, failure class, and dead-letter
counts require dashboards, alerts, and runbooks.

### Security and privacy consequences

Payload logging is redacted. Webhook targets are treated as untrusted network
input. Scan verdict access is restricted and excludes file content.

## Validation

- Retry, idempotency, replay, and provider-outage integration tests.
- SSRF tests covering private addresses, DNS changes, and redirects.
- Clean, malicious, timeout, stale-verdict, and missing-scanner file tests.
- Secret creation/rotation tests proving readback and logs are redacted.

## Revisit triggers

- A provider requires a delivery semantic incompatible with the durable ledger.
- Scanning must move to an isolated account, network, or service boundary.
