# K-Comms

K-Comms is a development-ready foundation for a multi-tenant real-time
communications platform built with Erlang/OTP, Elixir, Phoenix, PostgreSQL,
durable background jobs, and S3-compatible object storage.

> **Maturity:** executable architecture bootstrap. The repository contains
> runnable application boundaries, database migrations, HTTP/WebSocket health
> foundations, API contracts, local infrastructure, CI, and the deployable
> engineering plan. Product authentication, production authorization policy,
> moderation, notification providers, and end-user clients remain planned work.

## Architecture baseline

- Modular Elixir umbrella with explicit core, web, worker, integration,
  observability, and test-support applications.
- PostgreSQL is authoritative for accepted messages, ordering, idempotency,
  memberships, outbox events, and audit history.
- Phoenix Channels, PubSub, and Presence provide real-time and ephemeral state.
- Oban provides durable PostgreSQL-backed background execution.
- S3-compatible storage holds attachments; MinIO supports local development.
- OpenAPI, AsyncAPI, and JSON Schema contracts are version controlled.
- Architecture, security, reliability, delivery, and operations live in `docs/`.

## Repository map

| Path | Purpose |
|---|---|
| `apps/comms_core` | Tenant-scoped domain rules, persistence, message acceptance, and authorization boundary |
| `apps/comms_web` | Phoenix HTTP API, WebSockets, Channels, Presence, and health endpoints |
| `apps/comms_workers` | Durable notifications, webhooks, outbox, and attachment-processing jobs |
| `apps/comms_integrations` | Fail-closed object-storage, notification, webhook, and identity adapters |
| `apps/comms_observability` | Telemetry event and runtime metadata conventions |
| `apps/comms_test_support` | Shared test IDs, factories, and helpers |
| `contracts` | Canonical OpenAPI, AsyncAPI, and JSON Schemas |
| `docs` | Deployable engineering plan and development guides |
| `infra` | Terraform module contracts and environment composition |
| `ops` | Alert rules, dashboards, container, and runtime guidance |
| `scripts` | Bootstrap and validation automation |

See [`DOCUMENTATION-MAP.md`](DOCUMENTATION-MAP.md) for the twelve engineering
plan outputs and their approval evidence.

## Quick start

Requirements: Git and Docker with Compose.

```bash
git clone https://github.com/Soyuz-Tec/k-comms.git
cd k-comms
cp .env.example .env
make bootstrap
make dev
```

Local endpoints:

- `GET http://localhost:4000/health/live`
- `GET http://localhost:4000/health/ready`
- `GET http://localhost:4000/api/v1/status`
- PostgreSQL: `localhost:5432`
- MinIO API: `localhost:9000`
- MinIO console: `localhost:9001`

Native BEAM development uses the versions in `.tool-versions`:

```bash
mix local.hex --force
mix local.rebar --force
mix setup
mix phx.server
```

## Quality gates

```bash
make check
make contracts
make docs-check
```

The initial adapters intentionally deny work until approved implementations are
configured. Do not weaken authentication, authorization, attachment signing, or
outbound delivery merely to make a demonstration pass.

No redistribution license has been granted yet. See
[`LICENSE-DECISION.md`](LICENSE-DECISION.md).
