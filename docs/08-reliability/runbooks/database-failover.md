# Runbook: Database Failover

- **Owner:** K-Comms platform and data operations
- **Alerts/triggers:** Managed PostgreSQL primary/replica alarm, failed verified connection, unsafe replication lag, or write unavailability
- **Default severity:** Sev-1 for possible loss/divergence or platform-wide writes; Sev-2 for bounded failover with durable state intact
- **Dashboard:** Provider database dashboard plus `ops/dashboards/service-overview.json`
- **Required context:** Environment, region, deployed Git revision, image digest, database provider incident, and last known recovery point

## User impact

Message sends, membership changes, authentication, administration, and durable
background work fail closed when PostgreSQL is unavailable. Already
acknowledged messages must remain recoverable. Realtime connections may stay
open briefly, but they are not evidence that durable writes are working.

## Preconditions and safety warnings

- Assign an incident commander, data-operations owner, and communications owner.
- Confirm the provider failover procedure, approved RPO/RTO, latest independent
  backup, and retained application release before changing state.
- Never promote a replica, restore a backup, run SQL, delete jobs, or change the
  application database URL from an ad hoc shell.
- Stop immediately on suspected split brain, unknown replication position,
  tenant-isolation concern, or a recovery point outside the approved RPO.

## Initial diagnosis

Record command output in the restricted incident evidence store. These checks
are read-only:

```bash
: "${NAMESPACE:?set the production namespace}"
: "${API_ORIGIN:?set the trusted production origin}"
kubectl -n "$NAMESPACE" get deployment k-comms-edge k-comms-worker -o wide
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=k-comms -o wide
kubectl -n "$NAMESPACE" get job k-comms-migrate -o wide
curl --fail --silent --show-error "$API_ORIGIN/health/ready"
```

Then establish, from the managed PostgreSQL control plane:

1. primary identity and health;
2. replica health, replay position, lag, and synchronous/async mode;
3. last successful PITR/backup timestamp and independent-copy status;
4. connection saturation, storage capacity, and recent maintenance/failover;
5. whether application errors began before or after a release/configuration
   change.

## Stabilization actions

1. Freeze rollout expansion, migrations, retention/deletion jobs, and unrelated
   database changes through the approved release pipeline.
2. Keep readiness fail-closed. Do not route writes to an unverified replica or
   weaken certificate/hostname verification.
3. If the provider confirms a healthy failover target inside the RPO, have the
   authorized data operator execute the provider-owned failover procedure.
4. If no safe target exists, keep writes unavailable and start the approved
   isolated restore/DR decision path. Preserve the failed primary and logs.
5. After the provider endpoint is authoritative, roll application workloads
   only when the connection identity or CA bundle changed; use the retained
   reviewed deployment bundle.

## Stop conditions

Stop recovery and escalate before serving traffic if any of these is true:

- two writable primaries, divergent timelines, or an unknown promotion point;
- restored data is older than the approved RPO or cannot be reconciled;
- hostname-verified TLS, database CA, or credential ownership is uncertain;
- migration version differs across candidate and retained release;
- synthetic authorization or tenant-isolation checks fail; or
- acknowledged-message loss or duplicate durable commands are observed.

## Escalation

Page platform/data on-call and the managed PostgreSQL provider. Page security
and privacy for suspected unauthorized access, tenant leakage, or credential
exposure. The incident commander owns the restore-versus-wait decision and
status updates; application engineers do not independently choose a recovery
point.

## Recovery validation

Do not reopen traffic based only on a green database console. Against the
recovered primary:

1. verify `/health/ready`, application revision, image digest, and database TLS
   peer name;
2. run one synthetic sign-in, idempotent send, live delivery, history replay,
   search, administration read, and background-job journey;
3. reconcile acknowledged messages and outbox/job age across the incident
   window;
4. confirm replica health, PITR operation, backup freshness, storage headroom,
   and alert recovery; and
5. observe the approved stability window before removing the traffic hold.

## Rollback and removal of temporary controls

Rollback means returning to the retained compatible application digest or the
documented provider topology; it never means an in-place destructive down
migration. Record every temporary traffic, scaling, job, or maintenance control
and remove it only after reconciliation. If restoration was used, retain the
source backup, recovery timestamp, restore logs, and exact bundle until the
problem review closes.

## Evidence to capture

- incident timeline, release revision/image digest, bundle digest, environment,
  namespace, and provider incident reference;
- primary/replica identities, replication positions, lag, backup/PITR records,
  chosen recovery point, and authorizing roles;
- deployment, readiness, migration, synthetic, queue/outbox, and reconciliation
  outputs without message content or secrets; and
- achieved data gap and recovery time compared with approved RPO/RTO.

## Follow-up

Complete a Sev-1/Sev-2 problem review, restore any consumed error budget,
rehearse the corrected procedure, and update provider contacts, thresholds,
capacity, and this runbook. Attach the retained exercise/incident evidence to
the exact-release readiness ledger; the repository template itself remains
pending.
