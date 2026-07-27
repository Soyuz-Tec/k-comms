# K-Comms

K-Comms is a multi-tenant real-time communication platform built with
Erlang/OTP, Elixir, Phoenix, PostgreSQL, React/TypeScript, durable background
jobs, and S3-compatible object storage.

The repository is qualified as a single-host local-staging package. It is not
production qualified: real providers, managed state, multi-zone recovery,
independent security evidence, support/on-call, compliance, licensing, image
attestation verification, and provider approval remain explicit launch gates.

## Implemented 0.3.0 platform

- Password sign-in and recovery, profiles, devices, session rotation, and revocation
- Tenant invitations, lifecycle controls, scoped roles, admission quotas, and last-owner safety
- Direct messages, private groups, public channels, memberships, and service-account participants
- Ordered/idempotent messaging, reconnect replay, history paging, search, drafts, edits, tombstones, reactions, read state, replies, threads, and mentions
- One-to-one, group, and channel audio/video calls with explicit camera and microphone consent, responsive participant grid, screen sharing, device controls, short-lived source-restricted provider grants, and durable participant eviction after access changes
- Phoenix Channels, Presence, typing state, inactive-conversation notifications, and durable in-app notification state
- Version-bound S3-compatible attachment upload/download, checksum verification, malware scanning, quarantine, and safe deletion
- Moderation cases and actions, retention policies, legal holds, deletion requests, audit evidence, and bounded neutralized CSV export
- Per-device browser push subscriptions, notification preferences, hardened webhooks, and scoped rotating service-account credentials
- Separate responsive and accessible React/TypeScript user (`/app`), tenant-admin (`/admin`), and content-blind platform-operations (`/ops`) interfaces
- Kubernetes-neutral staging and production overlays with migrations, bootstrap, TLS ingress, policies, disruption budgets, autoscaling, metrics, alerts, backup/restore, rollback, and local qualification runners
- Revision-bound release-evidence collection that binds clean Git state, OCI metadata, deployed Kubernetes topology, and hashed qualification files without retaining secrets or evidence contents
- Backend, browser, contract, documentation, release, manifest, container, security, load, and runtime acceptance gates

SIP, recording, transcription, media egress, and true end-to-end encryption are
explicitly deferred from this MVP.
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
- LiveKit signaling health: `http://localhost:7880`
- MinIO console: `http://localhost:9001`

The first local user is created through the client’s **Create development
workspace** form. Bootstrap is disabled by default in production.

### Local recovery and Windows logon start

The long-running Compose services use `restart: unless-stopped`, so Podman
restarts them after an unexpected process exit. On the Windows Podman machine,
enable Podman's boot-time restart service once and register the current-user
logon task:

```powershell
podman machine ssh systemctl --user enable podman-restart.service
powershell -ExecutionPolicy Bypass -File scripts/register_k_comms_autostart.ps1
```

The task waits 90 seconds after logon to avoid racing other Podman workloads,
starts the Podman machine if necessary, reconciles existing Compose images
without rebuilding them, and waits for API readiness, the web client, and the
local LiveKit media plane.
Windows retries a failed task three times at one-minute intervals. Its log is
written to `%LOCALAPPDATA%\K-Comms\autostart.log`. The same recovery can be run
manually:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/start_local_stack.ps1
```

### Immutable packaged local release

The release-qualified local path builds the exact clean Git revision into the
Dockerfile `runtime` target, serves the packaged client from Phoenix, runs
forward migrations, records image/configuration evidence, and retains the
previous application image for rollback. It uses a separate Compose project,
ports, and data volumes, so it does not disrupt the development stack:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Validate
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Deploy
```

Open `http://127.0.0.1:4188/app/`. Use `-Action Status`, `-Action Stop`, or
`-Action Rollback` for the remaining lifecycle operations. Rollback restores
the prior application/configuration and never runs a down migration. See the
[immutable local release runbook](docs/10-infrastructure-and-deployment/local-release-qualification.md).

For a controlled same-LAN media pilot, the explicit
`cloudflare_trusted_edge` profile serves the UI/API at
`https://comms.avayaworks.com`, LiveKit signaling at
`wss://media.avayaworks.com`, and browser object traffic at
`https://kcomms-files.avayaworks.com` through loopback-only Cloudflare Tunnel
origins. Only LiveKit ICE `7981/TCP` and `7982/UDP` are exposed on the selected
LAN media address. The tunnel service and its credentials remain outside this
repository and outside the release manager.

