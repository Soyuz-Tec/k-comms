# K-Comms 0.3.0 Threat Model

**Status:** Implemented security baseline with automated negative tests. An
independent repository and production-composition security review is still
required before production traffic.

## High-value assets

- Passwords, password-recovery links, access/refresh tokens, sessions, devices,
  one-time socket tickets, and signing keys
- Tenant membership, roles, platform roles, admission quotas, and authorization
  policy
- Message bodies, drafts, private attachments, exact object version IDs, and
  search results
- Audit events, bounded CSV exports, moderation cases, legal holds, retention
  policy, and deletion evidence
- Webhook signing secrets, service-account credentials, encrypted browser-push
  subscriptions, and provider credentials
- LiveKit API credentials, short-lived participant tokens, TURN credentials,
  call membership and room identifiers, and private live audio, camera video,
  and screen-share content
- PostgreSQL and object-storage backups, restore metadata, encryption keys, and
  retained deployment bundles
- Short-lived bootstrap, qualification, and platform-role management secrets

## Trust boundaries

1. Browser or service client to the public edge/API and WebSocket endpoint.
2. Public ingress or API gateway to edge replicas; forwarded client identity is
   trusted only after explicit proxy configuration.
3. Edge and worker nodes to PostgreSQL, object storage, DNS, and provider HTTPS
   endpoints.
4. Tenant A data and authority to Tenant B data and authority.
5. Member, moderator, tenant administrator, compliance/security administrator,
   and separately granted platform operator.
6. Human bearer tokens, one-time socket tickets, service credentials, and
   release-operation credentials.
7. Application database identity to backup, restore, and infrastructure
   operator identities.
8. Development/local-proof adapters and credentials to any staging or
   production provider composition.
9. Browser microphone, camera, and explicit screen capture to the external
   LiveKit signaling/media plane; K-Comms authorization to LiveKit
   participant-token issuance; and public clients through the selected TURN
   relay.

## Priority threat scenarios and current disposition

