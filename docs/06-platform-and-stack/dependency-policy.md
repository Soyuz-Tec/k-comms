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

## Product SDK register

| Dependency | Purpose and owner | Version/license | Boundary and removal strategy |
|---|---|---|---|
| `@excalidraw/excalidraw` | Conversation whiteboard editor; Collaboration/Web | Exact 0.18.1, MIT; notice in `THIRD_PARTY_NOTICES.md` | Lazy React adapter only; K-Comms owns persistence, authorization, realtime, and projection, so the editor can be replaced without changing the server contract |
