# ADR-0096: Bounded owner-projected usage reports

Status: Accepted
Qualification: source boundary decision accepted; execution and protected delivery pending.
Date: 2026-10-05  
Owners: IdentityAccess; Conversations; ConversationContent; Calls; Telephony; Web

## Context

The administrator screen exposes current admission quotas but does not provide
daily aggregate usage, retained storage totals, or an export using the same
filters. An aggregate report must preserve canonical table ownership, current
workspace authority, and governed erasure. It cannot reconstruct records that
were deleted or establish billing, provider delivery, participant attendance,
or lifetime totals from retained operational rows.

## Decision

Each canonical owner exposes exactly `usage_projection/2` through its existing
facade: `Accounts`, `Conversations`, `Messaging`, `Attachments`, `AudioCalls`,
and `Telephony`. Each owns a named `UsageQuery` and `UsageProjection`. A query
contains only a tenant UUID and inclusive UTC `from` and `through` dates. The
owner independently validates the exact tenant and a range of at most 31 days,
ending no later than the current UTC date. SQL predicates use the half-open
interval from the first UTC midnight through the midnight after `through`.

Every projection reads only its owner's schema through its own repository.
There are no foreign schema imports, cross-owner SQL joins, per-person metrics,
content, telephone numbers, file names, or resource identifiers in results.
An owner retains current workspace-human owner/administrator authority and
recent authentication through its read transaction. It uses the exact
IdentityAccess `lock_content_write_grant/2` operation, or its own helper in the
Accounts owner. Its canonical order is admission quota advisory, active Tenant
SHARE, actor User NO KEY UPDATE, Device SHARE, Session SHARE. Queries refresh
the remaining absolute 15-second SQL budget before each aggregate; the
repository transaction is capped at 20 seconds. Actor authority and elapsed
budget are checked again before returning.

Web owns the application composer, `CommsWeb.UsageReports`, which calls all six
facades and performs no repository access. Sources run in separate owner
transactions. A failed source query becomes `status: unavailable, data: null`,
while a successful empty source returns zero metrics and a null earliest
retained timestamp. Authorization, recent authentication, and invalid-range
errors abort the complete response; they cannot be converted to partial data.
Only each source’s exact named projection DTO is accepted; unexpected structures
are unavailable and disclose no persistence fields. Database errors disclose no
SQL text. Source observations are independent;
this is not a transactionally consistent snapshot across owners. Each source
observation marks the start of its bounded READ COMMITTED query sequence and
the duration cutoff; successive statements can observe later committed
retained state. Exports do not claim immutable snapshot membership.

The final JSON or CSV encoder runs through the exact Accounts facade
`with_usage_report_disclosure/2`. Its trusted zero-argument callback returns
only `{:ok, binary}` or `{:error, atom}`. This grants no repository adapter or
arbitrary value transport. Accounts retains current workspace-human
owner/administrator authority with recent authentication while encoding,
rechecks it afterward, and refuses a body larger than 1 MiB. The same absolute
15-second authority budget and 20-second transaction cap apply.

`GET /api/v1/admin/usage` and `GET /api/v1/admin/usage/export` accept only
`from` and `through`. Defaults cover the last 30 UTC dates. Both use the same
parser, sources, owner checks, and metrics. JSON identifies each source's
availability. CSV includes availability, UTC range, coverage, and source
observation timestamps on each row, with a maximum of 5,000 data rows, quoted
cells, spreadsheet-formula neutralization, and an observed export receipt.
Responses use private, no-store caching. Neither endpoint creates an export
job or persists an export artifact.

## Metric definitions and coverage

All reports declare `coverage: currently_retained_records` and
`lifetime_complete: false`. Each available source returns `observed_at` and
`earliest_retained_at`; the latter is the earliest retained row, not proof of
complete history. Daily bins describe retained creation/start cohorts and
their current status at observation, not a historical status snapshot.