| ID | Scenario | Implemented 0.3.0 controls | Residual verification or launch gate |
|---|---|---|---|
| T-001 | Cross-tenant record or object access through a guessed identifier | Tenant-scoped queries, composite ownership checks, membership authorization, opaque IDs, and negative tests | Independent authorization review remains pending |
| T-002 | A stolen refresh token maintains long-lived access | Hashed rotating refresh tokens, device/session binding, sliding expiry capped by an immutable stored absolute deadline, revocation, password-reset invalidation, and socket disconnect | Production anomaly detection and incident rehearsal remain pending |
| T-003 | A WebSocket remains authorized after membership, archival, session revocation, or absolute expiry | One-time hashed socket tickets, join and per-event checks, metadata-event interception, membership/session/absolute-deadline validation, and disconnect broadcast | Multi-zone revocation behavior remains a production exercise |
| T-004 | A malicious or substituted attachment is served | Quarantine-first state, signed checksum, completion identity, exact version ID/ETag binding, scanner gate, and version-bound download/delete | Approved scanner and object provider plus outage/rotation exercises remain pending |
| T-005 | Webhook, scanner, or notification configuration enables SSRF, DNS rebinding, slow-drip exhaustion, or protocol amplification | HTTPS-only endpoints, explicit DNS host allowlists, public-IP validation, DNS resolution followed by IP-pinned TLS, one total DNS/I/O deadline, response bounds, terminal protocol/size classification, and restricted egress | Provider composition and egress policy require independent review |
| T-006 | Logs, traces, audit responses, or operations views leak content or credentials | Allow-listed structured logging, response presenters, redaction tests, content-blind platform operations, recovery-event suppression, Sobelow, and Trivy filesystem secret scanning | Sealed exact-commit Codex Security evidence and production log sampling are promotion gates |
| T-007 | Retry, endpoint mutation, or concurrent workers duplicate or redirect an external effect | Idempotency keys, unique records, transactional outbox, claim tokens/generations, terminal failed deliveries, endpoint/delivery lock order, in-flight mutation conflict, explicit retry classification, delivery ledgers, and current-version replay tests | Real provider idempotency behavior must be qualified |
| T-008 | Tenant, conversation-owner, or platform administrative authority is abused | Persisted role checks, owner-escalation restrictions, separated platform roles, server-side recent step-up for sensitive state changes/retries and broad audit access, explicit role-scoped operational-read policy, reasons/versions, and audited one-shot platform-role grants bound to a fresh approval identifier and exact five-minute-to-eight-hour expiry | Exact-commit Codex Security closure, corporate approval/MFA policy, and independent production review remain gates |
| T-009 | Backup access bypasses application authorization | Restricted evidence path, checksums, isolated quiesced PostgreSQL/object restore, fail-closed guarded exact-version remap, audit records, restored UI readback, and authenticated SHA-256-matching download | Production encryption/access review, independent backup location, managed PITR, and provider-native recovery rehearsal remain pending |
| T-010 | Password hashing, service/socket admission, fan-out, reconnects, or large payloads exhaust the service | Request/payload bounds, tenant admission quotas, separate pre-work IP and authenticated buckets, fail-closed proxy trust with matching ingress-policy preflight, capped push subscriptions/fan-out, reconnect bounds, HPA manifests, and bounded load tests | Provider-specific globally distributed edge semantics/load proof and production reconnect/large-room capacity remain pending |
| T-011 | Password recovery reveals account existence, leaks a reset credential, or rebinds identity | Identical public response padded to a 500 ms minimum plus 0–50 ms jitter, rate limits, dummy password work, non-rebindable recovery email, one-time HMAC token, hash-only persistence, fragment URL, and full session/device revocation | Statistical timing review through the real ingress and provider-delivery review remain pending |
| T-012 | A service credential crosses into human or unauthorized conversation APIs | Separate credential format/pipeline, random secret with hash-only storage, bounded scopes, membership enforcement, expiry/rotation/revocation, and human-route denial | Credential distribution and production rotation procedures remain pending |
| T-013 | Browser-push subscription material or VAPID authority is exposed | Per-device subscription ownership, AES-256-GCM ciphertext with contextual AAD, versioned key IDs, redacted projections, and provider-owned VAPID private key | Real push-provider qualification and key-rotation exercise remain pending |
| T-014 | Development adapters are promoted and silently accept unsafe work | Explicit `ALLOW_DEVELOPMENT_ADAPTERS`, fail-closed runtime validation, production semantic preflight, and manifest tests | Promotion authority must retain and review the exact composed bundle |
| T-015 | Audit CSV triggers spreadsheet execution or exports unbounded data | Tenant-first query, 5,000-row cap, NUL stripping, formula neutralization, quoting, redacted filter evidence, and step-up | Office-client sampling and retention approval remain pending |
| T-016 | Database and object restore points are mutually inconsistent | Maintenance-window quiescence plus the revision-bound historical integrated restore proof, guarded exact-version remap, restored UI visibility, and authenticated exact-SHA-256 download | Re-run for every exact candidate; preserve this consistency boundary in the provider-native design and prove it with managed-state/PITR recovery before production reliance |
| T-017 | An invitation takes over an existing or suspended identity | Invitation creation and acceptance both reject every existing human email; audited administrative unsuspension remains the only reactivation path and preserves the existing password | Provider-delivery abuse monitoring and independent identity-flow review remain pending |
| T-018 | A caller joins, sees, or listens to another tenant or conversation by choosing a room, identity, media kind, or replaying a participant token | Call authorization derives opaque room/identity server-side, requires active session and membership, binds immutable `media_kind`, issues short-lived source-restricted tokens, rejects client-selected grants, and persists admission authority without the token | Independent cross-tenant and media-kind substitution review plus membership/session revocation during active audio/video calls are launch gates |
| T-019 | LiveKit API or TURN credentials leak, an unauthenticated TURN relay is abused, or provider logs expose call metadata | Provider credentials remain server-only in externally managed Secrets; browsers receive participant tokens only; production requires WSS/TLS, restricted TURN authentication, content-blind logs, and credential rotation | Provider configuration, relay-abuse testing, TLS/TURN reachability, redaction sampling, and rotation rehearsal remain pending |
| T-020 | Media traffic, reconnect storms, camera resolution, screen sharing, oversized rooms, recording, or provider failure causes denial of service or privacy harm | Calls are isolated from durable text readiness; production must qualify group size, participants, token lifetime, bandwidth/adaptation, recording-disabled policy, and retries and expose content-blind quality/capacity signals | Expected peak plus headroom, three-or-more participant video, forced-TURN, UDP-blocked fallback, provider interruption, privacy approval, and stop-condition exercises remain pending |
| T-021 | A session, device, user, membership, conversation, or tenant loses access while an admitted media participant remains connected or reconnects with a cached token | The authoritative access change and admission invalidation commit independently of provider I/O; durable media-queue work retries idempotent participant removal, repeats self-hosted enforcement for a 660-1,800 second minimum horizon, retains failures after it, and completes only after a removal succeeds at or after the horizon, without storing JWTs or secrets | Measure the exact access-change-to-disconnect SLO and cached-token replay bound in the provider composition. The self-hosted adapter does not promise instant token invalidation; stricter policy requires separately implemented and qualified LiveKit Cloud token revocation or whole-room deletion, which disconnects everyone |
| T-022 | Camera starts without informed action, background capture survives teardown, or screen sharing exposes unrelated applications or notifications | Video prejoin defaults camera/microphone off; Permissions Policy restricts capture to the first-party origin; screen sharing requires separate browser source selection and persistent stop control; every local track stops on leave/end/session loss/native track end/teardown; no recording, snapshot, transcript, or media persistence is authorized | Manual browser/privacy review, permission-revocation tests, OS/browser capture-indicator checks, screen-track cleanup, and internal-pilot consent feedback are launch gates |

## Review rule

Run a structured independent review against the exact release commit and the
provider-composed deployment. Validated findings must be tracked to closure or
explicit risk acceptance. No production promotion may infer security approval
from dependency audits, schema validation, or the local runtime proof alone.
