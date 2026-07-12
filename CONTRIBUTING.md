# Contributing to K-Comms

1. Reference an issue for non-trivial work.
2. Branch from `main` and keep the change focused.
3. Update tests, contracts, migrations, docs, and ADRs with implementation.
4. Run `make check`, `make contracts`, and `make docs-check`.
5. Open a pull request using the repository template.

Domain code must not depend on Phoenix controllers, socket structs, provider
SDK models, or deployment-specific configuration. Every tenant-owned query,
job, object key, metric, and log context must carry explicit tenant scope.
Durable work is acknowledged only after its authoritative transaction commits.
