# Runbook: WebSocket Saturation

- **Owner:** K-Comms realtime and platform operations
- **Alerts/triggers:** Ingress connection saturation, BEAM process/memory saturation, reconnect storm, mailbox pressure, or synthetic realtime/replay failure
- **Default severity:** Sev-2 for delayed realtime with durable replay intact; Sev-1 if acknowledged messages cannot be recovered or tenant authorization is uncertain
- **Dashboard:** `ops/dashboards/service-overview.json` plus ingress connection and node/runtime dashboards
- **Required context:** Environment, region, release revision, image digest, edge pod, connection count, reconnect rate, and durable commit/replay health

## User impact

Live message delivery, typing, presence, and connection establishment may be
slow or unavailable. Durable send/history/replay should continue when the
database is healthy, allowing clients to recover missed events after reconnect.

## Preconditions and safety warnings

- Prove durable commit and history replay before treating the incident as
  realtime-only.
- Respect PodDisruptionBudgets and failure-domain spread; never terminate all
  edge pods or bypass socket admission/rate limits.
- Do not raise connection limits, BEAM limits, or HPA bounds without verified
  ingress, node, database, and cluster headroom.
- Preserve reconnect jitter; coordinated reconnect attempts can amplify the
  outage.

## Initial diagnosis

```bash
: "${NAMESPACE:?set the production namespace}"
: "${API_ORIGIN:?set the trusted production origin}"
kubectl -n "$NAMESPACE" get deployment k-comms-edge -o wide
kubectl -n "$NAMESPACE" get hpa k-comms-edge -o wide
kubectl -n "$NAMESPACE" get pdb k-comms-edge -o wide
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=edge -o wide
kubectl -n "$NAMESPACE" top pods -l app.kubernetes.io/component=edge
curl --fail --silent --show-error "$API_ORIGIN/health/ready"
```

Correlate ingress active/new connections, rejected/upgraded connections,
reconnect rate, edge CPU/memory/process count, scheduler/mailbox pressure,
database commit latency, and pod restarts. Compare edge pods and zones to find
skew. Run one synthetic WebSocket client and confirm REST history replay.

## Stabilization actions

1. Freeze edge/ingress rollout changes and communicate realtime degradation.
2. If one pod is unhealthy, replace or drain only one instance through the
   approved disruption-budget-aware deployment procedure; verify peers before
   continuing.
3. If load is legitimate and all dependencies have approved headroom, raise
   capacity only within the reviewed HPA/cluster ceiling through change control.
4. Preserve socket admission limits and reconnect jitter. Use the approved
   ingress traffic control for abusive or accidental reconnect storms rather
   than disabling authentication.
5. If the candidate caused saturation, roll back through the retained signed
   bundle after proving schema compatibility.

## Stop conditions

Stop scaling or draining when scheduling fails, a failure domain loses its last
ready edge, database latency rises, queue/outbox age grows, replay diverges,
connection distribution worsens, or authorization differs after reconnect.
Escalate immediately for acknowledged-message loss or tenant-boundary failure.

## Escalation

Escalate to realtime and platform on-call plus ingress/network owners. Include
data operations when durable commit latency rises and security when traffic is
abusive, spoofed, cross-tenant, or bypasses admission controls. Incident command
owns capacity overrides, traffic policy, and rollback.

## Recovery validation

1. Verify edge deployment/HPA/PDB health, zone distribution, peer discovery,
   process/memory headroom, and no unexpected restarts.
2. Run the approved reconnect-storm scenario at target concurrency and jitter.
3. Prove each synthetic client receives live messages and reconciles missed
   events through ordered REST history without loss or duplicates.
4. Confirm durable commit latency, queue/outbox age, ingress errors, and
   connection admission return to approved thresholds for the stability window.
5. Verify an unauthorized or revoked session cannot reconnect or replay data.

## Rollback and removal of temporary controls

Return temporary HPA, node, ingress, and traffic controls to the reviewed
bundle. Remove capacity overrides only after normal peak plus headroom passes.
Retain rollout/rollback and reconnect evidence; do not make an emergency limit
the undocumented new baseline.

## Evidence to capture

- release/environment identity, edge/zone topology, HPA/PDB state, connection
  and reconnect rates, process/memory/CPU, ingress errors, and pod events;
- durable commit, replay, queue/outbox, synthetic, and authorization results;
- every capacity/traffic/rollout action, approval, limit, stop condition, and
  observed effect; and
- achieved recovery time and headroom without session tokens, tenant content,
  or raw user identifiers.

## Follow-up

Update the capacity model, reconnect/load scenarios, HPA/ingress thresholds,
alert coverage, and this runbook. Exercise zone loss plus reconnect storm in the
target topology before re-approving the performance/resilience readiness gate.
