# Scheduled meetings operations

Scheduled and recurring meetings are owned by Calls. Members use **Meetings**
to select an existing active conversation, a local start, an IANA timezone,
duration, finite daily/weekly recurrence, reminder and host policy. Conversation
membership remains the invitation/access scope. The host or a current
conversation owner/moderator can edit an unstarted series or cancel a series.
Mutations require the current schedule version; reload after a conflict.

## Calendar and timezone contract

- At most 52 occurrences, interval 1–4, last start within 366 days; 5–480 elapsed
  minutes per occurrence. Monthly/unbounded recurrence is rejected.
- Each occurrence preserves the chosen local wall time across DST. Ambiguous
  or nonexistent local start times reject the series; select a different time.
- Existing materialized UTC starts remain stable across timezone-data updates.
  Timezone data updates require the normal dependency release qualification.
- Calendar requests cover at most 93 days and return at most 500 occurrence
  rows before deduplication; `meta.truncated` discloses a capped request.
- **Download invitation** returns an authenticated ICS with stable occurrence
  UIDs and version numbers. Import the replacement after editing or cancelling.
  Cancelled VEVENTs use the existing UID and newer sequence. ICS contains no
  guest bearer or provider credential.
- Google/Microsoft synchronization is unavailable. Enabling an external calendar
  requires actual provider credentials, scoped OAuth/token storage, revocation,
  failure/recovery contracts and provider acceptance. ICS import is supported
  without those credentials.

## Host, guest and admission controls

Guests never gain schedule-management or calendar-list access. Guests can join
a linked meeting only when the host explicitly enables guests and the existing
conversation guest admission is valid. Enabling guests does not create or widen
a guest link. Disabling join-before-host means the original host starts the
occurrence; after host start, authorized participants may join. Moderator
management rights do not silently transfer the original host identity.

The scheduled admission window opens 15 minutes before start and closes at the
scheduled end. Existing Calls owns ongoing media and its expiry; duration does
not imply automatic forced disconnection. Cancellation denies new credentials,
revokes admitted participants and creates durable provider-eviction work.
Cancelling a meeting does not remove conversation membership or call history.

## Reminders and recovery

One reminder offset is supported: 0 (at start) through 10,080 minutes (one week
before). `CommsWorkers.MeetingReminderWorker` uses the existing Oban `media`
queue with ten attempts. Inspect job state/attempts and the ordinary operations
notification views when delivery fails; never print bearer/provider tokens.

The occurrence's `reminder_sent_at` marker and `meeting.reminder.v1` outbox
event commit together. Worker retries return `already_delivered`; old edited
versions, cancelled meetings and occurrences past their end return `ignored`.
An early job snoozes and retries. Outbox publication and email/push retries keep
their existing idempotency keys and channel policies. Current active membership
is resolved when fanout occurs. A reminder already published before cancellation
can arrive before or alongside its cancellation notice.

If media is unavailable, scheduling/ICS still stores authorized calendars when
tenant call policy allows it; starting waits for real LiveKit readiness. Provider
failure leaves no partially linked started occurrence or leaked credential.
Ordinary calls retain existing behavior unless associated with a scheduled
occurrence. Never mark provider media qualified from a synthetic browser test.

## Migration, qualification and rollback

Migration `20261005000100_add_scheduled_meetings.exs` creates Calls-owned tables
and bounded indexes/constraints; it changes no existing source data. Additive
`20261005001100_add_meeting_erasure_fence.exs` introduces author-lineage and
erasure-proof fields that remain private to Calls. A
scrubbed host may be null internally, and erased records are excluded from
the existing public MeetingView. Retain these tables and fields when rolling
back the application digest. Retry fencing needs opaque
IDs and versions; it does not justify retaining an erased host's authored title
or other readable schedule fields. Governed user/conversation erasure must
scrub those fields, suppress get/calendar/ICS/search retrieval and cancel
admission/reminders before recording owner completion proof. Legal holds block
destructive cleanup and completion; cancelled status alone is not erasure proof.
An approved rollback target requires `scheduled_meeting_lifecycle_v1` while
readable meeting history lacks verified erasure, scheduled meetings/occurrences,
policy-linked active rooms or active reminder jobs remain. The current release's
quiesced owner-count/job preflight refuses unsupported retained work and unknown
inventory; the target must retain its actual immutable capability declaration.
Use a compatible bridge or roll forward instead of deleting schedules or
claiming that preserved tables alone make an older binary safe.
The independent review found a P1 gap in cancelled host-title erasure and rollback
inventory. Owner erasure/proof and held-scope-safe cleanup are implemented in source;
earlier lifecycle-only qualification does not prove this fix. Qualify user and
conversation erasure across active/cancelled schedules, retained get/calendar/
ICS/search views, held subjects, late reminders and prior completed requests.
Governance must record `meeting_erasure_version: 1` only after its owner
preparation and pending proof succeeds. Older completed requests without that
evidence need the same repair. Unknown legacy authorship cannot be treated as
erased or make an incompatible rollback safe.
Legacy author repair requires complete version and actor attribution from the
public Audit projections; missing evidence refuses cleanup. The new migration's
down path refuses retained tombstones or scrubbed null hosts and never rebuilds
an erased identity. Use an approved forward repair or compatible bridge.
Qualify database migration, schedule/member/guest denial, DST recurrence,
version conflicts, cancellation eviction, reminder retry and real rendered
calendar workflows in staging. Follow the required backup/restore/rollback
gates and protected production approval before promotion.

The architecture is recorded in
[ADR-0087](../02-architecture/adr/0087-add-durable-scheduled-meetings.md).
