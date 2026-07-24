# ADR-0048: Make abandoned upload cleanup durable and convergent

- **Status:** Accepted
- **Date:** 2026-07-24
- **Owners:** Conversation Content, Attachment Safety, Platform Operations, and Security
- **Related decisions:** ADR-0005, ADR-0011, ADR-0027

## Context

An attachment intent authorizes one client to upload to a unique object key
through an expiring signed request. A browser can cancel, disconnect, or fail
after the intent is created but before the upload is attached to a message.
Deleting the key immediately is insufficient: an already issued signed request
can be replayed until its expiry, and a versioned bucket can retain older object
versions or delete markers even when the current object appears absent.

Cleanup must therefore survive browser, web-node, worker, and object-provider
failures. It must also preserve tenant and attachment authorization boundaries,
avoid logging signed URLs, and converge without requiring a direct database
repair.

## Decision

The Conversation Content boundary owns the cleanup lifecycle in the existing
PostgreSQL repository. It persists the upload authorization expiry, cleanup
state, attempt count, next-attempt time, claim time, last bounded error, and
completion time on the attachment intent.

The lifecycle is:

1. The object-storage signer returns the absolute expiry used in its signature.
   The application persists that expiry before returning the authorization to
   the client.
2. If signing or expiry persistence fails, the application compensates by
   scheduling the intent for cleanup.
3. A user cancellation is owner- and tenant-scoped and idempotently schedules
   cleanup after the signed request expires plus a configured grace period.
   The client retains the intent identifier until this request is accepted and
   surfaces a final retry failure instead of silently replacing the intent.
4. An Oban reconciliation job periodically finds stale pending intents and
   incomplete or abandoned cleanup claims. It enqueues bounded, tenant-aware
   work transactionally.
5. A cleanup worker must receive both tenant and attachment identifiers. It
   claims the row through the Conversation Content facade, then instructs the
   object-storage port to enumerate and delete every version and delete marker
   for the exact unique key. Completion is recorded only after the provider
   verifies that no matching version remains.
6. Provider or verification failures remain observable as retryable or failed
   durable state. Reconciliation can re-enqueue terminal Oban attempts, so an
   exhausted job does not make the cleanup lifecycle terminal.

The public boundary exposes only opaque cleanup targets. Provider credentials,
signed URLs, bucket internals, and direct schema access remain outside the
facade. The failed-cleanup count is exported through the operations snapshot
and Prometheus metrics.

Bucket versioning is required. Provider credentials used by the cleanup worker
must be able to list bucket versions and delete specific object versions and
delete markers for the configured attachment prefix. A provider lifecycle rule
may be used as a reviewed defense in depth only when it cannot remove retained,
quarantined, or legally held attachment versions; it is not a substitute for
application reconciliation.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Delete the current object immediately when the user cancels | Small implementation | Signed-request replay and noncurrent versions survive | Does not converge for a versioned bucket |
| Let the browser retry cleanup best-effort | No scheduled worker | Browser closure, offline clients, and swallowed failures leak objects | The authoritative lifecycle must be server-side |
| Store cleanup state only in Oban arguments | Reuses the job system | Exhausted or lost jobs obscure attachment state and authorization | The owning domain needs an auditable state machine |
| Run a bucket-wide destructive sweep | Finds legacy objects | Weak tenant attribution and high deletion blast radius | Cleanup must be scoped to an authorized unique key |
| Globally expire all noncurrent versions | Simple provider backstop | Can destroy quarantined, retained, or legally held evidence | Lifecycle policy must respect attachment retention semantics |

## Consequences

### Positive

- Cleanup survives process restarts and exhausted worker attempts.
- Replay after cancellation is bounded by the exact authorization expiry and
  grace period.
- Every object version and delete marker under the authorized unique key is
  deleted and absence is verified before completion.
- Tenant authorization, failure counts, and retry state are inspectable without
  exposing object-provider secrets.
- The design stays within the modular monolith: one owning context, one
  repository, a small facade, and infrastructure behind a port.

### Negative and accepted trade-offs

- Abandoned objects remain intentionally present until authorization expiry and
  grace have elapsed.
- Version enumeration needs additional provider permissions and requests.
- Provider outages can leave rows in retryable or failed state until
  reconciliation succeeds.
- Exact-key cleanup depends on the invariant that each attachment intent owns a
  unique object key.

### Operational consequences

- Alert when `k_comms_attachment_cleanup_failures` is non-zero or rising.
- Preserve the periodic reconciler and cleanup queue in every environment that
  permits attachment uploads.
- Investigate failed rows through supported operations surfaces and logs using
  opaque attachment/correlation identifiers; never copy signed URLs into
  tickets or logs.
- Validate version-list and version-delete permissions during deployment and
  credential rotation.

## Validation

- Migration and schema constraints cover all cleanup states and due-work
  indexes.
- Core tests cover authorization expiry, idempotent abandonment, tenant/owner
  isolation, claims, retries, completion, and reconciliation.
- Integration tests cover safe version-list parsing, multiple versions and
  delete markers, exact-key deletion, empty verification, and idempotent purge.
- Worker tests cover the tenant envelope, pre-expiry deferral, verified
  completion, persisted failures, and reconciliation.
- Controller and client tests cover presign compensation, retained cancellation
  intent, surfaced final failure, and replacement blocking.
- Architecture validation confirms the cleanup contract remains inside the
  Conversation Content boundary and object storage remains behind its port.

## Revisit triggers

- The object-storage provider changes version-listing or batch-delete semantics.
- Multipart or resumable upload support permits a transfer to finish beyond the
  configured grace period.
- Attachment retention, legal hold, or quarantine policies add provider
  lifecycle constraints.
- Cleanup volume requires a separate bounded partitioning or rate-control
  strategy.
