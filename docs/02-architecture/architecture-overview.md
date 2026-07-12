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

## Data systems

- PostgreSQL: authoritative messages, memberships, policies, jobs/outbox, and audit.
- Object storage: attachments and generated variants.
- Search index: optional derived projection.
- BEAM process state/ETS: bounded, reconstructable caches and ephemeral state.

## Boundaries

- Identity and tenancy
- Conversations and membership
- Messaging
- Realtime and synchronization
- Presence
- Attachments
- Notifications
- Search
- Integrations
- Administration and compliance

## Evolution path

Extract a domain into a separate service only when independent scaling, isolation, ownership, data residency, or deployment cadence provides measurable benefit greater than the operational cost.
