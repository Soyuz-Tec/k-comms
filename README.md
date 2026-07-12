# K-Comms

K-Comms is a multi-tenant real-time communication-platform MVP built with
Erlang/OTP, Elixir, Phoenix, PostgreSQL, React/TypeScript, durable background
jobs, and S3-compatible object storage.

## Implemented MVP

- Workspace bootstrap, password authentication, device sessions, refresh rotation, and revocation
- Tenant-scoped users, roles, conversations, and memberships
- Ordered/idempotent durable messaging, history replay, edits, deletion tombstones, reactions, and replies
- Phoenix Channels, Presence, typing events, reconnect replay, and read cursors
- PostgreSQL full-text message search constrained by active membership
- Attachment metadata and signed direct upload/download URLs for MinIO or another S3-compatible service
- React/TypeScript reference web client
- Podman-first local development and OCI builds
- Kubernetes-neutral Kustomize staging package
- Backend, web, contract, release, Kubernetes, and container CI gates

Voice/video and true end-to-end encryption are explicitly deferred from this MVP.
Messages are server-readable for authorized search, moderation, notifications,
and multi-device recovery; TLS and encryption at rest are required.

## Repository map

| Path | Purpose |
|---|---|
| `apps/comms_core` | Authoritative identity, tenancy, conversations, messages, attachments, audit, and persistence |
| `apps/comms_web` | REST API, access tokens, Phoenix Channels, Presence, and static client delivery |
| `apps/comms_workers` | Durable outbox, notification, webhook, and attachment workers |
| `apps/comms_integrations` | S3 signing, webhook delivery, and provider adapters |
| `clients/web` | React/TypeScript reference client |
| `contracts` | OpenAPI, AsyncAPI, and JSON Schema contracts |
| `deploy/k8s` | Kubernetes-neutral Kustomize base and staging overlay |
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
pinning, bootstrap, backup/restore verification, deployment, and rollback. See
also `docs/12-development-guides/mvp-handoff.md` and
`docs/09-security-and-compliance/tls-pki-certificate-lifecycle.md`.

## Security and licensing

Never commit real secrets, TLS private keys, customer content, or production
data. Use private vulnerability reporting for security issues. No redistribution
license has been selected; see `LICENSE-DECISION.md`.
