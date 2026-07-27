# Encryption and Key Management

- TLS protects client and service communication.
- Managed keys protect databases, object storage, and backups.
- Application-level field encryption is used only for identified restricted fields with a rotation design.
- Signing keys, webhook secrets, and token secrets have explicit owners and rotation schedules.
- Key access is logged and separated from ordinary application administration.
- Disaster recovery includes key availability and recovery testing.

## Effective application cryptography

- Restricted webhook and push-subscription fields use AES-256-GCM with a fresh
  96-bit nonce, a 128-bit authentication tag, explicit key identifiers, and
  context-specific additional authenticated data.
- Ephemeral instant-room replay capsules use AES-256-GCM with a
  purpose-derived key and separate v2 AAD. Decryption retains a bounded legacy
  v1 fallback only for capsules created during the ten-minute replay window
  before an upgrade.
- Human passwords use PBKDF2-HMAC-SHA256 with a 16-byte random salt, 32-byte
  output, and 600,000 iterations. Successful authentication upgrades accepted
  legacy hashes. Missing identities still perform a dummy current-cost KDF,
  and every invalid login response is padded to a 500-millisecond floor plus
  bounded jitter so legacy migration cannot invert the account-timing signal.
- Random refresh, recovery, guest-link, and service-account credentials are
  256-bit opaque values. Persisted forms are digests or contextual HMACs; short
  access/guest tokens are signed and re-resolve live server authority.
- `SECRET_KEY_BASE` requires at least 64 bytes at runtime. Encryption keyrings
  require the selected active ID, unique IDs, distinct rotation material, and
  separation between webhook and push domains.
- Attachment uploads sign `x-amz-server-side-encryption`, so the object store
  rejects a request that drops or downgrades encryption rather than silently
  storing plaintext. Upload and restore verification both require the object to
  report an encryption algorithm and fail closed with
  `object_encryption_missing` otherwise. Any algorithm is accepted so a
  KMS-backed bucket is not rejected for being stronger than the requested
  default, but only SSE-S3 keeps the ETag equal to the plaintext MD5; under any
  other algorithm the ETag is not treated as content evidence and the streamed
  SHA-256 remains authoritative.
- Environments that provision their own object store enable bucket default
  encryption, and the application reaches it as a bucket-scoped identity that
  cannot suspend versioning, clear bucket encryption, remove the bucket, or
  reach the admin API. Reusing the object-store root credential for the
  application is rejected by deployment secret validation.
- Participant and room-control credentials are issued only for a secure media
  origin. A plaintext signalling or SFU control origin fails closed unless the
  explicit local-development gate is enabled, so an admin-scoped provider token
  never travels over a plaintext origin in a promoted environment.

## Transport enforcement

Production PostgreSQL uses peer-verified TLS with an explicit CA, SNI, and
hostname verification. `DATABASE_URL` is forbidden from carrying an `ssl`
query override so URL parsing cannot disable that independent policy.
Production public, internal object-storage, provider, OIDC, application, and
media control-plane origins are HTTPS/WSS. Plain HTTP object storage is
permitted only by the explicit local-development gate and exact selected local
host.

Provider-managed volume, database, object, backup, and KMS encryption must be
proven by deployment evidence; repository configuration alone does not prove
those at-rest controls.

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

Normal rotation also terminalizes pending, retryable, or stale-delivering
rows tied to the retired version. Delivery materialization accepts only the
endpoint's current, unretired secret version, making rotation an immediate
revocation boundary.

## End-to-end encryption decision

E2EE changes search, moderation, compliance export, preview generation, key backup, device verification, and group membership semantics. It requires a dedicated ADR and protocol design before message storage and client synchronization are finalized.
