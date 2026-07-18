# Integration and Attachment-Safety Provider Guide

K-Comms persists notification, webhook, and attachment-scan state before any
external side effect. Provider absence or failure is visible and retryable; it
never becomes a fabricated delivery or clean-file verdict.

## Production configuration

Production defaults every optional provider to disabled. Enable only the modes
shown below and supply credentials through the deployment secret mechanism.
Unknown modes, development modes without their explicit gate, incomplete HTTP
credentials, non-HTTPS endpoints, and endpoint/allowlist mismatches fail at
runtime startup instead of silently falling back to a deny-all adapter.

| Capability | Mode | Required configuration |
|---|---|---|
| Notification delivery | `NOTIFICATION_PROVIDER_MODE=http` | `NOTIFICATION_PROVIDER_ENDPOINT`, `NOTIFICATION_PROVIDER_TOKEN`, `NOTIFICATION_PROVIDER_NAME`, `NOTIFICATION_PROVIDER_ALLOWED_HOSTS` |
| Browser Web Push | notification HTTP provider | `WEB_PUSH_VAPID_PUBLIC_KEY`, `PUSH_SUBSCRIPTION_ENCRYPTION_KEY` or versioned keyring; matching VAPID private key configured only at provider |
| Attachment scanning | `ATTACHMENT_SCANNER_MODE=http` | `ATTACHMENT_SCANNER_ENDPOINT`, `ATTACHMENT_SCANNER_TOKEN`, `ATTACHMENT_SCANNER_PROVIDER_NAME`, `ATTACHMENT_SCANNER_ALLOWED_HOSTS` |
| Webhook delivery | `WEBHOOK_PROVIDER_MODE=http` | `WEBHOOK_ALLOWED_HOSTS`, `WEBHOOK_SECRET_ENCRYPTION_KEY` |
| Metrics scraping | authenticated | `METRICS_BEARER_TOKEN` with at least 32 random characters |

Provider endpoints use HTTPS and must match explicit host and port allowlists.
Redirects, resolved private/link-local addresses, disallowed ports, invalid DNS,
and credential-bearing URLs are rejected. Tokens, signing secrets, payload
content, and provider response bodies are excluded from ordinary logs and API
readback.

`WEBHOOK_SECRET_ENCRYPTION_KEY` is exactly 32 raw bytes or a Base64 encoding of
32 bytes. Webhook signing secrets are returned only on endpoint creation or
rotation. Operators must store that one-time value before leaving the response.

For zero-downtime encryption-key rotation, set `WEBHOOK_SECRET_ENCRYPTION_KEY_ID`
to the active identifier and provide `WEBHOOK_SECRET_ENCRYPTION_KEYS` as a
comma-separated `key_id:base64-key` keyring. Retain the previous key identifier
until every secret version encrypted by it has been rotated. AEAD associated
data binds new ciphertext to its tenant, endpoint, secret version, and key ID.

Browser subscriptions use an independent key namespace. Set
`PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID` and either one exact 32-byte
`PUSH_SUBSCRIPTION_ENCRYPTION_KEY` or a comma-separated
`PUSH_SUBSCRIPTION_ENCRYPTION_KEYS` keyring. Do not reuse the webhook, Phoenix,
database, or recovery key. Retain previous IDs until their subscription rows
have been re-registered or expired.
Push configuration and registration additionally require an enabled
notification delivery adapter. `disabled` notification mode therefore cannot
advertise usable browser push. The gated local `log` adapter is accepted only
as degraded qualification delivery.

`WEB_PUSH_VAPID_PUBLIC_KEY` is a base64url uncompressed P-256 public key and is
safe to return to authenticated browsers. Its matching private key is never a
K-Comms runtime variable: it remains inside the configured notification
provider. For `channel: push`, the provider receives a standard destination
object with `endpoint`, optional `expirationTime`, and `keys.p256dh`/`keys.auth`.
That object exists in K-Comms memory only during the worker call. Providers must
not log it and should return HTTP 404 or 410 when the endpoint is permanently
gone so K-Comms can mark the exact subscription generation stale.

Attachment storage must have object versioning enabled. Uploads carry a signed
SHA-256 checksum, completion persists the returned object version and ETag, and
scanner/download URLs always select that exact version. Presign descriptors
also carry a configuration-derived `approved_origin`; clients reject a URL
whose origin differs, contains credentials, or uses non-HTTPS transport outside
explicit localhost development.

## Deliberate development modes

`ALLOW_DEVELOPMENT_ADAPTERS=true` unlocks these explicit non-production modes:

- `NOTIFICATION_PROVIDER_MODE=log` records delivery through the development log
  adapter without contacting a provider.
- `ATTACHMENT_SCANNER_MODE=allow_all` gives deterministic clean verdicts for
  local acceptance only.
- `WEBHOOK_PROVIDER_MODE=log` exercises endpoint, secret, ledger, worker, and
  replay behavior without network delivery.

Production overlays set `ALLOW_DEVELOPMENT_ADAPTERS=false`; selecting a
development mode without that gate resolves to the deny-all adapter.

## Attachment state invariant

Upload completion proves only object existence, size, and optional checksum.
It moves the attachment to quarantine and enqueues a scan. Only a clean verdict
for the current attachment object changes it to downloadable `ready` state.
Malicious, timeout, provider-error, missing-provider, and stale-verdict paths
remain non-downloadable. Admins may inspect and retry quarantine entries.

## Operational checks

- Inspect `/api/v1/ops` with an authorized operations identity.
- Alert on oldest retryable job, discarded jobs, unpublished outbox age,
  notification/webhook terminal failures, and quarantine age.
- Exercise provider outage, recovery, idempotent retry, secret rotation, and
  malicious-file paths before promotion.
- Capture a real test Web Push request and prove the provider uses the VAPID
  private key matching `WEB_PUSH_VAPID_PUBLIC_KEY` without returning or logging it.
- Protect `/metrics` with its dedicated bearer token and private network path.
