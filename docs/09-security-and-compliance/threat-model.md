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

## Priority threat scenarios and current disposition

| ID | Scenario | Implemented 0.3.0 controls | Residual verification or launch gate |
|---|---|---|---|
| T-001 | Cross-tenant record or object access through a guessed identifier | Tenant-scoped queries, composite ownership checks, membership authorization, opaque IDs, and negative tests | Independent authorization review remains pending |
| T-002 | A stolen refresh token maintains long-lived access | Hashed rotating refresh tokens, device/session binding, expiry, revocation, password-reset invalidation, and socket disconnect | Production anomaly detection and incident rehearsal remain pending |
| T-003 | A WebSocket remains authorized after membership or session revocation | One-time hashed socket tickets, join and per-command checks, membership validation, and disconnect broadcast | Multi-zone revocation behavior remains a production exercise |
| T-004 | A malicious or substituted attachment is served | Quarantine-first state, signed checksum, completion identity, exact version ID/ETag binding, scanner gate, and version-bound download/delete | Approved scanner and object provider plus outage/rotation exercises remain pending |
| T-005 | Webhook, scanner, or notification configuration enables SSRF or DNS rebinding | HTTPS-only endpoints, explicit DNS host allowlists, public-IP validation, DNS resolution followed by IP-pinned TLS, response bounds, and restricted egress | Provider composition and egress policy require independent review |
| T-006 | Logs, traces, audit responses, or operations views leak content or credentials | Allow-listed structured logging, response presenters, redaction tests, content-blind platform operations, recovery-event suppression, Sobelow, and Trivy filesystem secret scanning | Sealed exact-commit Codex Security evidence and production log sampling are promotion gates |
| T-007 | Retry or concurrent workers duplicate an external or messaging effect | Idempotency keys, unique records, transactional outbox, claim tokens/generations, delivery ledgers, and replay tests | Real provider idempotency behavior must be qualified |
| T-008 | Tenant or platform administrative authority is abused | Persisted role checks, separated platform roles, server-side recent step-up for sensitive tenant/admin/integration/moderation/governance operations, reasons/versions, and audited one-shot platform-role grant/revoke | Exact-commit Codex Security closure is a promotion gate; platform-role expiry is not in 0.3.0 |
| T-009 | Backup access bypasses application authorization | Restricted evidence path, checksums, isolated quiesced PostgreSQL/object restore, fail-closed guarded exact-version remap, audit records, restored UI readback, and authenticated SHA-256-matching download | Production encryption/access review, independent backup location, managed PITR, and provider-native recovery rehearsal remain pending |
| T-010 | Password hashing, joins, fan-out, reconnects, or large payloads exhaust the service | Request/payload bounds, tenant admission quotas, trusted-proxy CIDR/spoof-resistance checks, node-local IP/account limits, production auth-ingress connection/rate/burst limits, reconnect bounds, HPA manifests, and bounded load tests | Provider-specific globally distributed edge semantics/load proof and production reconnect/large-room capacity remain pending |
| T-011 | Password recovery reveals account existence or leaks a reset credential | Identical public response padded to a 500 ms minimum plus 0–50 ms jitter, rate limits, dummy password work, one-time HMAC token, hash-only persistence, fragment URL, and full session/device revocation | Statistical timing review through the real ingress and provider-delivery review remain pending |
| T-012 | A service credential crosses into human or unauthorized conversation APIs | Separate credential format/pipeline, random secret with hash-only storage, bounded scopes, membership enforcement, expiry/rotation/revocation, and human-route denial | Credential distribution and production rotation procedures remain pending |
| T-013 | Browser-push subscription material or VAPID authority is exposed | Per-device subscription ownership, AES-256-GCM ciphertext with contextual AAD, versioned key IDs, redacted projections, and provider-owned VAPID private key | Real push-provider qualification and key-rotation exercise remain pending |
| T-014 | Development adapters are promoted and silently accept unsafe work | Explicit `ALLOW_DEVELOPMENT_ADAPTERS`, fail-closed runtime validation, production semantic preflight, and manifest tests | Promotion authority must retain and review the exact composed bundle |
| T-015 | Audit CSV triggers spreadsheet execution or exports unbounded data | Tenant-first query, 5,000-row cap, NUL stripping, formula neutralization, quoting, redacted filter evidence, and step-up | Office-client sampling and retention approval remain pending |
| T-016 | Database and object restore points are mutually inconsistent | Maintenance-window quiescence plus integrated restored-stack proof covering 18 attachment rows/10 objects, four ready version-bound remaps, five audit records, restored UI visibility, and an authenticated exact-SHA-256 download | Preserve this consistency boundary in the provider-native design and prove it with managed-state/PITR recovery before production reliance |

## Review rule

Run a structured independent review against the exact release commit and the
provider-composed deployment. Validated findings must be tracked to closure or
explicit risk acceptance. No production promotion may infer security approval
from dependency audits, schema validation, or the local runtime proof alone.
