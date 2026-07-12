# Security Control Matrix

| Control area | Objective | Proposed implementation | Evidence | Owner | Status |
|---|---|---|---|---|---|
| Authentication | Verify user/device identity | OIDC, MFA/passkeys option, short-lived access tokens, refresh rotation | Auth test suite and IdP config | Identity | Draft |
| Authorization | Prevent unauthorized operations | Tenant context, policy module, per-command membership checks | Negative tests and code review | Domain/Security | Draft |
| Tenant isolation | Prevent cross-tenant data access | Scoped queries, composite constraints, optional RLS, storage prefixes | Isolation test pack | Data/Security | Draft |
| Encryption in transit | Protect network data | TLS externally and internally where applicable | Scanner/config evidence | Platform | Draft |
| Encryption at rest | Protect stored data and backups | Managed database/storage encryption and key policy | Cloud/KMS evidence | Platform/Security | Draft |
| Secret management | Prevent secret disclosure | Managed secret store, rotation, no image/source embedding | Rotation test | Platform | Draft |
| Audit | Record privileged and security-relevant actions | Append-oriented audit events and restricted access | Audit queries and retention | Compliance | Draft |
| Abuse prevention | Bound malicious/accidental load | IP/user/device/tenant quotas and payload limits | Abuse/load tests | Security/SRE | Draft |
| Secure delivery | Detect vulnerable code/artifacts | SAST, dependency, secret, image, and IaC scanning | CI reports | AppSec | Draft |
| Incident response | Contain and learn from events | Security runbooks, evidence preservation, notification workflow | Exercise report | Security | Draft |
