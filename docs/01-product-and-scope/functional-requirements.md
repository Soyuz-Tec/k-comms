# Functional Requirements

**Status:** K-Comms 0.3.0 application scope is implemented. Revision
`bc6ba02536b4bfb703cd5e196d2e431b690a24ad` is the historical locally
staging-qualified baseline; every newer candidate requires exact-revision
qualification. Rows with a residual qualifier require a real external
provider, independently sealed exact-commit review evidence, or another named
production gate; they are not missing local UI/API surfaces.

| ID | Requirement | Priority | Implemented acceptance evidence | Status |
|---|---|---|---|---|
| FR-ID-001 | Authenticate human users and bind rotating sessions to devices. | Must | Password, recovery, refresh rotation, socket ticket, logout, device/session revocation, and negative-boundary tests | Implemented |
| FR-TEN-001 | Isolate tenant data and policy. | Must | Tenant-scoped authorization, memberships, composite constraints, quotas, and cross-tenant negative tests | Implemented baseline; independent security review pending |
| FR-CONV-001 | Create direct, group, public-channel, and private conversations. | Must | Membership, visibility, public discovery/join/leave, archive, role, and quota tests | Implemented |
| FR-MSG-001 | Send a durable ordered message with a client idempotency key. | Must | Transactional acceptance, canonical sequence, duplicate replay, outbox, load reconciliation, and node replacement | Implemented |
| FR-MSG-002 | Edit and delete messages according to tenant policy. | Must | Edit-window, author/moderator authorization, revision, tombstone, governance, and retention tests | Implemented |
| FR-MSG-003 | Support replies, reactions, mentions, and canonical threads. | Should | Ordered thread/reply, mention validation, reaction, notification, and browser journeys | Implemented |
| FR-RT-001 | Deliver authorized live events to connected clients. | Must | Phoenix join/command authorization, Presence/typing, one-time socket tickets, and disconnect tests | Implemented; production fan-out capacity pending |
| FR-COM-001 | Provide authorized one-to-one and group audio/video calls with explicit capture controls and screen sharing. | Must | Unified call lifecycle and media kind, source-restricted LiveKit grants, responsive group grid, screen-share cleanup, durable expiry/eviction, and live multi-participant RTP journeys | Implemented local same-host baseline; production WSS/TURN/capacity/privacy evidence pending |
| FR-SYNC-001 | Recover missed durable events after reconnect. | Must | REST and Phoenix replay, paging, sequence ordering, disconnect/reconnect, and idempotent retry tests | Implemented |
| FR-PRES-001 | Show approximate presence and typing state without treating it as durable delivery. | Should | Presence/typing channel behavior and client state tests | Implemented |
| FR-FILE-001 | Upload, verify, scan, quarantine, download, and delete attachments. | Must | Signed checksum, version ID/ETag, exact-version scan/download/delete, stale-object, malicious-object, 25 MB ingress, quota tests, and guarded integrated restored-version remap proof | Application and portable staging restore implemented; production provider-native recovery qualification pending |
| FR-NOTIF-001 | Generate in-app, email, and browser-push notification intents from user policy. | Must | Durable intent/attempt ledger, in-app state, encrypted per-device push registration, retry/idempotency, and redacted log-adapter acceptance | Application implemented; real email/push provider delivery pending |
| FR-SRCH-001 | Search only active content visible to the requesting identity. | Must | PostgreSQL FTS with tenant, active membership, archived conversation, message status, and service-scope checks | Implemented |
| FR-ADM-001 | Administer users, invitations, channels, tenant policy, roles, sessions, and quotas. | Must | Separate admin UI, last-owner rules, role boundaries, optimistic versions, server-side recent step-up controls, audit, and admission tests | Implemented baseline; closure of the separately sealed exact-commit Codex Security result is a promotion gate |
| FR-MOD-001 | Report and manage moderation cases and attachment safety. | Must | Reporter/moderator boundaries, case actions, scan inventory/retry, quarantine, and audit tests | Implemented; real scanner qualification pending |
| FR-GOV-001 | Manage retention, legal holds, deletion requests, and audit export. | Must | Step-up authorization, state transitions, legal-hold blocking, object deletion evidence, and bounded formula-neutralized CSV tests | Implemented baseline; compliance approval and production retention pending |
| FR-INT-001 | Expose versioned APIs, signed webhooks, and safe provider adapters. | Should | OpenAPI/AsyncAPI/JSON Schema validation, encrypted webhook secrets, DNS/IP-pinned HTTPS, delivery claims, retry/replay, and SSRF tests | Implemented adapters; real provider and distributed edge rate-limit qualification pending |
| FR-SVC-001 | Provide scoped non-human communication credentials. | Should | One-time service credential, separate route boundary, scope/membership enforcement, expiry, rotation/revocation, idempotent send, and search tests | Implemented; production credential operations pending |
| FR-OPS-001 | Provide content-blind tenant and platform operations views. | Must | Separate `/ops` UI, persisted platform-role checks, protected metrics, provider/queue/health projections, and no-content response tests | Implemented package; alert routing and staffed operations pending |

SIP, recording, transcription, federation, active-active multi-region writes,
OIDC/SAML/SCIM, MFA/passkeys, and true end-to-end encryption are outside the
0.3.0 scope unless introduced through a dedicated requirement and ADR.
