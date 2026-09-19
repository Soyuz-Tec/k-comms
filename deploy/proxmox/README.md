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
- generated service environments: `/etc/k-comms/service-env/current/*.env`
- current non-secret release identity: `/etc/k-comms/release.env`
- operator scripts: `/opt/k-comms/bin`
- immutable templates: `/opt/k-comms/templates`
- deployment receipts: `/var/lib/k-comms/receipts`
- backups: `/var/backups/k-comms`

`runtime.env` and the Cloudflare tunnel token are always mode `0600`, remain
outside Git, and are never included in receipts or logs.

Each container receives its own allowlisted environment. The root-owned source
remains the only configuration authority; generated directories are mode `0700`
and files are mode `0600`. `service-env.py` rejects unclassified/duplicate inputs,
placeholders, missing required values, unsafe permissions, and source symlinks.
It prepares the entire set before atomically switching the active generation.
Never edit derived files or print them into workflow logs. See ADR-0082.

Install requires Python 3. On an existing VM, ensure `python3` is available
before asset synchronization; missing dependencies fail before activation.
Successful deployment checks the actual application and sidecar environments.
Existing sidecars are restarted only when a mismatch requires it, after
quiescence and backup. Failed first-time upgrades may recover the old unit's
environment scope; that is failed-upgrade recovery, not successful isolation.

To verify files without displaying values, run on the authorized host:

```bash
sudo python3 /opt/k-comms/bin/service-env.py \
  --source /etc/k-comms/runtime.env \
  --destination /etc/k-comms/service-env --check
```

Application/sidecar credential values and database roles are unchanged. Equal
S3 application and MinIO administrator credentials still have equal privileges;
credential separation requires its own tested change. Restore the protected
source from a verified backup and let the restore command regenerate the files.

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

## Backup timing and local monitoring

`backup.sh` writes root-only `backup-<id>.json` and `backup-latest.json` in the
receipts directory. These record each phase, total elapsed time, result, and
failed phase. The nightly wrapper also writes `maintenance-<id>.json` and
`maintenance-latest.json`, measuring the stop request through verified recovery.
An unconfirmed stop has unknown outage duration; failed recovery leaves an open
interval. A failed backup remains a failed maintenance run after recovery.
Inspect these protected receipts to size a maintenance window from measurements.

The health timer now invokes `monitor.sh`, which runs full runtime verification
and checks backup freshness/completion, the preceding healthy observation,
available bytes, and free inodes for backups and both data volumes. Local state
is `/var/lib/k-comms/receipts/monitoring/monitor.json` (mode `0600` in a `0700`
directory). Storage indices `0`, `1`, and `2` denote backups, PostgreSQL, and
MinIO respectively. A stale backup, failed maintenance, low capacity, or failed
health/delivery check makes the systemd health service fail visibly.

Optional settings are shown in `monitoring.json.example`. Install an explicitly
reviewed copy at `/etc/k-comms/monitoring.json`, owned by root, mode `0600`.
Defaults enable local checks only. Keep `alerts_enabled` and `deadman_enabled`
false until an authorized receiver and escalation owner exist. For delivery,
set `hook_path` to a root-owned mode `0700` executable in protected directories.
The hook reads one JSON event from stdin (`alert`, `recovery`, or `heartbeat`),
must return within 10 seconds, and receives only `PATH` and `LANG`; credentials
belong in its own protected configuration. Its output is suppressed. Do not
embed receiver credentials in repository files or operational receipts.

Qualify alert and recovery receipt delivery with synthetic events, then stop a
synthetic staging heartbeat to prove the external deadman detects silence.
Record the receiver acknowledgment and response owner before claiming working
alert delivery. Planned backup interruption can produce health alerts. Hooks
are never invoked with the default settings, and no receiver is provisioned by
this bundle.

Local monitoring does not provide off-host backups or PostgreSQL PITR. A host
failure requires an external receiver to detect silence and an independent
backup copy to recover. Backup freshness checks do not reread all archive data
each minute; retain checksum verification and staging restore rehearsal.

## Protected GitHub delivery

The reusable `Deploy Proxmox` workflow uses the protected `staging` or
`production` GitHub environment; its manual form offers staging only.
Each environment must define:

- variables `K_COMMS_DEPLOY_HOST` and `K_COMMS_DEPLOY_USER`;
- secrets `K_COMMS_DEPLOY_SSH_KEY` and `K_COMMS_DEPLOY_HOST_KEY`; and
- a protected-branch deployment policy.

Production additionally requires an environment approval. The deploy job runs
only on a persistent Windows or Linux self-hosted runner carrying the
`k-comms-deploy` label. The host must provide PowerShell 7, OpenSSH clients,
and `tar`. Keep that runner registered only to this repository, run it as a
least-privilege account, restrict its installation and work directories to
that account plus the operating-system administrator, and confirm it is online
before promotion. On Windows, temporary protected files use an explicit ACL;
on Linux they use mode `0600`. Artifact provenance and SBOM verification stay
on a GitHub-hosted runner before the protected environment releases any SSH
material to the deployment job.

Each environment also defines the secret
`K_COMMS_LIVEKIT_CLOUD_CREDENTIAL` as one JSON object with exactly `url`,
`apiKey`, and `apiSecret`. Staging and production use different LiveKit
projects and keys. The workflow validates the value without printing it,
restricts the temporary file ACL, transfers it with mode `0600`, and deletes
the runner and VM copies after deployment.

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

