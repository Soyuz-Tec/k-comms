# Internal Production Readiness

## Decision boundary

K-Comms is an application candidate for a controlled internal rollout. A green
repository and local three-node staging qualification prove the application
bundle; they do not prove that the organization has supplied production state,
providers, identities, support coverage, or representative-user acceptance.

The release decision has three independent gates:

1. **Application gate** — exact revision, image digest, automated suites,
   migration, backup/restore, rollout, rollback/roll-forward, bounded load,
   failure replacement, and browser journeys.
2. **Environment and operating gate** — approved infrastructure, providers,
   secrets, identity policy, alert routes, recovery evidence, ownership, and
   support/on-call staffing.
3. **People gate** — the accessibility, task-success, SUS, and two-week pilot
   contract in
   [usability-validation.md](../11-testing-and-quality/usability-validation.md).

All three gates must identify the same immutable release before internal teams
may treat the service as production.

## Machine-verifiable readiness ledger

The repository maintains a complete pending ledger template at
[`internal-production-readiness-ledger.template.json`](internal-production-readiness-ledger.template.json)
and its JSON Schema at
[`internal-production-readiness-ledger.schema.json`](internal-production-readiness-ledger.schema.json).
The template deliberately has `template: true`, null release identity, pending
gates/signoffs, and `production_ready: false`. It is planning material, never a
claim that any external or human gate passed.

For a real release, copy the template into the restricted evidence store, set
`template` to `false`, and bind it to the exact Git revision, signed image
digest, reviewed production-bundle SHA-256, and stable environment ID. A passed
gate needs a role owner, separate approver, assessment time, future review/expiry
time, and query-free URI to retained evidence. Do not place credentials,
personal participant data, message content, or signed URLs in the ledger.
The release decision must be recorded at or after every passed gate assessment
and required sign-off, and the ledger generation time must be at or after that
decision.

Validate the pending template or a release ledger with:

```bash
python scripts/validate_readiness_ledger.py \
  docs/13-delivery-plan/internal-production-readiness-ledger.template.json
python scripts/validate_readiness_ledger.py /restricted/evidence/readiness-ledger.json
```

The validator checks exact gate/signoff coverage, owner/approver separation,
immutable identity formats, evidence metadata, expiry, approval chronology,
and decision consistency. It does not inspect the underlying evidence or
create an approval. `production_ready: true` is valid only when every gate and
required signoff is passed, non-expired, and the release authority has recorded
a non-expired approved decision.

## Application gate

| Control | Required evidence | Status before candidate qualification |
|---|---|---|
| Code quality | Formatting, lint, typecheck, unit/integration, contracts, docs, architecture and production build | Re-run for candidate |
| Security | Sobelow, dependency audit, boundary suites, no unresolved critical finding | Re-run/review for candidate |
| Browser usability | Desktop/mobile journeys and axe representative-state suite | Re-run for candidate |
| Delivery correctness | Authenticated send, replay, reconnect, search, attachment and administration journeys | Re-run for candidate |
| Audio/video authorization, media, and eviction | Two-party bidirectional audio/video RTP; three-or-more participant group grid; explicit default-off capture; screen-share publish/subscribe/cleanup; source-restricted grants; persisted admission without JWT; access-change commit during outage; blocked join; durable retry beyond the minimum horizon and successful removal at or after it | Re-run for candidate |
| Data change | Fresh migration, rollback window, reapply and warnings-as-errors tests | Re-run for candidate |
| Runtime resilience | Two edge replicas, worker, readiness, pod replacement and no acknowledged-message loss | Re-run for candidate |
| Recovery | PostgreSQL and object-storage backup plus isolated restore | Re-run for candidate |
| Release safety | Retained manifest, immutable digest, rollback and roll-forward | Re-run for candidate |

Historical evidence is useful for regression context but never promotes a newer
revision. Store the exact-candidate receipt with the release bundle.

## Environment and operating gate

Each row needs a named owner, approver, date, evidence link, and expiry/review
date. An unchecked or expired row blocks production use.

- [ ] Approved infrastructure composition is provisioned from reviewed code.
- [ ] Managed PostgreSQL has encryption, hostname-verified TLS, point-in-time
  recovery, monitored capacity, and a successful restore drill.
