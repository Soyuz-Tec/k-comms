# Usage report qualification

The implementation described in [ADR-0096](../02-architecture/adr/0096-bounded-owner-projected-usage-reports.md)
is in source. Compilation, automated execution, protected release, and staging
qualification remain pending. No external provider is required to query
retained local owner records.

Use a synthetic active workspace-human owner or administrator with recent
password verification. Request `/api/v1/admin/usage` and
`/api/v1/admin/usage/export` with the same inclusive `from`/`through` UTC dates.
Confirm at most 31 dates, matching response/export ranges, UTC receipt headers,
private no-store caching, and a source observation timestamp. Test ordinary
members, conversation-only elevated humans, revoked sessions, and expired
recent verification; none may receive report facts.

Run the meaningful backend cases in
`apps/comms_core/test/usage_projection_test.exs` and the HTTP/composer cases in
`apps/comms_web/test/usage_report_test.exs` after rebasing the previous qualified
milestone. Qualify SQL sums as integers, midnight boundaries under a non-UTC
database session, calls spanning the start/end of the range, unanswered phone
calls, and current status cohorts. Demonstrate real governed message erasure
and deleted ready attachments changing only their defined aggregate metrics.

Independently verify the final disclosure helper's exact current actor proof
after encoding and its byte bound. An owner query outage must mark only that
source unavailable with null data, while successful empty sources report zero.
An authority outage or denial must refuse the complete disclosure. Confirm
that failed query text and identifiers never enter JSON, CSV, or export
metadata. Validate source boundaries with the frozen facade inventory and
original empty architecture baseline; do not add exceptions.

These totals describe currently retained records. Earliest retained timestamps
do not prove lifetime completeness. Current statuses are observed state,
creation bins are retained cohorts, attachment bytes count verified originals,
and call durations describe bounded lifecycle overlap. Do not reconcile them
against carrier bills, object-storage bills, attendance, or lifetime totals as
if they measured those products. A broader reporting product needs explicit
metric semantics and qualified source integrations.

Record actual automated, browser, immutable-image, and staging receipts before
marking qualification complete. Source parsing alone is not a runtime receipt.
