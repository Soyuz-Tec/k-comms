# Runbook: Durable Queue or Outbox Backlog

- **Owner:** K-Comms workers and owning capability team
- **Alerts/triggers:** `KCommsObanQueueBacklog`, `KCommsDiscardedJobs`, `KCommsOutboxBacklog`, or `KCommsProviderDeliveryFailures`
- **Default severity:** Sev-2 when user-visible commitments are threatened; Sev-1 for unreplayable acknowledged work or unsafe duplicate side effects
- **Dashboard:** `ops/dashboards/service-overview.json`
- **Required context:** Environment, release revision, image digest, oldest-job age, queue/capability, and provider state

## User impact

Durable messages remain authoritative, but realtime publication, notifications,
webhooks, attachment scanning, retention, deletion, search, or exports may be
delayed. Discarded work may require reconciliation. Delay does not authorize
skipping ordering, tenancy, idempotency, or safety controls.

## Preconditions and safety warnings

- Identify the queue, worker type, oldest job, retry state, and downstream
  dependency before changing capacity or replaying work.
- Never delete outbox/job rows, bulk retry discarded work, or edit job arguments
  directly.
- Prove provider acceptance/idempotency and tenant scope before replaying an
  external side effect.
- Assign the owning capability for attachment, notification, webhook,
  retention, deletion, or export work.

## Initial diagnosis

```bash
: "${NAMESPACE:?set the production namespace}"
: "${API_ORIGIN:?set the trusted production origin}"
: "${METRICS_BEARER_TOKEN:?load through the approved secret channel}"
kubectl -n "$NAMESPACE" get deployment k-comms-worker -o wide
kubectl -n "$NAMESPACE" get hpa k-comms-worker -o wide
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=worker -o wide
curl --fail --silent --show-error \
  --header "authorization: Bearer $METRICS_BEARER_TOKEN" \
  "$API_ORIGIN/metrics" \
  | grep -E '^k_comms_(oban_queue_age_seconds|oban_jobs_pending|oban_jobs_discarded|outbox_pending|notification_failures|webhook_failures) '
```

Use content-blind `/ops` views and redacted logs to determine queue, error class,
attempt count, scheduled time, provider status, database saturation, worker
resource pressure, recent deployment, and whether backlog is growing or
draining. Do not inspect message bodies or provider secrets.

## Stabilization actions

1. Freeze worker/provider rollout changes and nonessential bulk jobs.
2. If workers are unhealthy, restore the reviewed deployment and readiness
   before changing capacity.
3. If work is capacity-bound and the provider/database has approved headroom,
   adjust only the reviewed HPA/capacity control through the change pipeline.
4. If a provider is failing, preserve retry state and wait or apply the
   documented provider recovery; do not create a retry storm.
5. Replay a discarded item only through an approved idempotent capability
   action after verifying source state, endpoint/object version, recipient,
   and prior provider acceptance.
6. Prioritize by user safety and SLO, not by direct row mutation.

## Stop conditions

Stop capacity increase or replay when database/provider saturation rises,
backlog age grows faster, duplicate effects appear, ordering changes, tenant
scope is uncertain, the job payload/release is incompatible, or an attachment
version/safety verdict cannot be proved. Escalate acknowledged-message replay
failure as Sev-1.

## Escalation

Escalate to workers plus the owning capability team. Include platform/data for
database or resource saturation and the provider owner for external failures.
Page security/privacy for cross-tenant work, credential/endpoint anomalies,
unsafe attachment processing, or unauthorized delivery. Incident command owns
bulk replay and rollout rollback decisions.

## Recovery validation

1. Require oldest-job age, pending jobs, outbox, and failure gauges to trend
   down through the approved observation window.
2. Confirm no new discarded jobs or duplicate provider effects.
3. Run synthetic send/live-delivery/replay and the affected capability journey:
   notification, signed webhook, clean attachment scan, search, or export.
4. Reconcile durable intents against terminal outcomes without content access.
5. Verify worker readiness, database/provider headroom, alert recovery, and the
   deployed immutable release.

## Rollback and removal of temporary controls

Return HPA limits, paused schedules, provider routing, and rollout controls to
the retained reviewed configuration. Remove temporary replay authority after
reconciliation and record every replayed identifier in the restricted audit
evidence. Do not clear discarded counters by deleting authoritative history.

## Evidence to capture

- alert values, queue/capability, oldest age, counts by safe terminal state,
  release/environment identity, and workload/HPA state;
- redacted error classes, provider incident, capacity changes, approval, start
  and completion times, and stop conditions evaluated;
- replay/reconciliation identifiers and outcomes without payload content,
  endpoint secrets, signed URLs, or raw user identifiers; and
- post-recovery synthetic results and stability-window metrics.

## Follow-up

Correct the underlying code, provider, capacity, retry, or alert defect. Review
job timeout/backoff/dead-letter policy, update capacity forecasts and this
runbook, and rehearse the scenario. Attach retained evidence to the matching
readiness gate; never mark the repository template passed.
