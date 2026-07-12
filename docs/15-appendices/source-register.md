# Source and Evidence Register

Track authoritative references used to approve decisions.

| ID | Source | Area supported | Version/date | Owner | Notes |
|---|---|---|---|---|---|
| SRC-001 | Erlang/OTP official documentation | Supervision, runtime behavior | OTP 29.0 release pin | Architecture | Matches CI and OCI build runtime |
| SRC-002 | Elixir official documentation | Language and release behavior | Elixir 1.20.1 release pin | Architecture | Matches CI and OCI build runtime |
| SRC-003 | Phoenix official documentation | Channels, PubSub, Presence | Phoenix 1.8.9 dependency pin | Realtime | Protocol behavior is additionally fixed by AsyncAPI and replay tests |
| SRC-004 | PostgreSQL official documentation | Transactions, advisory locks, recovery | PostgreSQL 17.10 staging pin | Data | Production managed-service minor updates remain provider controlled |
| SRC-005 | OWASP ASVS and API Security guidance | Authentication and trust-boundary controls | ASVS 5.0.0; API Security Top 10 (2023) | Security | Repository threat model, tests, and ADRs are the release-specific evidence |

Prefer primary standards, official project documentation, peer-reviewed publications, and tested internal evidence. Record benchmark scripts and reports as versioned evidence.
