# Architecture Overview

**Status:** Accepted implementation baseline for K-Comms 0.3.0
**Style:** Strict modular monolith with independently scalable runtime roles

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

Runtime roles use the same `k_comms` release artifact. Separate edge and worker
deployments provide independent process scaling and failure containment without
creating separately versioned services or distributed data ownership.

## Application module boundaries

The dependency matrix below is authoritative. Entries are permitted direct
in-umbrella dependencies, not dependencies that every application must use.
Any unlisted edge is forbidden.

| Application | Allowed direct in-umbrella dependencies | Responsibility |
|---|---|---|
| `comms_core` | None | Domain rules, application commands, authoritative schemas, persistence, and core-owned ports |
| `comms_observability` | None | Framework-neutral telemetry conventions and rendering |
| `comms_integrations` | `comms_observability` | External storage and delivery provider adapters |
| `comms_workers` | `comms_core`, `comms_integrations` | Background-job and outbox execution adapters |
| `comms_web` | `comms_core`, `comms_integrations`, `comms_observability` | HTTP, WebSocket, authentication, and product delivery adapters |
| `comms_test_support` | `comms_core` | Non-release fixtures and test infrastructure |

Dependencies point inward: adapters call core context APIs, and core defines any
port an adapter implements. `comms_core` must not reference adapter modules,
module-name strings, or OTP application atoms. A new umbrella app or edge needs
an architecture decision and a matching update to the deterministic
`scripts/validate_architecture.py` policy.

Root `config/*.exs` files and the umbrella release definition form the
composition root. They may bind core-owned ports and runtime identifiers to
concrete adapter implementations. Concrete names must remain in that
composition layer or in the adapter application; they must not leak back into
`apps/comms_core/lib`.

### Business-context control plane

`context-boundaries.yaml` is the executable ownership source of truth. It
assigns every production `CommsCore` module and source table exactly once,
publishes stable facades and Ecto-free contracts, validates one-way compiled
and runtime collaborations, and declares exact adapter-facing technical
interfaces. Production web, worker, and integration code may reference only
published facades/contracts or a declared technical interface; owner-internal
schemas and projectors are rejected.

The gate runs in `strict` mode. Architecture analysis and the checked-in
baseline must both be empty; temporary violations, baseline adoption, and the
former deferral policy are forbidden. Paired immutable-base manifest
comparison prevents strict enforcement from being removed or downgraded and
protects retired namespace and runtime-binding tombstones. A reviewed
transition can document the exact removal of old fingerprints, but strict mode
cannot adopt a new finding.

The combined diagnostic graph can still report SCCs created by declared
dependency inversions: consumer-to-provider runtime control flow is paired
with provider-to-consumer compile-time implementation of a consumer-owned
port. Those exact validated inversions are accepted topology, not retained
violation fingerprints. Compiled and runtime business graphs are each
acyclic, and no combined SCC authorizes an undeclared edge.

### Persistence access policy

`CommsCore.Repo` is an internal core persistence capability. Released web,
worker, and integration code must read and mutate domain state through the
owning `CommsCore` context API. This keeps authorization, tenancy, locking,
auditing, and transaction rules at one boundary.

No released source may access `CommsCore.Repo` outside core. Health, metrics,
and other operational adapters call narrowly named `CommsCore` APIs for their
fixed read-only probes.

Only this exact non-release source file may access `CommsCore.Repo` outside
core:

| Source | Allowed use |
|---|---|
| `apps/comms_test_support/lib/comms_test_support/fixtures.ex` | Non-release test fixture setup |

Adding another exception requires architecture review and an update to both
this table and the validator. Test files under an application's `test/`
directory may use the SQL sandbox and Repo for assertions; they are not
compiled into the production release and are outside the runtime source rule.

## Product surfaces

- **User workspace (`/app`):** tenant-scoped text, one-to-one/group audio and
  video communication, screen sharing, search, files, notifications, profile,
  and personal device/session controls.
- **Tenant administration (`/admin`):** people, channels, policy, moderation,
  audit, retention, integrations, storage, and tenant security.
- **Platform operations (`/ops`):** separately authorized, content-blind health,
  queue, provider, backup, incident, and controlled recovery workflows. Access
  uses an audited, exact-deadline platform grant lasting no more than eight
  hours.

The surfaces share a web-client platform but never substitute client-side route
checks for server-side authorization.

Service automation is a fourth, API-only boundary. Tenant admins manage
service principals in `/admin`, while credentials authenticate only the
`/api/v1/service/*` namespace. Service principals have no browser, refresh,
WebSocket, tenant-admin, or platform-operations session and remain constrained
by tenant membership plus explicit scopes.

## Data systems

- PostgreSQL: authoritative messages, memberships, policies, unified call
  lifecycles/media kind/admissions, atomically scheduled expiry and eviction
  jobs, outbox, and audit.
- Object storage: attachments and generated variants.
- Search index: optional derived projection.
- BEAM process state/ETS: bounded, reconstructable caches and ephemeral state.
- LiveKit media plane: ephemeral encrypted audio/video/screen transport and
  participant state; it owns neither tenant authorization nor durable call
  history.

Call creation and its unique eight-hour expiry job commit together. The
worker runtime owns provider-room cleanup and then invokes the same durable
ended/outbox/admission-revocation transition used by an authorized manual end;
provider failure retries without transferring lifecycle authority to LiveKit.

## Business boundaries

- IdentityAccess
- TenantAdministration
- Conversations
- ConversationContent, including Messaging and Attachments
- Calls
- NotificationDelivery
- WebhookManagement
- TrustGovernance
- Audit
- OperationsReadModel

PlatformRuntime, PlatformPersistence, and PlatformEventing are narrow technical
owners rather than business contexts. Authorization policy belongs to the
owner of the protected state. Calls authorization is internal to Calls;
`CommsCore.Authorization` and its former runtime binding are retired
control-plane tombstones.

IdentityAccess, TenantAdministration, and Conversations contribute synchronous
Calls revocation through exact consumer-owned, transaction-required lifecycle
ports. Calls implements those ports without giving the consumers a compiled
dependency on Calls. Released web, worker, and integration adapters receive
only Calls-owned Ecto-free views and provider-work contracts.

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
clients reconcile full state through authenticated REST reads. If availability
delivery fails after the durable intent insert, the outbox retry re-signals the
same idempotent projection rather than creating another intent. Outbox
event/job creation itself requires an active caller transaction.

## Evolution path

Extract a domain into a separate service only when independent scaling, isolation, ownership, data residency, or deployment cadence provides measurable benefit greater than the operational cost.
