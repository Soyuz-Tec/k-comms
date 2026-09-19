# ADR-0080: Bind release promotion and failure recovery to verified evidence

- **Status:** Accepted
- **Date:** 2026-09-19
- **Owners:** Delivery, Operations, Security
- **Related decisions:** ADR-0055, ADR-0058, ADR-0064
- **Supersedes:** ADR-0058's standalone manual production entry point

## Context

The Container chain already verifies immutable artifacts, qualifies staging,
and requires independent production approval. However, its sibling CI workflow
can still be running when production completes, and the direct deployment form
can select production without a staging dependency. Separately, a backup or
preactivation failure after application shutdown leaves the old application
stopped because recovery only handles the activation branch.

The gates must enforce the documented release sequence, and failure recovery
must distinguish an unchanged database from a partially migrated database.

## Decision

1. Before host access, require the latest `CI` push run on `main` for the exact
   release SHA to have succeeded, including every required CI job. Missing,
   skipped, cancelled, failed, malformed, or incomplete evidence fails closed.
   The initial gate may wait up to 35 minutes; the post-approval recheck does
   not wait. The image may be built concurrently, but cannot be deployed while
   exact-candidate CI is incomplete.
2. Production must belong to the current main Container run and attempt. Its
   staging deployment job must have succeeded in that attempt. Verify the
   GitHub-hosted staging artifact's SHA-256, provenance, environment, release
   SHA, image digest, backup completion, and rollback/restore qualification.
   Capture must be within the current attempt and no older than 24 hours.
   The qualification itself must also be no older than 24 hours. Retained
   exact-image host qualification can be reused inside that window only through
   staging re-verification and newly captured workflow evidence; stale or invalid
   qualification forces a new rollback and restore rehearsal.
3. Recheck both gates after protected production approval and before creating
   SSH credential files or accessing the host. The workflow does not approve
   its own deployment. Artifact downloads never receive the GitHub bearer
   token after the API redirect, and signed download URLs are never logged.
4. The direct Deploy Proxmox form offers staging only. A forced direct
   production call fails the Container-run proof. Manual production recovery
   must start or rerun the complete Container chain, including staging; a
   failed-job-only rerun cannot reuse an earlier attempt's staging artifact.
   Root-console disaster recovery remains a separately authorized, audited
   operational action, not an alternative routine promotion workflow.
5. A deployment EXIT handler covers every phase after the rollback guard is
   captured. Before migration, restore and verify the prior application on
   failure. A failed migration leaves writers stopped because earlier
   migrations may have committed. After successful migration, automatic
   reactivation requires the existing communication compatibility preflight
   against the previous revision/capabilities, then previous-image health
   verification. No down migration or destructive restore is automatic.
6. Failed deployments retain a root-only guard and a non-secret phase/recovery
   record under the receipts directory. If durable evidence storage fails,
   retain the original `/run` guard and report its location. Guard files contain
   configuration secrets and must never be uploaded as ordinary artifacts.
   An unverified restart is stopped and reported as failed recovery. Successful
   deployments remove the guard and publish their current receipt only after
   application verification and timer activation succeed.
7. Every protected staging qualification now proves host reboot recovery after
   rollback/restore qualification and before evidence export. The SSH wrapper
   accepts only the inventory staging address, retains strict host-key checks,
   and uses noninteractive sudo. The root helper also checks the configured
   staging environment, bind address, and exact running image/revision before
   scheduling a five-second delayed systemd reboot. Production has no automatic
   reboot step. A ten-minute overall deadline and per-command process deadlines
   bound reconnect and recovery; a denied request, unacknowledged request, or
   timeout fails the qualification without resubmitting the reboot request.
8. Successful reboot proof requires a changed kernel boot ID, full application
   and PWA readiness, both health and backup timers enabled and active, and
   inspection of the actual service container environments. A root-only receipt
   binds the request, previous/new boot IDs, image, revision, and verification
   timestamp. Evidence export checks the receipt against the current boot ID.
   Production requires this proof from the current Container attempt, no older
   than 24 hours. Retained rollback/restore qualification within 24 hours does
   not waive a new reboot proof for the current attempt.

