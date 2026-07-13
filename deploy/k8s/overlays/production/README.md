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
PostgreSQL egress CIDR. Create `k-comms-secrets` through the selected external
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
credentials may be supplied through the optional `k-comms-provider-secrets`
Secret. `runtime-secrets.env.example` is the key inventory for the external
runtime secret controller.

The approved production object store must expose an HTTPS public endpoint and
have bucket versioning enabled. K-Comms fails attachment completion closed when
the provider does not return a version ID, ETag, and validated SHA-256 checksum.

`provider-config-patch.example.yaml` lists the non-secret provider settings and
`provider-secrets.env.example` lists the optional credential keys. Copy the
configuration patch into the approved provider composition, replace every
example value, and import provider credentials through the external secret
controller; neither example file is referenced by the base overlay.

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

The provider-neutral overlay is expected to fail this promotion preflight on
its own. A passing composed bundle has HTTPS notification and scanner
providers, explicit webhook hosts, a valid public VAPID key, production safety
flags, narrowed PostgreSQL egress, non-placeholder origins, and immutable image
digests, plus matching narrow ingress/proxy trust. It also rejects any long-lived workload marked for the one-shot
provider-preflight exemption. Schema validation alone is not a promotion
decision.

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
6. Run synthetic auth, realtime, replay, search, notification, webhook, and
   clean/malicious attachment journeys.
7. Confirm dashboards, alert routes, backup freshness, and rollback inputs.

An environment is not production ready until the restore, node-loss, zone-loss,
provider-outage, certificate-rotation, and secret-rotation exercises pass for
the exact provider composition.
