# Security Policy

K-Comms is pre-production and security fixes target `main`. Report suspected
vulnerabilities through GitHub private vulnerability reporting, not public
issues. Never include real credentials, customer content, or production data.

Baseline controls:

- Authentication and authorization fail closed.
- Tenant and actor context are explicit on all protected commands.
- PostgreSQL is authoritative for acknowledged message state.
- Logs exclude message bodies, credentials, tokens, and signed object URLs.
- External delivery and background jobs are retry-bounded and idempotent.
- Secrets enter through runtime configuration or a managed secret store.

See `docs/09-security-and-compliance/` for the threat model and control matrix.
