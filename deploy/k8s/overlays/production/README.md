# Production Kubernetes Overlay

This overlay is the hardened, provider-neutral application composition. It
expects managed PostgreSQL, durable S3-compatible storage, externally managed
runtime secrets, DNS, certificates, telemetry, and alert routing. It does not
deploy stateful data services inside the application namespace.

The object bucket must have versioning enabled. Upload verification records the
immutable version ID, ETag, and verified checksum; scanning and download remain
bound to that exact version even if a still-valid upload URL creates a newer
object version.

## Required provider inputs

Before rendering an approved bundle, replace the example hostnames, bucket,
region, image tag with an immutable digest, ingress class, TLS secret, and the
PostgreSQL egress CIDR. Replace `DATABASE_SSL_SERVER_NAME` with the exact DNS
name covered by the managed PostgreSQL certificate. Create
`k-comms-database-ca` from the provider's reviewed PEM trust bundle, using key
`ca.crt`; `database-ca-configmap.example.yaml` is an inventory template and is
not included by the overlay. The CA is public trust material and must not be
stored in `k-comms-secrets`. The edge, worker, and migration workloads mount it
read-only at the configured `DATABASE_SSL_CA_FILE` path and fail startup if it
is missing or invalid. Create `k-comms-secrets` through the selected external
secret mechanism with `DATABASE_URL`, `SECRET_KEY_BASE`, `RELEASE_COOKIE`,
`S3_ACCESS_KEY_ID`, and `S3_SECRET_ACCESS_KEY` plus enabled provider secrets.
The runtime Secret also requires either a 32-byte
`WEBHOOK_SECRET_ENCRYPTION_KEY` or a versioned
`WEBHOOK_SECRET_ENCRYPTION_KEYS` keyring plus
`WEBHOOK_SECRET_ENCRYPTION_KEY_ID`, and a random `METRICS_BEARER_TOKEN` of at
least 32 characters. It must also provide a dedicated random
`PASSWORD_RECOVERY_SIGNING_KEY` of at least 32 bytes. Platform-role management
uses the separately rendered, restricted one-shot Job and Secret under
`deploy/k8s/operations/platform-role`; neither management nor grant secret may
enter the long-lived runtime Secret. Browser push additionally requires a
dedicated 32-byte `PUSH_SUBSCRIPTION_ENCRYPTION_KEY` (or versioned keyring) and
the provider's `WEB_PUSH_VAPID_PUBLIC_KEY`; the matching private key remains at
the provider. Retain old non-legacy webhook and push key IDs until their stored
values have been rotated or expired. The webhook ID `legacy` is reserved:
rotate those endpoints under the prior release, quiesce and terminate its
worker Deployment, clear any abandoned `delivering` claim under an operations
change record, and apply migration `20260713000110` before restoring workers. Provider
credentials are supplied through `k-comms-provider-secrets`. Production edge
and worker pods require that Secret because LiveKit audio/video is required;
notification and scanner tokens remain capability-specific entries in the same
externally managed inventory. `runtime-secrets.env.example` is the key
inventory for the external runtime secret controller.

The approved production object store must expose an HTTPS public endpoint and
have bucket versioning enabled. K-Comms fails attachment completion closed when
the provider does not return a version ID, ETag, and validated SHA-256 checksum.

`provider-config-patch.example.yaml` lists the non-secret provider settings and
`provider-secrets.env.example` lists the provider credential keys. Copy the
configuration patch into the approved provider composition, replace every
example value, and import provider credentials through the external secret
controller; neither example file is referenced by the base overlay.

That example also carries ADR-0023's proposed corporate identity contract.
Production preflight rejects the local-password/manual lifecycle and requires
an exact HTTPS OIDC issuer, registered client ID, reviewed assurance values,
and named OIDC/SCIM providers. This prevents a provider composition from
claiming corporate identity policy while retaining development modes. It does
not implement or qualify OIDC or SCIM: do not add client or provisioning
secrets until code consumes them, and do not promote until provider-backed
login, MFA, account linking, deprovisioning/revocation, and break-glass evidence
close the ADR's implementation gate.

Audio and video use a separate provider boundary. The compatibility-named
`AUDIO_*` settings govern both media kinds. The production application
composition must set AUDIO_PROVIDER_MODE=livekit, an exact browser-facing WSS port-443
LIVEKIT_SERVER_URL, an exact backend-facing HTTPS port-443 LIVEKIT_API_URL,
and a 60-300 second AUDIO_TOKEN_TTL_SECONDS. Set
AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS to 660-1,800 seconds, at least
the token lifetime; the maintained minimum repeat horizon is 660 seconds. Only
the WSS origin belongs in CSP_CONNECT_SOURCES. LIVEKIT_API_KEY and the
at-least-32-byte LIVEKIT_API_SECRET belong only in the externally managed
k-comms-provider-secrets Secret; that Secret is non-optional for production
edge and worker pods. The browser receives only short-lived participant
tokens, never provider credentials.

Each credential issuance persists its opaque participant admission identity
and K-Comms authorization bindings, but never the signed token. Access changes
commit their admission invalidation and durable media-queue eviction work
without waiting for LiveKit. The worker retries idempotent participant removal
and repeats it through at least the configured enforcement horizon, bounding
replay of a cached self-hosted token without restoring revoked application
authority. Failed removals continue retrying beyond the horizon; completion
requires a successful removal at or after it.

