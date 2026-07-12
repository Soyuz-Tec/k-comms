# Threat Model

**Status:** Draft

## High-value assets

- Authentication credentials, sessions, and signing keys
- Tenant membership and authorization policy
- Message bodies and private attachments
- Audit records and compliance exports
- Administrative capabilities
- Webhook secrets and bot credentials
- Backups and encryption keys

## Trust boundaries

1. Client device to edge/API.
2. Public edge to private application/data networks.
3. Application to identity, notification, search, and storage providers.
4. Tenant A data and Tenant B data.
5. Ordinary user, tenant administrator, support operator, and system administrator.
6. Production and non-production environments.

## Priority threat scenarios

| ID | Scenario | Primary mitigations | Verification |
|---|---|---|---|
| T-001 | Cross-tenant object access through guessed ID | Tenant-scoped authorization, opaque IDs, negative tests | Automated authorization suite |
| T-002 | Stolen refresh token maintains long-lived access | Rotation, revocation, device sessions, anomaly detection | Session tests and audit review |
| T-003 | WebSocket remains authorized after membership removal | Per-command checks or revocation propagation | Removal-during-session test |
| T-004 | Malicious attachment is served before scan | Quarantine state, signed URLs, scanner gate | Pipeline integration test |
| T-005 | Webhook endpoint enables SSRF | URL policy, DNS/IP validation, egress controls | Security test |
| T-006 | Log or trace leaks message content/token | Allow-list logging, redaction, secret scanning | CI and runtime sampling |
| T-007 | Retry causes duplicate external effect | Idempotency and delivery ledger | Failure/retry test |
| T-008 | Privileged support access is abused | Just-in-time roles, approval, session recording/audit | Access review |
| T-009 | Backup access bypasses application authorization | Separate encryption and restricted identities | Restore/audit exercise |
| T-010 | Denial of service via joins, fan-out, or large payloads | Layered quotas, admission control, backpressure | Load and abuse testing |

Use a structured threat-analysis method during formal review and track each accepted risk to the risk register.