## Consequences

Production cannot race exact-main CI or borrow qualification from another
digest, workflow, or attempt. Delayed approvals can expire qualification and
require a full rerun. The protected runner needs Python 3.13, installed by the
existing SHA-pinned setup action. GitHub API/artifact availability becomes a
release dependency; outages block new host access while the running service
continues unchanged.

Staging is briefly unavailable during each release qualification reboot. The
protected staging account must be authorized for the existing root deployment
helper and transient systemd reboot scheduling. Missing privileges fail closed;
the workflow does not install a new sudo rule or weaken SSH verification. This
implements completion Gate 5.8 for host-service changes without relying on a
change detector to decide when reboot proof matters.

An unsafe or failed migration intentionally requires operator-led compatible
roll-forward or separately approved recovery. The handler does not invent a
generic schema-rollback guarantee. Existing compatible migration discipline
and the communication rollback preflight remain required.

## Alternatives

- Triggering release through `workflow_run` would introduce another privileged
  trigger and checkout boundary. Keep the existing serialized chain and inspect
  exact-revision evidence through read-only GitHub APIs.
- A boolean caller input or a copied digest alone cannot prove staging. Use
  trusted current-run job results and a digest-verified artifact instead.
- Restarting the previous binary after every migration error may write through
  a partially changed schema. Leave that phase stopped and retain evidence.
- Removing independent production approval or silently restoring data would
  weaken existing authority and recovery boundaries; neither is permitted.

## Validation

- Execute the real deployment script with synthetic commands and inject backup,
  object preparation, migration, rendering, startup, health, timer, and recovery
  failures; verify lifecycle order, compatibility checks, evidence, and success
  cleanup on Linux.
- Negative gate fixtures cover wrong SHA/repository/workflow/attempt, pending
  or failed CI, missing jobs, missing/expired/mutated artifacts, wrong digest,
  incomplete backup/rollback/restore evidence, stale capture, and credential
  stripping on redirects.
- The Proxmox contract rejects removal or reordering of pre-approval and
  pre-host-access gates, standalone production dispatch, missing attempt
  binding, and missing CI behavior tests.
- Linux host-command fixtures reject production/wrong host identity, wrong
  release, old qualification, denied scheduling, unchanged boot, mismatched
  requests, and failed health/timers/environment checks. PowerShell transport
  fixtures exercise reconnects, exact deadlines, malformed acknowledgments,
  fixed staging destination, and termination of a stalled child process.
  Promotion fixtures reject missing, stale, or mismatched reboot receipts.
- A real release must still pass protected PR CI, immutable publication,
  synthetic staging qualification, independent production approval, and public
  verification. Local failure injection does not constitute production proof.

## Build prerequisites discovered during qualification

The pinned MinIO server/client manifests are available from the vendor's Quay
namespace after Docker Hub began rejecting fresh pulls. Use the verified identical
SHA-256 digests from Quay in CI, Compose, Kubernetes, and Proxmox; this changes
the retrieval registry, not object-storage bytes or storage identity. It does not
establish ongoing vendor maintenance or substitute for dependency review.
The [vendor container instructions](https://github.com/minio/minio/blob/master/docs/docker/README.md)
identify the Quay namespace; the actual digest availability was verified directly.

Install available Debian package updates in both BEAM build and application
runtime stages. A digest-pinned base alone does not apply subsequently released
security fixes to packages already present in that base. The published artifact
remains immutable, attested, and SBOM-bound; the existing vulnerability gate
must pass without suppression before promotion. Validate rebuilt runtime startup
and staging qualification before production.

## API sources

The implementation uses GitHub's read-only
[workflow runs](https://docs.github.com/en/rest/actions/workflow-runs),
[workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs), and
[artifact](https://docs.github.com/en/rest/actions/artifacts) APIs.
