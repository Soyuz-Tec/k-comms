# Configuration and Secrets

- Build artifacts are environment-neutral.
- Runtime configuration is injected through controlled configuration and secret systems.
- Secrets never enter source control, container images, logs, or client-visible configuration.
- Rotation is supported without full application rebuild.
- Configuration changes are reviewed, versioned, and auditable.
- Startup validates required configuration and fails clearly on unsafe combinations.

For staging, `k-comms-secrets` has a stable name because Kustomize generator
hashing is disabled. Secret updates therefore require an explicit rollout
restart of edge and worker deployments and a new reviewed rendered bundle.
Database and object-storage credential rotation must be coordinated with those
services before their consumers restart.

Production database transport is authenticated, not merely encrypted.
`DATABASE_SSL=true` requires `DATABASE_SSL_CA_FILE` to identify a readable PEM
CA bundle and `DATABASE_SSL_SERVER_NAME` to identify the explicit DNS hostname
covered by the managed PostgreSQL certificate. Runtime configures peer and
hostname verification and stops before connecting if either input is absent,
malformed, or an IP literal. The CA is non-secret trust material mounted
read-only from the provider-composed `k-comms-database-ca` ConfigMap; it does
not belong in `k-comms-secrets` or the container image. Keep credentials only
in `DATABASE_URL`. Rotate the CA with an old-plus-new overlap bundle, roll every
database-using workload, prove reconnection, and only then remove the retired
certificate. Local and portable staging retain `DATABASE_SSL=false` and do not
require these inputs.

`k-comms-secrets` also contains the webhook-secret and push-subscription
encryption keys and metrics
scraper token. Optional notification and scanner credentials may use the
separate `k-comms-provider-secrets` Secret referenced by edge and worker
workloads. The provider Secret is optional so disabled integrations do not
prevent core messaging from starting; the associated capability remains
explicitly unavailable and fails closed.

Provider endpoints, modes, names, allowlists, ports, and timeouts are
non-secret reviewed configuration. Provider tokens, the 32-byte webhook-secret
encryption key, the independent 32-byte push-subscription encryption key,
metrics bearer token, database credentials, release cookie,
object-storage credentials, and one-time webhook signing secrets are secret.
Rotation requires a rollout plus delivery/quarantine reconciliation evidence.
The webhook key ID `legacy` is permanently reserved for pre-context-bound
ciphertext and is rejected in the active key ID, keyring, application startup,
and deployment-secret validator. Rotate every such row before applying the
context-bound-secret migration. The migration fails while a legacy version is
current or unretired, or while any legacy delivery remains `delivering`.
Quiesce the prior worker Deployment and terminate it before administratively
clearing an abandoned claim; claim age alone is insufficient for an older
slow-drip transport. The migration takes write-conflicting locks before
checking, then removes retired legacy ciphertext and terminally marks its other
outstanding deliveries rather than retaining a globally replayable
compatibility path.
Runtime startup accepts only the documented provider modes. HTTP notification
and scanner modes require a complete HTTPS endpoint, token, provider name, and
an allowlist containing the endpoint host. Webhook HTTP mode requires at least
one explicit destination hostname. Invalid modes and incoherent HTTP settings
stop the release before it accepts traffic. The `log` and `allow_all` adapters
also stop startup unless `ALLOW_DEVELOPMENT_ADAPTERS=true` is set explicitly.
Restricted migration, bootstrap, and platform-role eval Jobs declare
`K_COMMS_RUNTIME_PURPOSE=one_shot`; they still validate mode names and the
development gate but do not receive or validate unrelated provider tokens.
They are not exempt from database TLS verification: a production one-shot Job
must mount the same reviewed CA bundle as the long-lived workloads. Before
apply, its provider composition must replace the fail-closed image placeholder
with the exact approved edge/worker/migration image digest and pass the
operation bundle beside the retained application bundle to
`scripts/validate_production_bundle.py`.
Long-lived edge and worker workloads default to `application`, cannot use that
exemption in a promotion-ready bundle, and always run the full preflight.

`WEB_PUSH_VAPID_PUBLIC_KEY` is reviewed non-secret configuration. The matching
VAPID private key belongs only to the selected notification provider and must
not be mounted in K-Comms pods. Subscription endpoints and authentication keys
are capability secrets encrypted with the dedicated push keyring and are
materialized only in notification-worker memory.
Browser-push registration is unavailable when notification delivery is
disabled, even if its encryption key and public VAPID key are present. The
explicit local `log` adapter remains a degraded but usable qualification path;
it never represents production delivery.

