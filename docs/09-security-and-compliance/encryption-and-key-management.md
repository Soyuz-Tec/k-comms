# Encryption and Key Management

- TLS protects client and service communication.
- Managed keys protect databases, object storage, and backups.
- Application-level field encryption is used only for identified restricted fields with a rotation design.
- Signing keys, webhook secrets, and token secrets have explicit owners and rotation schedules.
- Key access is logged and separated from ordinary application administration.
- Disaster recovery includes key availability and recovery testing.

## Context-bound integration secrets

Webhook signing-secret versions use AES-256-GCM additional authenticated data
containing the key identifier, tenant, endpoint, and secret version. Ciphertext
therefore cannot be moved to another tenant, endpoint, or version and still
decrypt. Key identifier `legacy` is rejected at runtime and by the current
database constraint; the single-key compatibility setting is never aliased to
that identifier.

Before upgrading a database created before contextual encryption, query
`webhook_secret_versions` for `key_id = 'legacy'` and rotate each affected
endpoint through the audited admin operation while the prior release is still
running. Before migration, quiesce the prior worker Deployment and wait for all
legacy-version deliveries to leave `delivering`; do not rely on claim age,
because an older worker can still be blocked in provider I/O. If a claim was
abandoned, terminate the old worker process before changing that row to
`failed` under the normal operations change record. Migration
`20260713000110` aborts while any legacy version remains current or unretired,
or while any delivery claim still uses one. It takes write-conflicting locks
before this check. After successful rotation and drain it terminally marks
other outstanding deliveries tied to the retired version, deletes the unusable
legacy ciphertext, and installs the constraint that prevents it from
returning. Delivered history and the audited rotation record remain; replay an
affected undelivered event only through the current endpoint version after the
upgrade, then restore the worker Deployment.

## End-to-end encryption decision

E2EE changes search, moderation, compliance export, preview generation, key backup, device verification, and group membership semantics. It requires a dedicated ADR and protocol design before message storage and client synchronization are finalized.
