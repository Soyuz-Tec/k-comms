# Backup and Restore

- Enable continuous database recovery or equivalent point-in-time recovery.
- Encrypt and access-control backups independently from the primary system.
- Back up configuration, schema, and required object-storage metadata.
- Define retention by recovery and compliance requirements.
- Test full and selective restore in an isolated environment.
- Record achieved recovery time and any data gap.
- Confirm search and derived projections can be rebuilt from authoritative data.

The portable staging workflow uses two non-destructive component checks before
the isolated integrated restore:

- A PostgreSQL custom-format dump is listed, restored with `--exit-on-error`
  into a temporary database, queried for authoritative tables, and removed.
- The MinIO bucket is mirrored to restricted storage, restored into a temporary
  bucket, downloaded again, and compared with SHA-256 file manifests.

A portable object mirror does not preserve MinIO version IDs. During an actual
database-and-object restore, application traffic remains stopped while the
guarded one-shot release workflow streams and verifies every version-bound
attachment, obtains each restored S3 version ID, and atomically remaps the
verified rows with audit events. A missing or mismatched object aborts the
operation without a partial remap. Promotion additionally requires downloading
an attachment that existed before the backup through the restored application.

Neither verification may overwrite the active database or bucket. Backup
artifacts, checksums, restore output, image digest, and timestamps are retained
as evidence. Exact commands and cleanup behavior are maintained in the
[staging runbook](../../deploy/k8s/overlays/staging/README.md). Production still
requires an independent backup location, point-in-time recovery, object-policy
backup, version-aware replication or snapshots where available, and a
provider-specific disaster-recovery rehearsal.

## 2026-07-12 integrated portable restore result

With application traffic quiesced, the current database and object data were
backed up and restored into an isolated stack. The restored data contained 18
attachment rows and 10 objects. The guarded workflow verified all four ready,
version-bound candidates before atomically remapping them and recording five
audit events. A pre-backup message attachment was visible in the restored web
UI, and its authenticated version-bound download exactly matched the expected
SHA-256. Six legacy unversioned rows intentionally remained quarantined and
fail-closed; they were not upgraded or made downloadable.

This passes the portable staging integrated-restore gate. It does not establish
production RPO/RTO or replace independent backup retention, managed database
PITR, provider-native object recovery, encryption/access review, or a disaster-
recovery rehearsal in the selected production environment.
