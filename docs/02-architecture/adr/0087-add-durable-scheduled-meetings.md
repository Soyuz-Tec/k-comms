# ADR-0087: Add durable scheduled meetings to Calls

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Calls, Web, NotificationDelivery
- **Related decisions:** ADR-0025, ADR-0043, ADR-0062, ADR-0075, ADR-0086

## Context

Calls owns real-time conversation sessions, admissions, participant revocation
and provider expiry. It previously persisted no scheduled or recurring meeting.
Calendar invitations must refer to durable, authorized schedules rather than
fabricated call history. There are no Google or Microsoft calendar credentials
or independently qualified calendar synchronization providers.

## Decision

Keep scheduling within the Calls bounded context and its existing
`CommsCore.AudioCalls` facade. Add owner-private `meetings` and
`meeting_occurrences` tables and the Ecto-free `MeetingView` public contract.
Persist foreign identity/conversation references as scalar identifiers. Reuse
IdentityAccess access grants and Conversations membership/read projections;
never query foreign canonical persistence directly.

The following nine facade operations are deliberately added to the frozen
adapter-public inventory under ADR-0075: `schedule_meeting/3`,
`update_meeting/3`, `cancel_meeting/3`, `get_meeting/2`, `list_meetings/2`,
`meeting_calendar/2`, `start_meeting/6`, `deliver_meeting_reminder/3`, and
`search_meetings/2`.
The public-facade snapshot/hash and manifest transition must record this exact
additive surface and the `MeetingView` contract. Calls publishes
`meeting.scheduled.v1`, `meeting.updated.v1`, `meeting.cancelled.v1`, and
`meeting.reminder.v1`; NotificationDelivery consumes them through the existing
outbox publication path. No new business dependency edge or boundary exemption
is introduced. The strict zero-finding baseline remains unchanged.

An active human workspace member may schedule in an active conversation. The
original host and current conversation owner/moderator may edit or cancel.
Every mutation takes the existing conversation/access locks, then the meeting
lock, checks the submitted version, and contributes occurrence/job/audit/outbox
writes to one owner transaction. Edits replace unstarted series only. A started
series requires cancellation and a new schedule; its historical call
association is preserved. Cancellation revokes every associated admission and
queues provider eviction through the established Calls lifecycle, and subsequent
generic call admission must pass the scheduling policy guard.

Recurrence is finite: no recurrence, daily, or weekly; interval 1–4; count 1–52;
last start within 366 days of scheduling. Duration is 5–480 elapsed minutes and
one reminder offset is 0–10,080 minutes. Each local wall-clock occurrence is
converted independently using the IANA zone database supplied by `tzdata`.
UTC week arithmetic must not drift a 09:00 weekly meeting across DST. Ambiguous
and nonexistent local starts reject the entire schedule. Automatic timezone
data downloads are disabled; timezone updates follow the reviewed dependency
release path. Existing schedules retain their materialized UTC instants when
the timezone database changes.

Host policy defaults to members only and host-start required. If explicitly
enabled, already authorized conversation guests may join the associated call;
the schedule does not create an identity, guest link or admission. Join-before-
host permits another active human conversation member to start an occurrence.
Occurrence starts are admitted from 15 minutes before start until its scheduled
end. This is an admission window, not an automatic forced meeting termination:
existing call expiry and participant revocation continue to own ongoing media.

Member calendar reads use current active membership before returning results,
cover at most 93 days, and disclose a 500-occurrence result bound. ICS export is
authenticated and returns one stable, versioned UTC VEVENT per occurrence,
escaped/folded according to the calendar wire format. Cancellation exports
cancelled VEVENTs with the same UIDs. No bearer or media token enters the ICS.
Google/Microsoft synchronization capability is explicitly false until a real
adapter, credentials, provider contract and live qualification are supplied.

Unified retrieval composes `search_meetings/2` through the same facade. It uses
literal case-insensitive title matching, optional conversation scope, current
active membership, a UTC window of at most 732 days (default one year before
and after observation), and 1–50 results with an explicit truncation flag. The
result is a bounded source contribution, never a claim of exhaustive global
meeting history.

Existing Oban `media` queue executes the reminder worker. An exact configured
worker is authorized by `RuntimePorts`; each reminder locks its meeting and
occurrence, checks the current version/status/due time and appends the outbox
event together with its durable sent marker. Retries produce one event. Edited,
cancelled and expired occurrences become no-ops. Notification fanout independently
resolves current active membership and channel preferences; delivery failures use
existing retry/idempotency mechanisms. A reminder already published before
cancellation may be delivered alongside the later cancellation notification.

## Consequences

The migration is additive and rollback retains schedule/history tables. There
is no new service, process, supervisor, database owner or real-time media stack.
External calendar modifications require downloading/importing the updated ICS;
the product does not claim automatic third-party calendar synchronization.
Guests continue to use existing conversation admission, never an unprotected
schedule identifier. Recurrence exceptions and monthly/unbounded recurrence
are deliberately outside the finite first scheduling contract.

## Validation and rollout

Require meaningful tests for tenant/session/membership denial, host/moderator
authority, stale versions, cancellation admission revocation, reminder retries,
DST boundaries, recurrence bounds and ICS escaping. Browser journeys cover
calendar/list scheduling, retained edit failure, cancellation and invitation
download against explicitly synthetic API fixtures; they do not qualify media
or external providers. Compilation, migration/architecture checks, backend/web
tests and the protected immutable release chain remain mandatory. Preserve the
same qualified digest between staging and production and do not bypass the
independent production approval.

See the [meetings runbook](../../14-operations/meetings.md) for operational
limits, reminder diagnosis, provider prerequisites and rollback.
