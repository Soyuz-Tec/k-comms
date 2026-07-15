# Runbook: Service Degradation

- **Owner:** K-Comms application and platform operations
- **Alerts/triggers:** `KCommsHighMessageCommitLatency`, `KCommsAuthenticationFailureRatio`, synthetic journey failure, or broad elevated error rate
- **Default severity:** Sev-2 for bounded degradation; Sev-1 for platform-wide outage, acknowledged-message loss, tenant-isolation risk, or active secret exposure
- **Dashboard:** `ops/dashboards/service-overview.json` plus ingress, database, and runtime dashboards
- **Required context:** Environment, region, release revision, image digest, deployment start, affected capability, and tenant scope

## User impact

Users may experience slow or failed sign-in, send, replay, search,
administration, attachment, or provider workflows. Durable state and
authorization remain authoritative; client errors or live-delivery success do
not justify bypassing persistence, session, or tenant controls.

## Preconditions and safety warnings

- Assign incident command for broad or Sev-1/Sev-2 impact and freeze rollout
  expansion while the cause is unknown.
- Confirm the deployed immutable release and retained rollback bundle before
  changing traffic or workloads.
- Never weaken authentication, recent-step-up, rate limits, tenant checks,
  network policy, TLS, readiness, or auditability to recover availability.
- Separate provider degradation from application, database, ingress, and
  client failures before choosing mitigation.

## Initial diagnosis

```bash
: "${NAMESPACE:?set the production namespace}"
: "${API_ORIGIN:?set the trusted production origin}"
kubectl -n "$NAMESPACE" get deployment k-comms-edge k-comms-worker -o wide
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=k-comms -o wide
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=30s
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=30s
curl --fail --silent --show-error "$API_ORIGIN/health/live"
curl --fail --silent --show-error "$API_ORIGIN/health/ready"
```

Compare the incident start with deploy/config/secret/provider/certificate
events. Use the dashboard to separate authentication ratio, durable commit
latency, queue/outbox age, attachment/provider failures, process count, and
memory. Establish scope with synthetic accounts; do not sample user content.

## Stabilization actions

1. Pause canary/rollout expansion and preserve the current evidence snapshot.
2. If degradation correlates with the candidate and retained schema is
   compatible, use the approved release pipeline to roll back to the retained
   signed digest. Do not mutate images directly with an ad hoc command.
3. If a dependency is degraded, keep unaffected capabilities available and
   allow built-in fail-closed behavior; use only approved traffic or provider
   controls.
4. If one pod is unhealthy, let disruption-budget-aware rollout replacement
   handle one instance at a time and verify cluster reconvergence.
5. Keep clients on normal idempotent retry/replay behavior; do not ask users to
   resend acknowledged messages blindly.

## Stop conditions

Stop mitigation and escalate when release identity is unknown, rollback schema
compatibility is unproved, readiness worsens, two failure domains would be
removed, acknowledgements cannot be replayed, authorization differs, tenant
scope expands, or a security/privacy condition appears. Stop rollout entirely
on the conditions listed in the internal-production readiness policy.

## Escalation

Escalate to application and platform on-call, then the owning identity,
messaging, attachment, or integration team. Include data/provider owners for
dependency failure. Page security/privacy immediately for isolation,
credential, audit, or unauthorized-access concerns. Incident command owns
rollback, traffic, and communications decisions.

## Recovery validation

1. Confirm the exact release/image, deployment convergence, zero unexpected
   restarts, readiness, and dependency health.
2. Run synthetic sign-in, token refresh, recent step-up, idempotent send, live
   delivery, disconnected replay, search, and affected provider/attachment
   journeys.
3. Reconcile acknowledged messages, queue/outbox movement, provider outcomes,
   and alert recovery.
4. Require latency/error/authentication ratios within approved thresholds for
   the stability window.
5. Confirm support sees the same content-blind status and no temporary control
   remains hidden.

## Rollback and removal of temporary controls

If rollback was used, retain both manifests, signed digests, timestamps,
migration compatibility evidence, and post-rollback synthetics. Restore traffic,
HPA, feature, and provider controls through reviewed configuration only after
the stability window. Schedule roll-forward as a separate reviewed change.

## Evidence to capture

- incident/release/environment identity, affected capability and scope,
  dashboard snapshots, alerts, synthetics, workload state, and dependency
  incidents;
- every change, approver, start/end time, expected result, stop condition, and
  observed result;
- rollback/roll-forward bundle and image digests plus migration state; and
- content-blind reconciliation and error-budget impact, excluding credentials,
  message content, and raw user identifiers.

## Follow-up

Complete the problem review, track corrective work, replenish the error budget,
and update alerts, dashboards, tests, capacity, and this runbook. Rehearse the
fixed path before the responsible readiness gate can be re-approved.
