# ADR-0084: Record maintenance intervals and monitor recovery evidence

- **Status:** Accepted
- **Date:** 2026-09-19
- **Owners:** Operations, Security
- **Related decisions:** ADR-0055, ADR-0080, ADR-0082

## Context

The nightly application-consistent backup deliberately stops application writers
while dumping PostgreSQL and archiving MinIO. Its duration is therefore an
availability cost, but there is no structured phase or recovery timing evidence.
The periodic health service checks the application but does not detect a stale
backup, low storage, a missed health interval, or provide a delivery contract
for an external alert receiver.

## Decision

Record root-only, non-secret JSON receipts for every initiated backup and nightly
maintenance operation. Measure elapsed time with a monotonic clock. Backup
receipts include PostgreSQL, MinIO, configuration, manifest, retention, total
duration, result, failed phase, and backup path. Failed backups remain failed
even if MinIO recovery succeeds. Latest receipts are atomically published beside
immutable historical receipts.

The maintenance EXIT handler is installed before stopping the application. It
attempts application restart and full health verification on backup failure,
preserves the failure status, and records recovery separately. The measured
availability interval runs from the request to stop through successful health
verification, including restart and recovery. It is a conservative local
maintenance interval, not an independent edge-availability SLI. If stopping was
not confirmed, outage duration is unknown rather than invented. Failed recovery
records an open interval and elapsed observation; it does not claim a completed
outage or a later recovery it did not observe. An initially inactive application
is left inactive and does not acquire a new maintenance outage.

The health timer invokes a monitor that still runs the full deployment verifier.
It additionally checks latest backup evidence and completion marker, backup age,
the preceding healthy observation age, free bytes, and free inodes on backup,
PostgreSQL, and MinIO paths. Failed maintenance remains visible until a successful
maintenance run supersedes it. Root-only monitor state distinguishes new alerts,
unchanged issues, recovery, and healthy heartbeats. Failed alert and recovery
delivery retries; enabling alerts delivers existing unacknowledged issues once.

Alert and deadman delivery are disabled by default. An operator may configure a
root-owned `0600` monitoring JSON file and a root-owned `0700` executable hook in
directories not writable by other users. The hook receives a bounded, non-secret
event on stdin with a minimal environment. It has a 10-second timeout; output is
discarded. Invocation is direct, without a shell. Unhealthy state never sends a
healthy heartbeat. Hooks must be separately configured and tested against an
authorized receiver; a successful process exit proves hook acceptance only.

## Consequences

Operators can measure backup-induced interruption, distinguish backup failure
from failed service recovery, and detect stale local recovery evidence. Default
thresholds are a 28-hour backup age, 180-second healthy-observation age, 5 GiB free
space, and 5 percent free inodes. They are explicit bounded configuration values.
Planned maintenance can produce application-health alerts; the implementation
does not hide actual unavailability behind an unbounded maintenance exemption.

This adds local evidence and an integration boundary. It does not configure an
external receiver, prove notification delivery, detect total host loss without
an external deadman, create off-host backups, add PostgreSQL PITR, guarantee a
recovery objective, or replace periodic full backup checksum/restore rehearsal.
Receipt retention remains an operator policy; the existing backup data-retention
policy is unchanged. Open outage intervals require later operator/runtime
evidence to establish recovery time.

## Alternatives

- Recording backup duration alone omits shutdown and restart/health cost.
- Logging raw command errors or environment values risks disclosure and is not
  necessary for stable operational event codes.
- Shipping a preselected external endpoint would invent a receiver, credentials,
  ownership, and notification policy. Keep the integration disabled until those
  are explicitly configured and qualified.
- A local heartbeat cannot detect the complete loss of its own host; a receiver
  outside that failure domain is required for that claim.

## Validation

Linux failure-injection tests execute the real backup and maintenance scripts
with synthetic host commands. They cover success, dump/stop/backup/start/health
failure, verified recovery, open intervals, initially inactive services, all
backup phases, and health-inclusive timing. Pure decision tests cover stale,
failed, missing, malformed and incomplete backups, health gaps, low bytes/inodes,
alert deduplication, recovery, retry, disabled delivery, and hook permissions,
environment, timeout, and output handling. CI enforces the wiring.

Staging must capture real operation receipts. Production alert delivery and
external deadman detection remain pending an authorized receiver and a witnessed
delivery/failure drill; local tests are not evidence of those external outcomes.
