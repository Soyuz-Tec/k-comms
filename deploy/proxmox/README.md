# Proxmox Podman deployment

This package is the repository-owned deployment contract for dedicated Debian
VMs on Proxmox VE. It keeps Proxmox as the virtualization boundary, runs
rootful Podman Quadlets inside each VM, and promotes only the immutable GHCR
digest published and attested by `.github/workflows/container.yml`.

## Environment boundaries

| Environment | VM | Address | Public ingress | Data policy |
|---|---:|---|---|---|
| staging | 101 | `192.168.1.23` | LAN-only | synthetic data only |
| production | 100 | `192.168.1.22` | Cloudflare Tunnel | authoritative data |

The management interface at `192.168.1.21:8006`, PostgreSQL, the MinIO console,
and the Podman API are never public routes. Production application, signaling,
and object ports stay on loopback for `cloudflared`. LiveKit ICE is restricted
to TCP `7981` and UDP `7982` from `192.168.1.0/24`. Staging exposes its
application, signaling, object API, and ICE ports only to the same LAN.

## Files installed in each VM

- Quadlets: `/etc/containers/systemd/k-comms-*`
- protected runtime configuration: `/etc/k-comms/runtime.env`
- current non-secret release identity: `/etc/k-comms/release.env`
- operator scripts: `/opt/k-comms/bin`
- immutable templates: `/opt/k-comms/templates`
- deployment receipts: `/var/lib/k-comms/receipts`
- backups: `/var/backups/k-comms`

`runtime.env` and the Cloudflare tunnel token are always mode `0600`, remain
outside Git, and are never included in receipts or logs.

The protected `/etc/k-comms/environment` file also records the storage
identity. Fresh staging uses `k-comms-postgres-data` and
`k-comms-minio-data`. Production is explicitly marked `adopted` and names its
pre-existing authoritative volumes. A production deploy refuses to start if
either volume is absent, lacks its PostgreSQL or MinIO format marker, or is
still mounted by a running legacy container.

Network identity is equally explicit. Staging uses `10.89.0.0/24`; the
Compose-era production network already owns that subnet, so the managed
production Quadlet network uses the independently verified
`10.90.0.0/24`. The firewall DNS allowance is rendered from the same protected
subnet and gateway values. Adoption refuses to proceed if that dedicated
subnet is already present in an unrelated route or Podman network.

The pinned PostgreSQL image starts its entrypoint as root only long enough to
initialize/chown the managed volume and drop to its `postgres` user. Its
Quadlet therefore cannot set Linux `no-new-privileges`; a staging regression
test proved that doing so traps `gosu` before database startup. The application
retains read-only rootfs, dropped capabilities, and no-new-privileges controls.

## Protected GitHub delivery

The manual `Deploy Proxmox` workflow uses the protected `staging` or
`production` GitHub environment. Each environment must define:

- variables `K_COMMS_DEPLOY_HOST` and `K_COMMS_DEPLOY_USER`;
- secrets `K_COMMS_DEPLOY_SSH_KEY` and `K_COMMS_DEPLOY_HOST_KEY`; and
- a protected-branch deployment policy.

Production additionally requires an environment approval. The deploy job runs
only on a persistent Windows self-hosted runner carrying the
`k-comms-deploy` label. Keep that runner registered to this repository, run it
as a least-privilege account, restrict its installation directory to that
account and `SYSTEM`, and confirm it is online before promotion. Artifact
provenance and SBOM verification stay on a GitHub-hosted runner before the
protected environment releases any SSH material to the deployment job.

## Initial VM installation

On a fresh dedicated Debian VM:

1. Copy this directory to `/tmp/k-comms-proxmox`.
2. Generate or install `/etc/k-comms/runtime.env` from
   `runtime.env.example`.
3. Run:

   ```bash
   sudo ./bin/install.sh \
     --environment staging \
     --bind-address 192.168.1.23 \
     --media-address 192.168.1.23
   ```

4. Deploy an attested image digest:

   ```bash
   sudo /opt/k-comms/bin/deploy.sh \
     --environment staging \
     --image ghcr.io/soyuz-tec/k-comms@sha256:<digest> \
     --revision <40-character-main-commit> \
     --bootstrap
   ```

Production uses `127.0.0.1` for the application, signaling, and object bind
address and `192.168.1.22` for LiveKit ICE.

## One-time legacy production adoption

The current production VM was originally installed as the
`k-comms-release` Compose project. Before the next application update, migrate
service ownership to the reviewed Quadlets without copying, renaming, or
reinitializing its authoritative volumes:

