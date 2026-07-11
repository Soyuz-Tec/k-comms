# K-Comms

A development-ready foundation for a multi-tenant real-time communication
platform built with Erlang/OTP, Elixir, Phoenix, PostgreSQL, durable background
work, and S3-compatible object storage.

> **Status:** architecture/bootstrap. The repository contains executable
> scaffolding and an extensive deployable engineering plan; it is not yet a
> production-ready communication service.

## Architecture baseline

- Modular Elixir umbrella with explicit domain, edge, worker, integration, and observability applications.
- PostgreSQL as the authoritative store for accepted messages and membership state.
- Phoenix Channels, PubSub, and Presence for real-time and ephemeral behavior.
- Oban-backed durable jobs for notifications, webhooks, projections, and outbox processing.
- S3-compatible object storage for attachments; MinIO is provided for local development.
- Versioned OpenAPI, AsyncAPI, and JSON Schema contracts.
- Separate release roles for all-in-one, edge, and worker deployments.

## Repository map

| Path | Purpose |
|---|---|
| `apps/comms_core` | Tenant, identity, conversation, message, and persistence rules |
| `apps/comms_web` | Phoenix HTTP, WebSocket, channel, presence, and health edge |
| `apps/comms_workers` | Durable jobs, projections, notifications, and outbox processing |
| `apps/comms_integrations` | Object storage, identity, push, email, and webhook adapters |
| `apps/comms_observability` | Telemetry conventions and metric definitions |
| `apps/comms_test_support` | Factories, fakes, deterministic clocks, and failure tools |
| `contracts` | Canonical machine-readable API and event contracts |
| `docs` | Architecture, data, delivery, security, reliability, and operating plan |
| `infra` | Terraform module and environment boundaries |
| `ops` | Machine-consumed dashboards, alerts, and runtime assets |
| `scripts` | Bootstrap and validation automation |

See [`DOCUMENTATION-MAP.md`](DOCUMENTATION-MAP.md) for the engineering-plan reading order.

## Quick start

Requirements: Docker with Compose and Git.

```bash
git clone https://github.com/Soyuz-Tec/k-comms.git
cd k-comms
cp .env.example .env
make bootstrap
make dev
```

Endpoints after startup:

- `GET http://localhost:4000/health/live`
- `GET http://localhost:4000/health/ready`
- `GET http://localhost:4000/api/v1/status`
- MinIO API: `http://localhost:9000`
- MinIO console: `http://localhost:9001`

## Quality gate

```bash
make check
make contracts
python3 scripts/validate_docs.py
```

CI additionally compiles a production release and container. The dependency
lockfile must be generated and committed from the first successful BEAM-enabled
bootstrap before any release is tagged.

## Intentional fail-closed boundaries

Authentication, conversation authorization, notification delivery, object
storage signing, and the transactional message command are represented by
contracts that currently reject work. Implement them through reviewed issues
and ADRs rather than weakening the defaults.

## Key decisions still required

- Product scope and target capacity
- End-to-end encryption model
- Voice/video and WebRTC media plane
- Cloud provider and runtime orchestrator
- Multi-region ownership and failover
- Identity providers and enterprise provisioning
- Licensing model for source redistribution and commercial use

## Contributing and security

Read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`GOVERNANCE.md`](GOVERNANCE.md),
and [`SECURITY.md`](SECURITY.md). Never place secrets, customer content, or
production data in issues, commits, tests, or documentation.
