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

The pinned PostgreSQL image starts its entrypoint as root only long enough to
initialize/chown the managed volume and drop to its `postgres` user. Its
Quadlet therefore cannot set Linux `no-new-privileges`; a staging regression
test proved that doing so traps `gosu` before database startup. The application
retains read-only rootfs, dropped capabilities, and no-new-privileges controls.

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
