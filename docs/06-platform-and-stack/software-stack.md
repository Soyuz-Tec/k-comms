# Proposed Software Stack

**Status:** Draft; exact supported versions must be selected and pinned during implementation.

| Layer | Proposed technology | Purpose | Decision status |
|---|---|---|---|
| Runtime | Erlang/OTP and Elixir | Concurrency, supervision, distribution, application runtime | Proposed |
| Web/API | Phoenix | HTTP endpoints, WebSockets, routing, endpoint lifecycle | Proposed |
| Realtime | Phoenix Channels, PubSub, Presence | Connections, topic fan-out, ephemeral online state | Proposed |
| Persistence | Ecto and PostgreSQL | Transactional authoritative data | Proposed |
| Background work | Oban or equivalent PostgreSQL-backed job system | Durable retryable work | Proposed |
| HTTP server | Bandit or Cowboy through Phoenix | HTTP/WebSocket transport | Benchmark decision |
| Binary storage | S3-compatible object storage plus CDN | Attachments and generated variants | Proposed |
| Search | PostgreSQL FTS initially; OpenSearch-compatible service later | Authorized search projection | Conditional |
| Cache | ETS for bounded local caches; Redis only for justified shared semantics | Performance optimization | Conditional |
| Identity | OIDC; SAML/SCIM for enterprise | Authentication and provisioning | Proposed |
| Telemetry | OpenTelemetry, Prometheus-compatible metrics, centralized logs | Tracing, metrics, logs | Proposed |
| Packaging | OCI containers and Elixir releases | Repeatable deployment | Proposed |
| Orchestration | Kubernetes or managed container runtime | Scheduling, scaling, health, rollout | ADR required |
| Infrastructure | Terraform-compatible IaC | Repeatable environments | Proposed |
| CI/CD | Hosted CI plus artifact registry and policy gates | Build, test, scan, deploy | Provider decision |

## Selection criteria

- Operational maturity and team competence
- Failure semantics and data guarantees
- Horizontal scaling characteristics
- Security update cadence
- Licensing and commercial support
- Observability and testability
- Exit cost and data portability

Avoid adding a distributed component when PostgreSQL, BEAM processes, or object storage already satisfy the measured requirement.
