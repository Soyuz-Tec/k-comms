# Runbook: Service Degradation

- **Owner:** K-Comms application and platform operations
- **Alerts/triggers:** `KCommsHighMessageCommitLatency`, `KCommsAuthenticationFailureRatio`, synthetic journey failure, audio/video provider or TURN degradation, or broad elevated error rate
- **Default severity:** Sev-2 for bounded degradation; Sev-1 for platform-wide outage, acknowledged-message loss, tenant-isolation risk, or active secret exposure
- **Dashboard:** `ops/dashboards/service-overview.json` plus ingress, database, and runtime dashboards
- **Required context:** Environment, region, release revision, image digest, deployment start, affected capability, and tenant scope

## User impact

Users may experience slow or failed sign-in, send, replay, search,
administration, attachment, or provider workflows. Durable state and
authorization remain authoritative; client errors or live-delivery success do
not justify bypassing persistence, session, or tenant controls.
Media-provider failure may prevent joining, publishing, subscribing, or
reconnecting while durable text messaging remains healthy. Do not mark the
whole service unready solely because media is unavailable.

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

### Audio/video media-specific diagnosis

Confirm AUDIO_PROVIDER_MODE is livekit, LIVEKIT_SERVER_URL is the reviewed WSS
browser origin, LIVEKIT_API_URL is the reviewed backend HTTPS origin,
AUDIO_TOKEN_TTL_SECONDS is 60-300, and
AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS is 660-1,800 and not shorter
than the token lifetime. Confirm the response CSP contains only the exact WSS
origin. Never print or inspect LIVEKIT_API_SECRET during diagnosis. Separate
signaling/TLS failure, browser camera/microphone/screen permission, capture
device failure, decode/render or bandwidth pressure, SFU/group capacity,
direct UDP media, TURN relay failure, participant-eviction backlog, and overdue
`CommsWorkers.AudioCallExpiryWorker` jobs on the `media` queue.

An authoritative logout, revocation, suspension, membership removal, archive,
or applicable tenant audio/video disable must commit even while LiveKit is unavailable. Inspect
only aggregate `media` queue state, pending/enforcing eviction counts, oldest
attempt age, and provider error class. Do not query, copy, or log JWTs, room
names, opaque provider identities, or raw user identifiers. A durable admitted
participant identity is expected; a persisted participant token is a Sev-1
secret-handling defect.
Use synthetic callers and non-sensitive test patterns only; do not join a user
room, capture personal screens, or record audio/video. Verify the selected
provider's content-blind health, participant/room capacity, join failures,
reconnects, packet loss, jitter/RTT, bitrate/resolution/frame rate, CPU and
bandwidth limitation, TURN allocations, and certificate state from approved
dashboards.

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
6. For media-only failure, keep text messaging available and fail affected call
   media closed with an explicit unavailable state. Do not extend token lifetime, expose
   provider credentials, disable membership checks, open TURN relay access, or
   bypass WSS/TLS to restore a call.
7. Restore the media queue and provider path so
   `CommsWorkers.AudioParticipantEvictionWorker` can resume durable idempotent
   removal. Do not reactivate a revoked admission, cancel its retries, or make
   the access change wait for provider recovery.
   `CommsWorkers.AudioCallExpiryWorker` must also resume provider-room deletion
   for overdue calls; do not manually mark a call ended while its room remains.
8. If policy requires an immediate hard stop and the composed provider has no
   separately implemented, qualified LiveKit Cloud token-revocation path,
   authorized whole-room deletion is the only immediate fallback. It
   disconnects every participant; record incident command and user-impact
   approval before using it.

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
6. Use synthetic browser identities to prove bidirectional audio and camera
   video, default-off capture, mute/camera toggles, leave/rejoin, forced TURN,
   UDP-blocked fallback, and provider interruption/recovery. Use at least three
   identities to prove the group grid and screen-share publication,
   subscription, native track end, and cleanup. Remove one caller's membership
   and revoke another session during active calls; both must lose media access without affecting
   durable text readiness. During a simulated provider outage, verify each
   access change commits, new joins fail immediately, eviction remains durable,
   and retry recovery removes the exact synthetic participant. Failures must
   remain queued beyond the minimum enforcement horizon.
7. Attempt cached-token reconnect only with synthetic credentials. For the
   self-hosted path, prove repeated eviction prevents continued access through
   the configured minimum enforcement horizon and that a removal succeeds at
   or after it; record the measured access-change-to-disconnect latency. Do not
   describe this as instantaneous token revocation. If a LiveKit Cloud
   revocation path is selected, qualify it separately; the portable adapter
   does not implement that behavior.
8. For expiry recovery, use an approved non-production due-call fixture or
   clock-controlled test. Prove the creation transaction contains one unique
   job at `expires_at`, provider deletion failure remains retryable, eventual
   success emits one normal ended transition and admission-eviction work, and
   an already-ended or superseded-call job is a no-op. Never change production
   call deadlines directly for this test.

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
  message content, and raw user identifiers; and
- for audio/video incidents, WSS/TLS certificate identity, TURN transport used,
  media kind, aggregate join/reconnect/quality/group-capacity results,
  participant-revocation
  trigger and commit time, eviction attempt/recovery counts, minimum
  enforcement-horizon value, measured disconnect latency, cached-token replay result, and provider
  incident identifiers without room names, tokens, user audio/video/screen
  content, or raw participant identities.

## Follow-up

Complete the problem review, track corrective work, replenish the error budget,
and update alerts, dashboards, tests, capacity, and this runbook. Rehearse the
fixed path before the responsible readiness gate can be re-approved.