| Source | Current metrics | UTC daily metrics |
| --- | --- | --- |
| Identity | Active human and service rows; guests excluded | Retained human and service creations |
| Conversations | Unarchived conversation count | Retained direct/group/channel creations |
| Messages | Retained message rows | Creations and current active/deleted/moderated status |
| Attachments | Ready verified original count and declared bytes | Creations and currently ready original count/bytes |
| Calls | Current active/ending status rows | Starts by audio/video and current status, observed room lifecycle seconds |
| Telephony | Current ringing/answered status rows | Starts by direction and current status, observed answered lifecycle seconds |

Ready attachment totals require ready status, clean scan, an exact object
version and ETag, and verified checksum equality. Deleted, pending, and
quarantined rows contribute no ready bytes. These are original declared bytes;
they exclude variants, media artifacts, prior object versions, provider
storage overhead, and external storage billing.

Duration aggregates sum whole seconds of each retained call overlapping each
UTC day, bounded by its start or answer, end, fixed expiry, and the source's
observation time. A call started before the selected range may contribute
duration without contributing a start. Ringing time contributes no telephone
answered seconds. Room lifecycle duration is not verified media activity or
participant attendance; telephone lifecycle duration is not a carrier CDR.
Current status counts can include durable rows awaiting lifecycle cleanup and
do not assert current provider connectivity.

Governed erasure is reflected by the owner's current retained state: message
tombstones shift current status bins, removed rows stop contributing, and
deleted attachments stop contributing ready bytes. No report stores author
identifiers or an additional historical copy of erased content. This stateless
feature adds no table, background job, or rollback capability.

## Exact boundary additions

The only new owner operations are six `usage_projection/2` methods and
`Accounts.with_usage_report_disclosure/2`. The only consumer of projections and
the disclosure callback is `CommsWeb.UsageReports`. The five non-identity
`UsageReports` implementation modules consume existing
`Accounts.access_grant/1` and `lock_content_write_grant/2`; the Accounts
implementation uses owner-internal helpers. All twelve named query/projection
DTOs remain owned by their corresponding context. These additions require an
exact approved facade/contract transition after rebasing the qualified prior
milestone; ADR-0093 records that immutable-parent-bound composition. The frozen
inventory classifies only each exact `usage_projection/2` and
`Accounts.with_usage_report_disclosure/2` as public delivery operations. The
query/projection pairs are `CommsCore.Accounts.UsageQuery/UsageProjection`,
`CommsCore.Conversations.UsageQuery/UsageProjection`,
`CommsCore.Messaging.UsageQuery/UsageProjection`,
`CommsCore.Attachments.UsageQuery/UsageProjection`,
`CommsCore.AudioCalls.UsageQuery/UsageProjection`, and
`CommsCore.Telephony.UsageQuery/UsageProjection`.

The only direct projection and disclosure consumer is
`CommsWeb.UsageReports`; its controller consumes that Web composer rather than
foreign persistence. The five non-identity implementation callers of the
existing IdentityAccess grant operations are exactly
`CommsCore.Conversations.UsageReports`, `CommsCore.Messaging.UsageReports`,
`CommsCore.Attachments.UsageReports`, `CommsCore.AudioCalls.UsageReports`, and
`CommsCore.Telephony.UsageReports`. No ownership or allowed-dependency edge is
widened, no implementation module is published, and no persistence exception
is added. The immutable empty architecture baseline remains unchanged.

## Qualification

Implementation source and seventeen meaningful source tests are present. Source
parsing passed; compilation and test execution are pending the parent
milestone's qualification and rebase. Cases cover inclusive UTC boundaries
under a non-UTC SQL session, tenant/scope/role/proof denial, real governed
message erasure, verified bytes exceeding 32-bit values, duration clipping,
post-encoding expiry, unavailable versus empty sources, identical HTTP export
filters, bounded CSV rows, spreadsheet escaping, and explicit allowed-origin
receipt exposure with unapproved-origin denial. Provider, staging,
release, and production completion remain separate gates.
