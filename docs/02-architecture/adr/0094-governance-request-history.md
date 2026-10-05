# ADR 0094: Bounded chronological governance request history

Status: Accepted
Qualification: source boundary decision accepted; execution and protected delivery
remain pending parent integration.

The administrative request detail previously filtered a recently loaded tenant
Audit list in the browser. Events for an older request could be omitted, and
provider failure strings and arbitrary proof metadata could reach the detail
panel. The API now reads one exact authorized deletion request and its real
retained lifecycle events, in chronological `(inserted_at, id)` order.

Governance owns permission, current request state and redaction. Its public
`deletion_request_timeline/3` and `export_deletion_request_history/3` use the Audit
owner's `resource_history_page/1`, with `ResourceHistoryQuery` and
`ResourceHistoryPage` contracts. Governance never imports an Audit schema or
reads an Audit table. Audit owns `audit_resource_history_snapshots`, its index,
its cap and expiry cleanup. Web only presents the resulting typed contracts.

Each disclosure transaction takes Governance's tenant fence first, then the
existing IdentityAccess content-write grant (quota, active Tenant, canonical
current User NO KEY UPDATE, live Device SHARE and exact live Session SHARE),
then the exact tenant-scoped Request SHARE. This matches governance writers'
tenant-fence prefix and avoids a reader User-to-Request / eraser Request-to-User
inverse. The current actor must be a human with workspace scope, Owner or
ComplianceAdmin role, and recent step-up. The original tuple and current facts
are rechecked after waits, after projection/CSV work and immediately before
return. A shared 15-second absolute query budget and 20-second repository cap
bound the operation. Snapshot expiry is rechecked before disclosure. All page
and export responses use `Cache-Control: no-store`.

A timestamp/id upper bound alone does not freeze membership: a later event can
have an equal or backdated timestamp. PostgreSQL tuple XID visibility also needs
mature/frozen tuple epoch semantics; this feature does not use that approach.
Audit instead captures at most 5,000 exact event UUIDs in one SELECT. A snapshot
stores only those UUIDs, exact tenant/resource/actions, observed time, expiry
and truncation; it stores no event metadata, actors or provider content.
Subsequent pages intersect that fixed membership with retained Audit rows.
Later inserts, including equal or backdated timestamps, stay excluded. Audit
rows are append-only through the owner API. Retention may remove a captured
member; the response discloses captured and retained counts rather than
reconstructing that event. The current Request DTO can advance independently
of an older snapshot, and separate observed timestamps make that visible.

Snapshots last one hour. Audit serializes admission under its own tenant lock,
permits at most 100 live snapshots per tenant, and rejects new capture at the
cap. Reading an existing valid snapshot remains possible. New capture removes
up to 100 expired snapshots for its tenant. The hourly
`AuditHistorySnapshotPurgeWorker` uses the Audit facade to remove at most 1,000
expired rows, schedules one demand continuation when needed and never loops
through unbounded rows in an execution. Tenant deletion cascades snapshots.

The cursor is HMAC-SHA256 signed with dedicated 32-byte-or-longer
`:governance_history_cursor_key`, supplied securely by `GOV_HISTORY_CURSOR_KEY`.
It is never derived from provider, password, MFA or OIDC material. The token
binds version, kind, tenant, request, opaque snapshot UUID, immutable page limit,
last timestamp/id and one-hour expiry. Missing key fails closed; tampered,
foreign, expired or missing snapshots are rejected. Tokens are kept in the UI's
memory. The retained snapshot table and active purge demand jobs require
`governance_history_v1`; a rollback target without it must pass current-image,
quiesced zero-hazard proof. All retained snapshot rows, including expired rows
not yet physically purged, are counted through the Audit owner projection
`rollback_history_snapshot_hazard_count/0`. This feature does not make an old
image compatible by changing a runtime flag.

Page limits are 1–50 (default25); export limits are 1–5,000 (default5,000). A
snapshot that omitted the oldest-ordered source tail discloses truncation.
`available` coverage means the captured retained source contains its creation
origin and all captured members remain; `partial` means origin is missing,
retention removed members or the snapshot cap omitted rows; `unavailable` means
no retained source events exist. Coverage is always retained-only, declares `version_lineage: unproven`, and is not a
claim of complete lifetime/version lineage. Missing audit is never fabricated
from the current request status. Only actual positive event versions are shown.

Redacted events include actual timestamp/action, current tenant-local actor
label, transition status, bounded attempt/version integers, explicit error
enums, and allowlisted integer proof versions/counts. Foreign or removed actors
become unavailable; nil actors are system. Current request failure strings are
normalized and evidence is reduced to the same proof/count allowlist. Object
keys, target digests, executors, credentials, arbitrary error text and raw
metadata are omitted. CSV omits authored request reasons, quotes cells,
neutralizes spreadsheet formulas and uses the fixed filename
`deletion-request-history.csv`. Export audit records contain only row count,
truncation, maximum and coverage enum, and are excluded from lifecycle history.

Qualification must include equal-timestamp keyset pages, later equal/backdated
inserts, empty snapshots, retained deletion, exact namespace binding, cap and
expiry, cursor tampering/expiry, redaction/foreign actors, formula handling,
real two-connection session revocation and session/step-up expiry waits,
bounded worker continuation, API error/no-store/CORS contracts, and rollback
row/job refusal. Authoring and parsing these tests is not execution evidence.

## Accepted boundary registry

The exact ADR-0093 composition transition publishes only Audit's
`ResourceHistoryQuery` and `ResourceHistoryPage`, and Governance's
`DeletionRequestTimeline`, `DeletionRequestHistoryExport`, `HistoryActor` and
`HistoryEvent`. `CommsWeb.DeletionRequestHistoryController` consumes the two
Governance history facade operations; Governance's history implementation
consumes Audit's exact `resource_history_page/1`. The snapshot schema remains
private to Audit, and `audit_resource_history_snapshots` is an owner-only source
table with access restricted to `CommsCore.Audit`.

`CommsWorkers.AuditHistorySnapshotPurgeWorker` consumes only the public
`Audit.purge_resource_history_snapshots/2` housekeeping operation. Core release
uses the content-free owner hazard count and existing fingerprint fragment.
Only active jobs for the configured exact purge worker whose JSON `continue`
argument is the boolean `true` add a continuation hazard. Routine empty-argument
cron jobs, false or string values, unrelated workers and terminal jobs do not
establish retained continuation work. All persisted snapshots, including
expired rows awaiting physical purge, remain hazards. The exact
`governance_history_v1` immutable capability covers those rows and continuation
jobs; the existing Repo technical owner performs the bounded exact-worker count
without publishing additional persistence access.
