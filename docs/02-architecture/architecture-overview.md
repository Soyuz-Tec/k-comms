# Architecture Overview

**Status:** Draft
**Style:** Modular monolith with independently scalable runtime roles

## Architectural principles

1. Persist authoritative state before acknowledging success.
2. Treat real-time delivery as an acceleration path, not the source of truth.
3. Make every client capable of replaying missed durable events.
4. Keep ephemeral state distinct from durable business state.
5. Partition work by tenant, conversation, or key; avoid global processes.
6. Keep domain logic independent of HTTP, WebSocket, and job adapters.
7. Make retries expected and commands idempotent.
8. Prefer observable, reversible changes.

## Runtime roles

- **Edge/API:** HTTPS, WebSocket, authentication, channel joins, command translation, and live delivery.
- **Worker:** notifications, search indexing, attachment processing, webhooks, retention, and exports.
- **Administrative:** migrations, scheduled operations, internal tools, and maintenance workflows.

## Product surfaces

- **User workspace (`/app`):** tenant-scoped communication, search, files,
  notifications, profile, and personal device/session controls.
- **Tenant administration (`/admin`):** people, channels, policy, moderation,
  audit, retention, integrations, storage, and tenant security.
- **Platform operations (`/ops`):** separately authorized, content-blind health,
  queue, provider, backup, incident, and controlled recovery workflows.

The surfaces share a web-client platform but never substitute client-side route
checks for server-side authorization.

Service automation is a fourth, API-only boundary. Tenant admins manage
service principals in `/admin`, while credentials authenticate only the
`/api/v1/service/*` namespace. Service principals have no browser, refresh,
WebSocket, tenant-admin, or platform-operations session and remain constrained
by tenant membership plus explicit scopes.

## Data systems

- PostgreSQL: authoritative messages, memberships, policies, jobs/outbox, and audit.
- Object storage: attachments and generated variants.
- Search index: optional derived projection.
- BEAM process state/ETS: bounded, reconstructable caches and ephemeral state.

## Boundaries

- Identity and tenancy
- Service-principal authentication
- Conversations and membership
- Messaging
- Realtime and synchronization
- Presence
- Attachments
- Notifications
- Search
- Integrations
- Administration and compliance

Tenant identity, conversation, and membership growth passes through one
`AdmissionQuotas` domain boundary. Admission checks and tenant-limit updates
share a tenant-scoped PostgreSQL transaction advisory lock, so replicas cannot
over-admit during concurrent creates, joins, reactivations, or policy changes.
The admin surface reports exact-capacity and over-limit state without deleting
existing resources.

Messaging persists explicit mention recipients and canonical thread roots in
the same transaction as the message and outbox events. Notifications consume
those identifiers for human-only fanout. In-app read/dismiss state is durable;
the user WebSocket topic carries only content-free availability metadata and
clients reconcile full state through authenticated REST reads.

## Evolution path

Extract a domain into a separate service only when independent scaling, isolation, ownership, data residency, or deployment cadence provides measurable benefit greater than the operational cost.