This portable production application overlay intentionally does not deploy
LiveKit, Coturn, or another SFU/TURN service. The selected external media
composition needs separately reviewed DNS, WSS/HTTPS certificates, TURN
TLS/UDP/TCP reachability, restricted relay credentials, regional routing,
expected group size and camera/screen bandwidth capacity plus headroom,
camera/screen consent and recording-disabled privacy policy,
content-blind telemetry, provider outage handling, and revocation evidence. Standard HTTP
Ingress validation is not evidence that RTP/SRTP or TURN works.

The portable self-hosted adapter does not claim instantaneous token
invalidation. If the approved revocation SLO requires an immediate
single-participant hard stop, separately implement and qualify LiveKit Cloud
token revocation. Otherwise whole-room deletion is the immediate fallback and
disconnects all participants; it is not an equivalent per-participant control.

Set `TRUSTED_PROXY_CIDRS` only to the provider-specific ingress-controller
source networks and replace the empty `k-comms-edge-ingress` rule with matching
`ipBlock` sources on TCP 4000. The semantic preflight rejects empty, generic
RFC1918, unrestricted, invalid, or mismatched trust/policy ranges. The separate
human-auth, service-API, and WebSocket Ingress resources carry independently
calibrated admission settings; verify real client-address propagation and
distributed limit behavior in the selected ingress implementation.

After composing those external values, validate the secret inventories without
printing their contents, render the exact reviewed bundle, and run the semantic
promotion preflight:

```bash
python scripts/validate_staging_secrets.py \
  '<restricted-path>/runtime-secrets.env' \
  '<restricted-path>/provider-secrets.env'
make production-preflight PRODUCTION_BUNDLE='<restricted-path>/production.yaml'
```

Before applying a privileged one-shot operation, render its provider
composition beside the retained production bundle and pass every file to the
same validator:

```bash
python scripts/validate_production_bundle.py \
  '<restricted-path>/production.yaml' \
  '<restricted-path>/platform-role.yaml' \
  '<restricted-path>/attachment-restore-remap.yaml'
```

The operation manifests intentionally contain an unusable
`REPLACE_WITH_APPROVED_SHA256_DIGEST` image value. The provider composition must
replace it with the exact immutable image reference used by edge, worker, and
migration, set the same production namespace, and make the database CA volume
non-optional. Validate only the operation being run; both files above simply
demonstrate the combined validation path.

The semantic preflight requires every namespaced object to target
`k-comms-production`; cluster-scoped objects are recognized explicitly. It
also requires the worker startup, readiness, and liveness probes to retain the
exact release RPC health command. A provider composition must change the
namespace through an approved repository change rather than mixing namespaces
inside a rendered bundle.

The provider-neutral overlay is expected to fail this promotion preflight on
its own. A passing composed bundle has HTTPS notification and scanner
providers, explicit webhook hosts, a valid public VAPID key, production safety
flags, the proposed corporate OIDC/SCIM policy contract, authenticated
PostgreSQL TLS with a retained CA mount and non-placeholder
verification hostname, narrowed PostgreSQL egress, non-placeholder origins, and
one exact immutable image reference, plus matching narrow ingress/proxy trust.
It also rejects duplicate resource identities, extra workload containers,
unsafe security contexts, ineffective disruption budgets, and any long-lived
workload marked for the one-shot
provider-preflight exemption. Schema validation alone is not a promotion
decision.

The preflight also rejects disabled or insecure media mode, non-WSS or
non-port-443 media origins, token TTLs or participant-eviction enforcement
horizons outside their reviewed ranges, an enforcement horizon shorter than
the token lifetime, CSP/media origin mismatch, an optional provider Secret, and
any portable in-namespace LiveKit or TURN workload. A passing configuration
validates the deployment contract only; it does not prove media reachability,
audio/video/screen quality, group capacity, call privacy, or the revocation SLO.

The portable PostgreSQL egress rule deliberately excludes link-local addresses
but permits TCP 5432 globally. The provider composition must narrow it to the
managed database network and enforce the same destination through its firewall.

## Promotion gate

1. Render, schema-validate, and pass the semantic production preflight for the
   exact provider-composed bundle.
2. Replace the image reference with an immutable, signed digest.
3. Review the diff from the last retained production bundle.
4. Run the migration Job and retain timing evidence.
5. Deploy edge and workers, then wait for availability and HPA readiness.
6. Run synthetic auth, realtime, replay, search, notification, webhook,
   clean/malicious attachment, two-party bidirectional audio/video, at least
   three-participant group-grid, and screen-share publish/subscribe/cleanup
   journeys, including
   forced TURN, UDP-blocked fallback, provider interruption/recovery, durable
   participant eviction, and cached-token replay through the full minimum
   enforcement horizon, including a successful removal at or after it. Record
   access-change commit and media-disconnect times separately.
7. Confirm dashboards, alert routes, backup freshness, and rollback inputs.

An environment is not production ready until the restore, node-loss, zone-loss,
provider-outage, certificate-rotation, and secret-rotation exercises pass for
the exact provider composition.

For a managed PostgreSQL CA rotation, first publish a reviewed bundle containing
both current and replacement CA certificates, roll migration-capable and
long-lived workloads, and prove new verified connections. Remove the retired
CA only in a second reviewed rollout after the provider cutover succeeds.