Use the repository-wide
[development-to-production completion standard](../../docs/14-operations/development-to-production-completion-standard.md)
after every completed runtime feature or update. The sequence below is the
Proxmox implementation of that standard.

1. Merge a reviewed PR into protected `main`.
2. Wait for CI and the Container workflow to pass.
3. The Container workflow records the registry digest, verifies both SLSA
   provenance and the CycloneDX SBOM attestation, and automatically queues the
   exact candidate for staging. Before host access, the latest main-push CI run
   for that exact SHA and all required CI jobs must pass. The initial gate
   waits at most 35 minutes; it cannot borrow another revision's green checks.
4. Staging deploys the digest, runs `verify.sh`, rehearses `rollback.sh`,
   reactivates the candidate, and runs an isolated restore rehearsal against
   the retained PostgreSQL and MinIO backup. It then requests a protected
   staging-only reboot and proves a changed boot ID, full application/PWA
   readiness, enabled and active health/backup timers, and actual restricted
   service container environments. Reconnect/recovery has a ten-minute overall
   deadline with bounded SSH child processes. Production is never rebooted by
   this qualification step.
5. The same workflow automatically queues production and waits until the
   required reviewer approves the protected GitHub `production` environment.
   Before approval and again before SSH access, it verifies that this Container
   run/attempt has a successful staging job and a SHA-256-verified staging
   artifact for the same revision and image digest, with complete backup and
   rollback/restore qualification and a reboot receipt for the current attempt.
   The qualification and its evidence capture
   must both be no older than 24 hours; stale host qualification repeats the
   rollback and restore rehearsal. Evidence captured more than 24 hours ago,
   incomplete CI, and missing or mismatched receipts block promotion.
6. Production rechecks protected `main`, takes a quiesced backup, and deploys
   the same digest qualified in staging.
7. The workflow retains non-secret deployment evidence and verifies the public
   application, media, and object-storage endpoints.

For this VM, the one-time legacy adoption above must already have completed.
Normal production deployments never create a new authoritative volume and do
not need an adoption flag.

Reboot proof is recorded at `/var/lib/k-comms/receipts/staging-reboot.json` as a
root-only receipt with the exact image/revision, request ID, old/new kernel boot
IDs, verification timestamp, and readiness/timer/service-environment results.
Export also checks that the host is still on that verified boot. The staging
wrapper only accepts `192.168.1.23`; the root helper independently requires the
staging environment and bind address. Existing SSH keys/known-host pinning and
noninteractive sudo are retained. Missing permissions, failed scheduling,
unacknowledged requests, wrong identities, and timeouts fail closed. Investigate
the protected staging job/host before rerunning the full chain; the wrapper
never repeats a reboot request during reconnect. A full rerun creates a new
request and reboot proof even when rollback/restore qualification is reusable.

Manual `Deploy Proxmox` dispatch is staging-only. To recover or repeat a
production promotion, start the complete `Container` workflow on current
protected main, or rerun **all jobs** in its current release run. Rerunning only
the failed production job cannot reuse staging evidence from an older attempt.
The same independent production approval remains required. Artifact names
include the run attempt: `k-comms-staging-<revision>-attempt-<attempt>` and
`k-comms-production-<revision>-attempt-<attempt>`. The protected runner installs
Python 3.13 through the pinned setup action for the post-approval recheck.

The deploy script takes an application-consistent backup before replacing a
running application. It stops writers, verifies the PostgreSQL dump, snapshots
the stopped MinIO volume, runs forward-only migrations, renders the exact
digest into the application Quadlet, starts the service, and records a
non-secret receipt. Pre-migration failure restores and verifies the unchanged
previous application. A failed migration leaves writers stopped because it may
have committed earlier migration files. After a successful migration, failed
activation requires the communication rollback compatibility preflight before
restoring and verifying the previous application. Failed recovery remains
stopped; no down migration is attempted. Database recovery remains an explicit,
separately confirmed `restore.sh` operation.

Failed deployments retain a restricted configuration guard and `failure.txt`
under `/var/lib/k-comms/receipts/failed-deployments/`. The record identifies the
phase, original exit code, and whether the prior application was verified or
remains stopped. If that directory is unavailable, the original `/run` guard
is retained and its path is logged. The guard includes secrets: inspect it only
with operational authority, never upload it to GitHub/support artifacts, and
remove it through the approved restricted-evidence retention process after
recovery. Investigate failed/partial migrations and use a compatible
roll-forward or separately authorized restore before restarting writers.

Run `python scripts/test_proxmox_deploy_recovery.py` and
`python scripts/test_verify_release_gates.py` after release-safety changes.
These tests use isolated synthetic dependencies and do not access live hosts.
See [ADR-0080](../../docs/02-architecture/adr/0080-bind-release-promotion-and-failure-recovery.md).

`restore-rehearsal.sh` is staging-only. It verifies checksums and archive
readability, restores PostgreSQL into a temporary database, extracts the MinIO
snapshot into a temporary directory, validates both restored targets, records
a non-secret receipt, and removes the temporary targets. It never replaces the
active staging or production data.

Every protected deployment also applies the environment's managed LiveKit
credential transactionally. The candidate runtime uses the exact matching
`wss://<project>.livekit.cloud` and `https://<project>.livekit.cloud`
endpoints, records only `managed_cloud` in the non-secret receipt, and restores
the previous protected runtime file if activation fails. The LAN-only
self-hosted LiveKit Quadlet remains active as a rollback standby; no public
media port is opened on the VM.

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
