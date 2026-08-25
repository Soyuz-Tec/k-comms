# Feature Progress Matrix

```yaml
status: in-review
owner: product-and-engineering
reviewers: [product, architecture, security, sre, accessibility]
last_reviewed: 2026-08-25
next_review: 2026-09-08
related_requirements: [product-completion, internal-production-readiness]
related_adrs: [ADR-0025, ADR-0057, ADR-0063]
related_tests: [release-32824311645, external-media-qualification-2026-07-27]
```

## Purpose

This matrix is the durable reference for comparing the original 36-feature
baseline with the currently verified K-Comms capability set. It records
implementation maturity separately from production qualification: a feature
can be usable while provider, capacity, recovery, accessibility, compliance,
or representative-user gates remain open.

Do not infer a completion percentage from these categories. Update a row only
after code, test, release, or retained external evidence changes its status.
Every update must also refresh the snapshot identity, evidence register,
`last_reviewed`, and change log.

## Current snapshot

| Field | Verified value |
|---|---|
| Git revision | `d486b5a2ef2467756f7558b28d84de3d38278c3d` |
| Immutable image | `ghcr.io/soyuz-tec/k-comms@sha256:1e6e1dd0d2d15dd1347aa5e11415bbf03e8d986d05b803fc883eac27adc051f2` |
| Release workflow | [Run 32824311645](https://github.com/Soyuz-Tec/k-comms/actions/runs/32824311645) |
| Staging | VM 101 deployed and qualified |
| Production | VM 100 deployed and public verification passed |
| Snapshot date | 2026-08-25 |

## Status model

| Status | Meaning |
|---|---|
| **Complete** | The defined core feature is implemented, tested, and included in the current production release. |
| **Partial** | A usable implementation or baseline exists, but one or more named delivery or qualification gates remain open. |
| **Not started** | No K-Comms product implementation exists beyond planning, provider capability, or framework support. |

Movement uses **Up** for a status-category improvement, **Improved** for
material capability or evidence added without changing category, and **None**
when no material status change has been verified. Accountable roles are
planning assignments until a named owner accepts them.

## Portfolio summary

| Current status | Features | Share (rounded) |
|---|---:|---:|
| Complete | 7 | 19.4% |
| Partial | 12 | 33.3% |
| Not started | 17 | 47.2% |
| **Total** | **36** | **100%** |

## Feature comparison

| ID | Capability | Accountable role | Original baseline | Current status | Movement | Evidence | Next gate |
|---:|---|---|---|---|---|---|---|
| F-01 | User authentication and account management | Identity engineering | Complete | **Complete** | None | E2 | Enterprise OIDC, MFA/passkeys, and SCIM are separate future scope. |
| F-02 | Tenant and workspace administration | Product engineering | Complete | **Complete** | None | E2 | Continue role-boundary and tenant-isolation regression coverage. |
| F-03 | Direct and group messaging | Messaging engineering | Complete | **Complete** | None | E2, E3 | Requalify ordering, replay, and delivery for every promoted candidate. |
| F-04 | Channels, threads, replies, mentions, and reactions | Messaging engineering | Complete | **Complete** | None | E2 | Maintain API, event, and browser-journey compatibility. |
| F-05 | Presence, typing indicators, and read status | Realtime engineering | Complete | **Complete** | None | E2 | Continue reconnect and ephemeral-state reconstruction tests. |
| F-06 | File sharing and attachment management | Content engineering | Complete | **Complete** | None | E2, E3 | Qualify approved malware scanning and production object-storage controls. |
| F-07 | Notifications and browser push | Integrations engineering | Partial | **Partial** | None | E2, E3 | Qualify approved email, Web Push, and notification providers in production. |
| F-08 | Audio calling | Media engineering | Partial | **Partial** | None | E4, E5 | Run the office readiness tool from both physical endpoints on the UAE network, then complete revocation, outage, and capacity qualification. |
| F-09 | Video calling | Media engineering | Partial | **Partial** | None | E4, E5 | Complete broader resilience, privacy, and representative-network qualification. |
| F-10 | Group conferencing | Media engineering | Partial | **Partial** | None | E3, E4 | Pass three-or-more-participant capacity, reconnect, and failure exercises. |
| F-11 | Screen sharing | Media engineering | Partial | **Partial** | None | E3, E4 | Qualify external cross-platform sharing, audio, cleanup, and revocation. |
| F-12 | Collaborative whiteboard | Collaboration engineering | Not started | **Complete** | **Up** | E1, E6, E7 | Maintain concurrency, recovery, authorization, and SDK compatibility gates. |
| F-13 | Shared documents and realtime co-editing | Collaboration engineering | Not started | **Not started** | None | E2 | Approve the product need and a dedicated collaboration ADR before implementation. |
| F-14 | Unified collaboration workspace | Product engineering | Partial | **Partial** | **Improved** | E2, E6 | Add approved shared-document, calendar, native-client, and telephony surfaces. |
| F-15 | Call recording and media playback | Media engineering | Not started | **Not started** | None | E2, E3 | Approve consent, privacy, retention, and managed-room architecture. |
| F-16 | Transcription, captions, and meeting summaries | Media and AI engineering | Not started | **Not started** | None | E2, E3 | Approve provider, consent, retention, access, and accuracy requirements. |
| F-17 | Native iOS application | iOS engineering | Not started | **Not started** | None | E2, E3 | Approve the native-client ADR, then implement SwiftUI, LiveKit, CallKit, and APNs. |
| F-18 | Native Android application | Android engineering | Not started | **Not started** | None | E2, E3 | Approve the native-client ADR, then implement Compose, LiveKit, Core-Telecom, and FCM. |
| F-19 | Windows desktop application | Desktop engineering | Not started | **Not started** | None | E2 | Decide whether the PWA is sufficient or approve a signed desktop package. |
| F-20 | macOS desktop application | Desktop engineering | Not started | **Not started** | None | E2 | Decide whether the PWA is sufficient or approve a signed desktop package. |
| F-21 | Linux desktop application | Desktop engineering | Not started | **Not started** | None | E2 | Decide whether the PWA is sufficient or approve a packaged desktop client. |
| F-22 | SIP calling and registration | Telephony engineering | Not started | **Not started** | None | E2, E3 | Select a provider and approve SIP identity, routing, security, and lifecycle contracts. |
| F-23 | PSTN inbound and outbound calling | Telephony engineering | Not started | **Not started** | None | E2, E3 | Contract and qualify a carrier, trunks, numbers, fraud controls, and call flows. |
| F-24 | Phone-number and trunk management | Telephony engineering | Not started | **Not started** | None | E2 | Define tenant administration, provider reconciliation, and audit contracts. |
| F-25 | IVR and auto-attendant | Telephony engineering | Not started | **Not started** | None | E2 | Approve product flows and a state-machine design after core PSTN delivery. |
| F-26 | Call queues, routing, and contact-center controls | Telephony engineering | Not started | **Not started** | None | E2 | Define routing, presence, queue durability, supervisor, and reporting requirements. |
| F-27 | Voicemail | Telephony engineering | Not started | **Not started** | None | E2 | Define recording consent, storage, retention, notification, and playback policy. |
| F-28 | Calendar integration and meeting scheduling | Integrations engineering | Not started | **Not started** | None | E2 | Select calendar providers and approve authorization, synchronization, and conflict rules. |
| F-29 | External workspace and organizational federation | Platform architecture | Not started | **Not started** | None | E2, E3 | Define trust, identity mapping, data residency, abuse, and cross-tenant authorization. |
| F-30 | Advanced search and unified content discovery | Search engineering | Partial | **Partial** | None | E2 | Complete authorization-aware discovery across messages, files, people, and collaboration content. |
| F-31 | Moderation, retention, legal hold, and audit | Security and compliance | Partial | **Partial** | None | E2, E3 | Obtain policy-owner approval and complete production evidence and recovery exercises. |
| F-32 | Third-party integrations and webhooks | Integrations engineering | Partial | **Partial** | None | E2, E3 | Qualify approved real providers, credentials, delivery, replay, and outage behavior. |
| F-33 | Analytics, call-quality monitoring, and reporting | Observability engineering | Partial | **Partial** | None | E3 | Complete content-blind media quality, product analytics, dashboards, and alert ownership. |
| F-34 | End-to-end encryption | Security architecture | Not started | **Not started** | None | E2, E3 | Approve private-room key ownership, rotation, recovery, and incompatible-feature behavior. |
| F-35 | Multi-region availability and disaster recovery | SRE and platform engineering | Partial | **Partial** | None | E1, E3, E8 | Qualify multi-zone loss, provider failure, regional routing, and recovery objectives. |
| F-36 | Accessibility and physical-device certification | Accessibility and quality engineering | Partial | **Partial** | None | E3, E5, E9 | Complete manual WCAG audit, assistive-technology matrix, usability study, and internal pilot. |

## Evidence register

| ID | Evidence source | What it supports |
|---|---|---|
| E1 | [Release workflow 32824311645](https://github.com/Soyuz-Tec/k-comms/actions/runs/32824311645) | Immutable publication, VM 101 qualification, rollback/restore rehearsal, VM 100 same-digest deployment, complete backups, and public verification for the current snapshot. |
| E2 | [Product completion plan](product-completion-plan.md) | Implemented web-first product baseline and explicitly excluded capabilities. |
| E3 | [Internal production readiness](internal-production-readiness.md) | Open application, environment, provider, capacity, security, accessibility, and people gates. |
| E4 | [ADR-0025](../02-architecture/adr/0025-unified-audio-video-calls.md) | Browser audio, video, conferencing, and screen-sharing architecture. |
| E5 | [External media qualification](../11-testing-and-quality/external-media-qualification-2026-07-27.md) | Dated two-device cellular production audio/video evidence and its explicit limitations. |
| E6 | [ADR-0063](../02-architecture/adr/0063-conversation-whiteboards-with-excalidraw.md) | Excalidraw adapter, durable whiteboard authority, realtime transport, isolation, and failure boundaries. |
| E7 | [Core tests](../../apps/comms_core/test/whiteboards_test.exs), [API tests](../../apps/comms_web/test/whiteboard_controller_test.exs), [channel tests](../../apps/comms_web/test/whiteboard_channel_test.exs), and [client collaboration tests](../../clients/web/src/features/whiteboard/useWhiteboardCollaboration.test.tsx) | Durable replay, idempotency, authorization, presence, concurrency, clear behavior, and reconnect handling. |
| E8 | [Disaster recovery](../08-reliability/disaster-recovery.md) | Recovery scope, objectives, and remaining regional resilience work. |
| E9 | [Usability validation](../11-testing-and-quality/usability-validation.md) | Manual accessibility, task-success, usability-study, and internal-pilot gates. |

## Update procedure

1. Verify the canonical Git revision, immutable image digest, deployment state,
   and retained evidence before editing a status.
2. Update `Current status` only when the status definition is satisfied; record
   incremental progress that does not cross a category in `Movement` and
   `Next gate`.
3. Add or update an evidence-register entry. Do not cite chat statements,
   unchecked templates, provider capability pages, or unbound historical runs
   as current-release proof.
4. Record the change below and refresh the document metadata and portfolio
   totals.
5. Review changes through the protected documentation workflow. A
   documentation-only change does not trigger a runtime deployment.

## Change log

| Date | Snapshot | Change |
|---|---|---|
| 2026-08-25 | `d486b5a2ef2467756f7558b28d84de3d38278c3d` | Refreshed the current production snapshot after the consolidated dependency release. The same immutable digest passed provenance and SBOM verification, VM 101 rollback and isolated-restore rehearsal, VM 100 deployment, and public endpoint verification; no feature status changed. |
| 2026-08-01 | `90c1f89fff3df0d3871762b137775e170a7553b1` | Established the 36-feature matrix. F-12 moved from Not started to Complete after the Excalidraw collaboration release; F-14 recorded material workspace improvement while remaining Partial. |