Trusted-edge deployments require a schema-v7 receipt. The manager records
`trustedProxySourceKind=podman-app-self-v1`, seals the exact isolated Podman
bridge name, ID, subnet, gateway, prefix, and reserved application IPv4/CIDR,
then trusts only that application `/32`. It creates the application stopped,
reconnects it with the sealed address request, verifies its ownership, image,
network identity, and aliases, and starts that same container without
recreation. Windows Podman assigns and exposes the requested address only at
start, so startup is the atomic collision gate and the manager immediately
verifies the running prefix/address. `Start` and `Rollback` replay and verify
the same reservation or fail closed; a
schema-v6 trusted-edge receipt must be redeployed before it can be activated.
Because that unsafe gateway-trust release cannot be an automatic rollback
target, its one supported upgrade is an explicitly acknowledged, irreversible
clean cutover to v7 under the **same** state root and Compose project. Reusing
both preserves the stable encryption/authentication secrets and the owned
PostgreSQL and MinIO volumes. Run `Stop`, prove a usable backup/restore path or
explicitly accept the migration risk, then deploy with
`-Schema6CutoverConfirmation schema6-irrevocable-cutover-data-risk-v1`.
The manager proves all project containers and the receipt-bound media
forwarder are stopped, the supervisor is absent, the stable environment is
unchanged, and both data volumes remain exclusively project-owned before any
candidate mutation. The resulting v7 receipt has no v6 rollback link. If the
candidate fails, its runtime is removed while the stable secrets, volumes, and
v6 audit pointer remain. The manager then recreates only the exact retained v6
application from its sealed environment, Compose source, image, and project,
using `--no-start`, and proves that stopped container as the non-activating
audit anchor before sealing failure evidence. The obsolete v6 release is never
reactivated. `Stop` is the only other schema-v6 trusted-edge lifecycle action
and never resolves or trusts the obsolete peer. After an irreversible candidate
failure, repeating `Stop` is idempotent through that exact stopped audit anchor:
it validates the current v6 receipt and retained assets, re-proves complete
quiescence, and does not start containers or rewrite the v6 audit pointer. A
missing anchor fails closed.

A separate recovery token exists only for the rare case where the first-ever
candidate failed and no `current.json` was published. Reuse the same state root
and Compose project, correct the candidate, and append
`-FailedFirstCandidateRetryConfirmation failed-first-candidate-retry-v1` to the
new `Deploy`. The token is accepted only after the manager proves that no
published receipt or project container exists and that the retained
`failure.json`, stable environment, and immutable candidate files match their
recorded hashes. A failed candidate never retains the active receipt name
`deployment.json`: after complete cleanup, the manager hashes any unpublished
candidate receipt, atomically seals its intended `unpublished-deployment.json`
path and SHA-256 in `failure.json`, and then atomically renames the receipt.
An interruption before the rename leaves `deployment.json` in place so retry
fails closed. Otherwise, restore `current.json` from the exact healthy receipt
instead of retrying.

Direct loopback access remains a local-operator-trust path, not a shareable
trusted-edge origin.

This profile does not qualify remote media, TURN/TLS, or production use;
follow the trusted-edge deployment, rollback, and physical second-device gates
in the
[local release runbook](docs/10-infrastructure-and-deployment/local-release-qualification.md#trusted-httpswss-with-cloudflare-and-same-lan-media).

## Quality gates

```bash
make check
make web-check
make contracts
make docs-check
make qualification-script-tests
make compose-validate
make local-release-validate
make build
make kube-validate
```

`make kube-validate` renders every maintained overlay and operations bundle;
CI additionally applies strict pinned Kubernetes schemas. A provider-composed
production bundle must separately pass `make production-preflight
PRODUCTION_BUNDLE=/restricted/path/production.yaml`. The `release` target only
builds the OCI candidate; it does not promote or deploy it.

`make qualification-script-tests` also validates loopback-by-default Compose
exposure, operations assets, the pending internal-readiness ledger, and the
formal-study and internal-pilot scorers. Those checks prove that evidence can
be evaluated consistently; they do not create human approvals or provider
evidence.

Compose publishes PostgreSQL, MinIO, LiveKit, the API, and the Vite client on
`127.0.0.1` by default while preserving ports 5432, 9000/9001, 7880/7881 TCP,
7882 UDP, 4000, and 5173.
Set `K_COMMS_BIND_ADDRESS` only when another host must connect. For example,
`K_COMMS_BIND_ADDRESS=0.0.0.0` is an explicit LAN exposure opt-in and requires
trusted-network firewall controls plus replacement of every development
credential; it is never production configuration. Recreate existing Compose
containers after changing the bind address.

Local audio/video uses five-minute participant tokens and a 660-second minimum
participant-eviction enforcement horizon. K-Comms persists the opaque admitted
participant identity and authorization bindings, never the token. Access
changes commit even if LiveKit is unavailable; durable retries continue beyond
the horizon until removal succeeds at or after it.

The same-host Compose proof covers one-to-one and group audio/video signaling,
media, and screen-share behavior. It does not establish external WSS/HTTPS,
TURN/TLS, bandwidth, maximum group size, privacy approval, or production
incident readiness; those remain environment-specific promotion gates.

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

Local staging deliberately uses the `allow_all` development scanner and log
delivery adapters behind `ALLOW_DEVELOPMENT_ADAPTERS=true`; this proves the
workflow and degraded-state reporting, not real malware, email, push, or
webhook-provider behavior.

Main-branch publication runs retain a CycloneDX SBOM and create GitHub keyless
Sigstore-signed build-provenance and SBOM attestations for the immutable GHCR
digest. A manual `workflow_dispatch` publishes only when `main` is selected as
the run ref; dispatching another branch or tag skips the publication job.
Promotion must verify both predicates as documented in `ops/runtime/README.md`
and `docs/10-infrastructure-and-deployment/supply-chain-integrity.md`.

## Security and licensing

Never commit real secrets, TLS private keys, customer content, or production
data. Use private vulnerability reporting for security issues. License
selection is an explicit owner-controlled gate for external adoption,
redistribution, or public release; engineering agents and contributors must not
infer or choose one. See `LICENSE-DECISION.md`.
