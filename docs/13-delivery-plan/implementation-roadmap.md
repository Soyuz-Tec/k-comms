# Implementation Roadmap

## Phase 0 — Decisions and proof points

- Resolve E2EE, call/media-plane boundaries, scale, retention, RPO/RTO,
  residency, and client scope. ADR-0025 resolves the audio/video boundary while
  production provider evidence remains open.
- Approve critical ADRs.
- Prototype message transaction, sequence allocation, channel replay, and node failure.
- Establish baseline repository, CI, environments, and telemetry.

**Gate:** architecture baseline and benchmark feasibility approved.

## Phase 1 — Platform foundation

- Identity/tenancy, sessions, authorization framework
- Core schema and migration tooling
- Edge/API and worker release roles
- Observability, secrets, CI/CD, staging

**Gate:** secure authenticated skeleton deploys and operates in staging.

## Phase 2 — Durable messaging MVP

- Conversations/membership
- Message send, ordering, idempotency, history
- WebSocket delivery and offline synchronization
- Basic web client and administration

**Gate:** message invariants pass failure, load, and tenant-isolation tests.

## Phase 3 — Product completion

- Attachments, notifications, search, reactions, replies, read state
- Unified one-to-one/group audio/video calls and explicit screen sharing
- Moderation, audit, retention, integrations
- Mobile/desktop synchronization contracts

**Gate:** end-to-end acceptance and production-scale rehearsal.

## Phase 4 — Production hardening and launch

- SLO dashboards and alerts
- Backup/restore and DR exercises
- Security testing and remediation
- Capacity, cost, runbooks, on-call, support readiness

**Gate:** production readiness review.

## Phase 5 — Scale and enterprise evolution

- Sharding/partitioning as evidence requires
- Advanced compliance and enterprise identity
- Media-region/group-scale evolution, federation, E2EE, or multi-region architecture