```bash
sudo ./bin/adopt-legacy-production.sh \
  --runtime-source /opt/k-comms/release.env \
  --confirmation adopt-k-comms-production-v1
```

The adoption gate proves the legacy containers are healthy, proves their exact
volume mounts and on-disk format markers, converts the existing protected
configuration without printing secrets, and stages all host assets without
activating them. It then stops writers, creates a PostgreSQL logical dump and
stopped MinIO snapshot, disables the legacy service, starts the same
application image under Quadlets, and runs production verification. If any
activation gate fails, the new units are stopped and the retained legacy
service is restarted automatically.

The transaction also changes each retained legacy container restart policy to
`no` after it is stopped. This prevents Podman's boot-time restart service from
starting a legacy database or object store independently of the disabled
legacy systemd unit. It also disables the legacy TCP and UDP media helper
units, whose dependency on the legacy application unit could otherwise
reactivate that stack during boot. A failed adoption restores every
container's original restart policy, the legacy application service, and both
media helpers.

For production, the transaction starts the installed Cloudflare connector
after the candidate app service and before verification. The fallback path
also starts the connector after restoring the legacy service, so an application
activation failure does not leave public ingress offline.

The connector's systemd lifecycle remains independent from the application
unit. It stays available across application restarts and cutovers, while
`verify.sh` still requires both the connector and the selected application
origin to be active and ready before adoption or deployment succeeds.
Both initial installation and every reviewed asset synchronization install
this connector unit explicitly; it is intentionally outside the
`k-comms-*` systemd filename glob.

The host contract also persists `net.core.rmem_max=5000000` under
`/etc/sysctl.d` and applies it during installation and asset synchronization.
This matches the minimum production receive-buffer ceiling reported by the
pinned LiveKit server. Production verification fails if the effective value
is lower.

The protected configuration conversion accounts for the Compose-to-Podman
environment-file parsing boundary. It removes only optional outer double
quotes from `CSP_CONNECT_SOURCES`, then requires the normalized value to be
exactly `'self'`, `LIVEKIT_SERVER_URL`, and `S3_PUBLIC_ENDPOINT` before any
cutover.

Before the maintenance action, the same gate can be exercised read-only by
adding `--preflight-only`; it exits before creating or changing any file,
service, firewall rule, container, or volume.

The operation records a `k-comms-legacy-adoption-receipt-v1` receipt and keeps
the stopped legacy containers plus their local image for the first-update
rollback seam. Do not delete that image until a later production deployment
and rollback rehearsal have both succeeded. The application image and source
revision do not change during adoption. The receipt records that independent
legacy-container restart has been suppressed and the legacy media helpers have
been disabled.

Until that first digest promotion, `verify.sh` accepts the retained local image
only for the production VM with `adopted` storage and only when its OCI source
and full revision labels match this repository and the installed release
identity. Staging and normal production deployment inputs remain immutable
GHCR digests.

## Promotion sequence

1. Merge a reviewed PR into protected `main`.
2. Wait for CI and the Container workflow to pass.
3. Copy the registry digest from the successful publication job.
4. Verify both SLSA provenance and the CycloneDX SBOM attestation.
5. Deploy the digest to staging and run `verify.sh`.
6. Rehearse `rollback.sh` and an isolated `restore.sh`.
7. Approve the protected GitHub `production` environment.
8. Deploy the same digest to production.
9. Retain the deployment receipt, backup manifest, and post-deploy evidence.

For this VM, the one-time legacy adoption above must already have completed.
Normal production deployments never create a new authoritative volume and do
not need an adoption flag.

The deploy script takes an application-consistent backup before replacing a
running application. It stops writers, verifies the PostgreSQL dump, snapshots
the stopped MinIO volume, runs forward-only migrations, renders the exact
digest into the application Quadlet, starts the service, and records a
non-secret receipt. A failed health gate restores the previous application
Quadlet. Database recovery remains an explicit, separately confirmed
`restore.sh` operation.

## Rollback rules

- `rollback.sh` changes only the application image and runs the repository's
  communication compatibility preflight before activation.
- It never applies a down migration.
- `restore.sh` requires the exact confirmation
  `restore-k-comms-backup-v1`, an intact `COMPLETE` marker, and matching
  SHA-256 manifest.
- Proxmox VM backups complement these application backups; they do not replace
  PostgreSQL and object-storage recovery evidence.

## Availability boundary

This package makes one VM reproducible and recoverable. It does not make a
single Proxmox host or a single PostgreSQL instance highly available. A second
production origin, independent backup target, PostgreSQL PITR archive, and a
second `cloudflared` replica remain the next availability increment.
