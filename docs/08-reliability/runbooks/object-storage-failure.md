# Runbook: Object Storage or Attachment-Safety Failure

- **Owner:** K-Comms attachment safety and platform operations
- **Alerts/triggers:** `KCommsAttachmentQuarantineBacklog`, `KCommsAttachmentScanFailures`, object-provider health alarm, or version/checksum mismatch
- **Default severity:** Sev-2 for blocked attachment workflows; Sev-1 for unsafe download, object substitution, or cross-tenant exposure
- **Dashboard:** `ops/dashboards/service-overview.json` plus object-storage and scanner-provider dashboards
- **Required context:** Environment, release revision, image digest, provider endpoint, bucket, and affected object-version range

## User impact

New uploads may not complete, scanning may be delayed, and affected attachments
remain quarantined or unavailable for download. Messaging without attachments
should continue. A safety or version-identity failure is never bypassed to
restore convenience.

## Preconditions and safety warnings

- Keep quarantine and exact-version download checks fail-closed.
- Never mark an object clean manually, copy it over another version, disable
  versioning, expose provider credentials, or substitute an `allow_all` scanner.
- Assign the attachment-safety owner before retrying provider side effects.
- Treat checksum, ETag, version ID, bucket ownership, or tenant binding mismatch
  as a security incident.

## Initial diagnosis

Use read-only workload and metric checks, preserving correlation IDs rather
than filenames, signed URLs, or message content:

```bash
: "${NAMESPACE:?set the production namespace}"
: "${API_ORIGIN:?set the trusted production origin}"
: "${METRICS_BEARER_TOKEN:?load through the approved secret channel}"
kubectl -n "$NAMESPACE" get deployment k-comms-worker -o wide
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=worker -o wide
curl --fail --silent --show-error "$API_ORIGIN/health/ready"
curl --fail --silent --show-error \
  --header "authorization: Bearer $METRICS_BEARER_TOKEN" \
  "$API_ORIGIN/metrics" \
  | grep -E '^k_comms_(attachments_quarantined|attachment_scan_failures) '
```

Correlate the first failure with object-provider availability, bucket
versioning, credential/CA rotation, egress/DNS changes, scanner status, worker
deployment, and retry classification. Inspect only redacted application logs.

## Stabilization actions

1. Freeze attachment-provider, scanner, network-policy, and worker rollout
   changes.
2. Communicate attachment degradation while leaving core messaging available.
3. Restore provider reachability, CA, DNS, or scoped credentials through the
   approved configuration/secret workflow; do not patch live secrets manually.
4. Once provider identity is verified, resume bounded exact-version jobs. Use
   the product retry ledger or approved idempotent operation, never direct
   database mutation.
5. If object data is unavailable or corrupt, enter the provider-native restore
   and exact-version remap procedure with backup, approval, dry run, and
   reconciliation evidence.

## Stop conditions

Stop retries or restoration when the requested version ID, SHA-256, ETag,
tenant binding, bucket identity, provider certificate, or scanner verdict
cannot be proved. Stop on unexpected object replacement, public exposure,
malware release, cross-tenant reference, or a growing retry loop.

## Escalation

Escalate to attachment safety, platform on-call, object-storage provider, and
scanner provider. Page security/privacy immediately for unsafe download,
malicious content release, credential exposure, object substitution, or tenant
boundary uncertainty. Data restore/remap needs the approved two-person change
authority.

## Recovery validation

1. Confirm bucket versioning, encryption, restricted credentials, provider TLS,
   and object lifecycle policy.
2. Upload a clean synthetic fixture and prove the exact version/checksum becomes
   downloadable only after a clean verdict.
3. Upload a malicious synthetic fixture and prove it remains quarantined and
   cannot be downloaded.
4. Verify a stale/replaced object version cannot satisfy completion, scanning,
   or download.
5. Confirm backlog/failure gauges decline, worker readiness is stable, and core
   message send/replay remains correct.

## Rollback and removal of temporary controls

Return worker replicas, provider routing, and maintenance controls to the
reviewed bundle. Retain old encryption keys until all bound values are rotated
or expired. Remove temporary restore/remap permissions and one-shot resources
after audit/reconciliation succeeds; do not delete source versions or evidence
until the incident review authorizes retention cleanup.

## Evidence to capture

- release and environment identity, provider incidents, affected opaque object
  references and version range, first/last failure timestamps, and alert values;
- redacted retry classifications, provider certificate/endpoint identity,
  bucket versioning policy, and worker deployment state;
- clean/malicious/stale-version synthetic results with hashes but no signed URLs
  or credentials; and
- restore/remap approvals, manifests, checksums, audit events, and final
  reconciliation counts.

## Follow-up

Review provider SLOs, lifecycle/capacity, scanner limits, retry policy, and
egress/credential rotation. Rehearse both outage and exact-version restore
paths, update alerts and this runbook, and link restricted evidence from the
exact-release readiness ledger.