Password recovery requires a dedicated, random, at-least-32-byte
`PASSWORD_RECOVERY_SIGNING_KEY`; it must not reuse the Phoenix, webhook, or
database secrets. `PUBLIC_APP_URL` is the browser-visible application origin
and must be an absolute HTTPS URL outside development and test.
`SESSION_TTL_SECONDS` bounds sliding refresh activity, while
`SESSION_ABSOLUTE_TTL_SECONDS` supplies the total-lifetime policy when a session
is created. Both default to 2,592,000 seconds (30 days). The resulting absolute
deadline is stored in `sessions.absolute_expires_at` and is not recalculated;
changing the policy affects only sessions created afterward. Explicit session,
device, password-reset, or account revocation remains the mechanism for ending
existing sessions early. During the documented one-release rollback window,
the database supplies a fixed, UTC-normalized 30-day absolute deadline only
when a previous release omits this newly added column. Current releases always
write the configured value explicitly; the compatibility default is not a
second policy source. The previous binary does not enforce the new absolute
deadline while it is active, so rollback remains a short, controlled recovery
window followed by verified roll-forward.
`PASSWORD_RECOVERY_TTL_SECONDS` is constrained by the application to 900–1800
seconds. Consumed, invalidated, and expired request rows are retained for 30
days by default (`PASSWORD_RECOVERY_RETENTION_SECONDS`) and then removed in
bounded batches; immutable audit events are retained separately. Signing-key
rotation immediately invalidates outstanding recovery links and therefore
requires an announced recovery window and rollout.

Every public recovery-request response is padded to at least
`PASSWORD_RECOVERY_MIN_RESPONSE_MS` (500 ms by default) plus a random delay up
to `PASSWORD_RECOVERY_JITTER_MS` (50 ms by default). The application bounds
those settings to 0–2,000 ms and 0–250 ms respectively. Keep the production
defaults unless an ingress-level timing study approves a change; the padding
is defense in depth and does not replace account and IP rate limits.

`TRUSTED_PROXY_CIDRS` is a comma-separated list of the ingress/proxy networks
whose forwarded client address may be trusted. Keep it empty unless the
deployed ingress ranges are known and reviewed. Requests from other peers and
malformed forwarding chains fail closed to the direct peer address. The
provider-neutral production overlay keeps it empty and denies edge ingress.
The provider composition must supply narrow ingress-controller CIDRs and exact
matching `k-comms-edge-ingress` NetworkPolicy `ipBlock` sources; promotion
preflight rejects generic RFC1918 or mismatched ranges. Qualify real-address
propagation and globally distributed rate-limit semantics under load.

Run `scripts/validate_staging_secrets.py` before creating Kubernetes Secrets.
It validates required one-of encryption keys/keyrings, key sizes, metrics and
release-secret entropy floors, bootstrap identity policy, and the credential
relationships in the portable staging PostgreSQL and MinIO services. Validation
errors identify only file, line, and key; secret values are never included.

The initial staging owner uses a separate `k-comms-bootstrap` Secret. It is
referenced only by the one-time release Job and is deleted, along with its local
env file, after success or failure. `ALLOW_BOOTSTRAP` remains `false`; the
staging HTTP API is not an administrative bootstrap path.

## Platform-role management

Platform roles are nullable identity attributes and have no tenant-admin HTTP
grant path. Long-lived edge and worker pods deliberately do not receive the
management secret. Use the restricted one-shot Job under
`deploy/k8s/operations/platform-role`, backed by a short-lived
`k-comms-platform-role-grant` Secret. The Job maps its management secret to the
configured verification value and matching command-scoped grant token, plus an
explicit actor, reason, target user, role, and `TTL_SECONDS` from 300 through
28,800 seconds, then invokes:

```sh
bin/k_comms eval 'CommsCore.Release.set_platform_role("USER_UUID", "platform_operator")'
```

Use `none` instead of `platform_operator` to revoke; a revoke does not require
`TTL_SECONDS`. The time-bounded grant or revoke and audit event commit
atomically; secrets are neither audited nor printed. The command prints the
grant deadline for operator readback. Delete the Job and its operator Secret
immediately afterward. Never add either secret value to the ordinary runtime
Secret or pod environment.

`K_COMMS_ALLOW_BOOTSTRAP_PLATFORM_ROLE=true` together with
`K_COMMS_BOOTSTRAP_PLATFORM_ROLE=platform_operator` is an explicitly opt-in,
idempotent convenience for local proof environments only. It applies only to
the already-created one-time bootstrap owner, uses the bounded
`K_COMMS_BOOTSTRAP_PLATFORM_ROLE_TTL_SECONDS` value (eight hours by default),
and emits a dedicated audit event. Keep it disabled for staging and production
bootstrap jobs.
