# K-Comms

K-Comms is a multi-tenant real-time communication platform built with
Erlang/OTP, Elixir, Phoenix, PostgreSQL, React/TypeScript, durable background
jobs, and S3-compatible object storage.

## Implemented 0.3.0 platform

- Password sign-in and recovery, profiles, devices, session rotation, and revocation
- Tenant invitations, lifecycle controls, scoped roles, admission quotas, and last-owner safety
- Direct messages, private groups, public channels, memberships, and service-account participants
- Ordered/idempotent messaging, reconnect replay, history paging, search, drafts, edits, tombstones, reactions, read state, replies, threads, and mentions
- Phoenix Channels, Presence, typing state, inactive-conversation notifications, and durable in-app notification state
- Version-bound S3-compatible attachment upload/download, checksum verification, malware scanning, quarantine, and safe deletion
- Moderation cases and actions, retention policies, legal holds, deletion requests, audit evidence, and bounded neutralized CSV export
- Per-device browser push subscriptions, notification preferences, hardened webhooks, and scoped rotating service-account credentials
- Separate responsive and accessible React/TypeScript user (`/app`), tenant-admin (`/admin`), and content-blind platform-operations (`/ops`) interfaces
- Kubernetes-neutral staging and production overlays with migrations, bootstrap, TLS ingress, policies, disruption budgets, autoscaling, metrics, alerts, backup/restore, rollback, and local qualification runners
- Backend, browser, contract, documentation, release, manifest, container, security, load, and runtime acceptance gates

Voice/video and true end-to-end encryption are explicitly deferred from this MVP.
Messages are server-readable for authorized search, moderation, notifications,
and multi-device recovery; TLS and encryption at rest are required.

## Repository map

| Path | Purpose |
|---|---|
| `apps/comms_core` | Authoritative identity, tenancy, conversations, messages, attachments, audit, and persistence |
| `apps/comms_web` | REST API, access tokens, Phoenix Channels, Presence, and static client delivery |
| `apps/comms_workers` | Durable outbox, notification, webhook, attachment, retention, and deletion workers |
| `apps/comms_integrations` | S3 signing, malware scanner, webhook delivery, push, and provider adapters |
| `clients/web` | React/TypeScript reference client |
| `contracts` | OpenAPI, AsyncAPI, and JSON Schema contracts |
| `deploy/k8s` | Kubernetes-neutral Kustomize base, staging/production overlays, and controlled operations jobs |
| `docs` | Architecture, security, reliability, testing, delivery, and operations plan |
| `ops` | Alert, dashboard, and MinIO development assets |

## Local development with Podman

Requirements: Podman, a Compose provider available through `podman compose`,
Git, and Python 3.

```bash
git clone https://github.com/Soyuz-Tec/k-comms.git
cd k-comms
cp .env.example .env
make bootstrap
make dev
```

Open:

- Web client: `http://localhost:5173`
- API: `http://localhost:4000/api/v1/status`
- Health: `http://localhost:4000/health/ready`
- MinIO console: `http://localhost:9001`

The first local user is created through the client’s **Create development
workspace** form. Bootstrap is disabled by default in production.

## Quality gates

```bash
make check
make build
make kube-validate
```

## Staging deployment

```bash
cp deploy/k8s/overlays/staging/secrets.env.example \
  deploy/k8s/overlays/staging/secrets.env
cp deploy/k8s/overlays/staging/bootstrap-secrets.env.example \
  deploy/k8s/overlays/staging/bootstrap-secrets.env
python scripts/validate_staging_secrets.py \
  deploy/k8s/overlays/staging/secrets.env \
  deploy/k8s/overlays/staging/bootstrap-secrets.env
```

The staging overlay is portable and intentionally includes single-node
PostgreSQL and MinIO. Replace them with an approved production data-services
overlay before launch. Do not apply the abbreviated example directly: follow
the ordered [staging runbook](deploy/k8s/overlays/staging/README.md) for image
pinning, migration, bootstrap, backup/restore verification, qualification,
deployment, and rollback. See
also `docs/12-development-guides/mvp-handoff.md` and
`docs/09-security-and-compliance/tls-pki-certificate-lifecycle.md`.

## Security and licensing

Never commit real secrets, TLS private keys, customer content, or production
data. Use private vulnerability reporting for security issues. License
selection is an explicit owner-controlled gate for external adoption,
redistribution, or public release; engineering agents and contributors must not
infer or choose one. See `LICENSE-DECISION.md`.