- [ ] Durable object storage has versioning/lifecycle policy, encryption,
  restricted credentials, and a successful restore/reconciliation drill.
- [ ] Notification, malware scanning, webhook egress, and Web Push use approved
  real providers. `log` and `allow_all` adapters are not production evidence.
- [ ] The external LiveKit/TURN composition has approved WSS/HTTPS,
  UDP/TCP/TURN-TLS reachability, relay controls, expected group size and
  audio/video/screen bandwidth capacity plus headroom, privacy/consent, outage handling, and
  content-blind telemetry. `AUDIO_TOKEN_TTL_SECONDS` is 60-300;
  `AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS` is 660-1,800 and not shorter
  than the token lifetime.
- [ ] Every audio/video access-change trigger commits independently of provider I/O,
  immediately blocks new credentials, and queues durable participant eviction.
  The provider exercise proves retry recovery and repeated self-hosted removal
  bounds cached-token replay for the minimum enforcement horizon, retains
  failures beyond it, and succeeds at or after it.
- [ ] The approved media revocation SLO explicitly accepts bounded self-hosted
  eviction or supplies a separately implemented and qualified LiveKit Cloud
  token-revocation path. Whole-room deletion is documented as an all-caller
  incident fallback, not as per-participant revocation.
- [ ] Secrets are externally owned, rotated, scoped, and excluded from Git,
  images, logs, and ordinary support access.
- [ ] Trusted DNS/TLS, ingress limits, network policy, and authenticated
  observability endpoints are verified from an internal client.
- [ ] Corporate authentication policy is approved. If local passwords remain,
  compensating controls, recovery ownership, session ceilings, and the absence
  of IdP-enforced MFA are explicitly accepted. If corporate OIDC/MFA is
  required, the proposed
  [ADR-0023 boundary](../02-architecture/adr/0023-corporate-oidc-scim-boundary.md)
  is a separate implementation and qualification gate and remains open.
- [ ] Production-scale load, reconnect storm, provider outage/recovery, node or
  zone failure, and soak tests meet approved SLOs at expected peak plus
  headroom.
- [ ] Camera and screen consent, capture indicators, default-off prejoin,
  permission denial/revocation, screen-source education, immediate stop,
  background teardown, recording-disabled provider policy, and privacy incident
  response have named evidence and approval.
- [ ] Alerts reach the real on-call receiver and every alert identifies user
  impact, severity, owner, starting query, safe mitigation, stop condition,
  validation, and escalation.
- [ ] Release, rollback, roll-forward, backup, restore, privacy/security,
  support, incident-command, and status-communication authority is named and
  exercised.
- [ ] Data classification, retention, legal hold, deletion, audit access, and
  support-content access are approved by security/privacy owners.
- [ ] Capacity, provider cost, observability retention, and pilot budget are
  approved.

## People gate

- [ ] Twelve-person validation study meets the participant mix and privacy
  contract.
- [ ] `node scripts/score_usability_study.mjs <study.json>` exits zero for the
  exact candidate.
- [ ] Manual WCAG 2.2 A/AA audit and assistive-technology matrix have no open
  critical or serious defect.
- [ ] Role-based member, tenant-admin/moderator, and operator exercises pass
  without unsafe facilitator workarounds.
- [ ] Two-week, 20–30-person internal pilot meets activation, weekly use,
  support-request, accessibility, security, and durability thresholds.
- [ ] Product, accessibility, security, operations, and business owners sign
  the release receipt.

## Rollout and stop conditions

Roll out by allowlisted tenant cohort with a staffed support channel and a
documented rollback decision-maker. Stop expansion and evaluate rollback for
any tenant-isolation failure, acknowledged-message loss, unauthorized audio
or video access beyond the approved revocation SLO, unintended camera/screen
capture, unrecoverable data error,
critical/serious accessibility blocker, Sev-1/Sev-2 incident, provider delivery
loop, alert-routing failure, or pilot usability gate regression.

The initial internal release includes browser one-to-one and group audio/video
calls plus explicit screen sharing. It does not add SIP, recording,
transcription, arbitrary media egress, federation, media
end-to-end encryption, native mobile clients, active-active writes, arbitrary
cluster administration from `/ops`, broad self-service multi-IdP, or a claim
of general availability.
