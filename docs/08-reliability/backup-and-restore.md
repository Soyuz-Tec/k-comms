# Backup and Restore

- Enable continuous database recovery or equivalent point-in-time recovery.
- Encrypt and access-control backups independently from the primary system.
- Back up configuration, schema, and required object-storage metadata.
- Define retention by recovery and compliance requirements.
- Test full and selective restore in an isolated environment.
- Record achieved recovery time and any data gap.
- Confirm search and derived projections can be rebuilt from authoritative data.

The portable staging proof uses two non-destructive restore targets:

- A PostgreSQL custom-format dump is listed, restored with `--exit-on-error`
  into a temporary database, queried for authoritative tables, and removed.
- The MinIO bucket is mirrored to restricted storage, restored into a temporary
  bucket, downloaded again, and compared with SHA-256 file manifests.

Neither verification may overwrite the active database or bucket. Backup
artifacts, checksums, restore output, image digest, and timestamps are retained
as evidence. Exact commands and cleanup behavior are maintained in the
[staging runbook](../../deploy/k8s/overlays/staging/README.md). Production still
requires an independent backup location, point-in-time recovery, object-policy
backup, and a provider-specific disaster-recovery rehearsal.
