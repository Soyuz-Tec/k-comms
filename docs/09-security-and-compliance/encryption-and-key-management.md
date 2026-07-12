# Encryption and Key Management

- TLS protects client and service communication.
- Managed keys protect databases, object storage, and backups.
- Application-level field encryption is used only for identified restricted fields with a rotation design.
- Signing keys, webhook secrets, and token secrets have explicit owners and rotation schedules.
- Key access is logged and separated from ordinary application administration.
- Disaster recovery includes key availability and recovery testing.

## End-to-end encryption decision

E2EE changes search, moderation, compliance export, preview generation, key backup, device verification, and group membership semantics. It requires a dedicated ADR and protocol design before message storage and client synchronization are finalized.
