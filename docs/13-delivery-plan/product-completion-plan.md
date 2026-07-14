# Product Completion Plan

**Target:** web-first, multi-tenant communication platform

**Release status:** K-Comms 0.3.0 MVP implemented. Revision
`bc6ba02536b4bfb703cd5e196d2e431b690a24ad` was locally staging-qualified on
2026-07-12; every newer candidate requires its own exact-revision
qualification. Production launch remains gated by the environment and
organizational work listed below.

## Product surfaces

| Surface | Route boundary | Primary users | Required capabilities |
|---|---|---|---|
| User workspace | `/app` | Members and moderators | Conversations, messages, search, files, notifications, account and device settings |
| Tenant administration | `/admin` | Owners, tenant administrators, compliance administrators | People, channels, policy, moderation, audit, retention, integrations, storage and security |
| Platform operations | `/ops` | Support, platform operators, security administrators | Content-blind service health, queues, providers, backups, incidents and controlled recovery actions |

The three surfaces share the React and TypeScript application platform but do
not share authority. Server-side authorization remains the source of truth.

## Completion record

| Increment | Delivered scope | Evidence status |
|---|---|---|
| Correctness foundation | Gap-free realtime catch-up, resilient refresh, durable unread/read behavior, routed modules, API/event contracts, client harness | Implemented and automated |
| User communication | Direct/group/channel journeys, search, edit/delete, replies/threads/mentions, history paging, retry, and safe attachment UX | Desktop and mobile browser journeys passed |
| Identity and administration | Recovery, sessions/devices, invitations, lifecycle, permission catalogue, channel administration, and last-owner safety | Role, boundary, recovery, and audit tests passed |
| Governance and safety | Moderation, audit/export, retention, legal hold, deletion, malware scan/quarantine, and quotas | Policy and reconciliation tests passed |
| Delivery and integrations | Email/push/in-app state, webhook endpoints/secrets/deliveries/replay, and scoped service accounts | Idempotency, SSRF, redaction, and recovery tests passed |
| Operations package | Protected read models, telemetry, manifests, controlled actions, backup/restore, rollout, rollback, and roll-forward | Implemented; historical local three-node proof passed and must be repeated per candidate |
| Local launch qualification | Accessibility/compatibility browser suite, bounded load, pod replacement, restore, rollback, and roll-forward | Historical revision-bound staging gate passed; not current-candidate evidence or a production SLO |

The historical revision-bound local performance gate sent 300 messages with
zero failed sends, zero loss, ordered history, ten matching idempotency probes,
5 messages/second, p95 23.13 ms, and p99 25.13 ms. Baseline acceptance also
exercised the configured 25,000,000-byte attachment ceiling. PostgreSQL and
MinIO backup/restore, one edge replacement, one worker replacement, rollback
compatibility, and roll-forward product acceptance passed with two edge
replicas and one worker. These results do not promote a different Git revision.

## Production launch work

The owner/evidence checklist and controlled internal release boundary are
maintained in
[internal-production-readiness.md](internal-production-readiness.md). The
application, environment/operating, and people gates are independent and must
all identify the same immutable release.

- Qualify the selected managed PostgreSQL, object storage, certificate, secret,
  notification, and malware-scanning services with production credentials.
- Run production-scale load/soak, reconnect storm, multi-zone failure, recovery,
  and disaster-recovery exercises against the approved topology.
- Complete independent security/privacy and provider/compliance reviews.
- Approve capacity and cost, incident response, customer support, alert routing,
  rollback authority, and staffed on-call coverage.

## Global definition of done

An increment is complete only when code, schemas, tests, contracts,
documentation, telemetry, migration/rollback instructions, and runtime
acceptance evidence apply to the promoted immutable release. Deferred provider
or environment decisions remain explicit launch blockers; a logging adapter,
unchecked box, or unexercised runbook is not production evidence.

Voice/video, federation, active-active multi-region writes, and true end-to-end
encryption remain outside this release unless superseded by a dedicated ADR.
