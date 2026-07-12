# Dependency Policy

## Admission criteria

A dependency must have:

- A documented owner and business/technical purpose.
- Compatible licensing.
- A maintained release and security posture.
- A bounded integration surface and removal strategy.
- Tests for failure, timeout, and unavailable-provider behavior.
- Version pinning through the language or infrastructure lock mechanism.

## Rules

- No direct dependency on another domain's internal modules.
- Wrap provider SDKs behind application-owned adapters.
- Track transitive vulnerabilities and license obligations.
- Prefer standard protocols over proprietary data lock-in.
- Review high-risk dependencies quarterly.
