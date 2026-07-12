# MVP Engineering Handoff

## Implemented vertical slice

- Local tenant bootstrap and password authentication
- Rotating refresh sessions and signed short-lived access tokens
- Tenant-scoped users, devices, conversations, and memberships
- Durable ordered and idempotent messages
- Message history replay, edits, deletion tombstones, reactions, and search
- Read cursors, presence, typing events, and Phoenix Channels
- Direct attachment upload intents for S3-compatible object storage
- React/TypeScript reference client
- Podman Compose local environment
- Kubernetes-neutral Kustomize staging overlay
- Sessionless, idempotent release bootstrap Job with an ephemeral owner Secret
- Isolated PostgreSQL and MinIO restore-verification and manifest-based rollback procedures
- Dependency-free staging acceptance for auth, realtime idempotency/replay, the 25 MB attachment ceiling, and revocation
- A kind-based local staging proof overlay for TLS, ingress, DNS, migration, rotation, restore, and rollback rehearsal
- CI for backend, web, contracts, Kubernetes rendering, OCI build, and release

## Intentional production gates

- Replace in-cluster PostgreSQL and MinIO for production or formally accept their operations model.
- Add a real notification provider and its credentials.
- Add webhook endpoint persistence and tenant management UI.
- Complete moderation workflows and abuse automation.
- Integrate malware scanning and quarantine before attachments are approved for production download.
- Run representative load, reconnect-storm, backup/restore, and failover tests.
- Provision TLS through the selected cluster certificate mechanism.
- Complete independent security review and production readiness review.

The attachment completion endpoint verifies that the object exists, its stored
size matches the accepted intent, and its SHA-256 metadata matches the accepted
client checksum when one was supplied. This is an MVP integrity check, not a
server-side content digest or malware verdict.

## First developer command

```bash
cp .env.example .env
make bootstrap
make dev
```

Open `http://localhost:5173`, choose **Create development workspace**, and use a
password of at least twelve characters.
