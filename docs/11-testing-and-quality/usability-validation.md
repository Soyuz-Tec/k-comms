# Usability and Accessibility Validation

## Purpose

This protocol converts K-Comms usability readiness from an engineering estimate
into release evidence. Automated tests establish that the product is testable;
they do not substitute for representative people completing real tasks.

The protocol uses synthetic tenants, synthetic conversations, and test accounts.
Do not record message bodies, search terms, email addresses, tenant slugs,
invitation credentials, access tokens, raw user identifiers, participant or
approver names, contact details, IP addresses, recordings, support-ticket text,
or free-form qualitative notes in the scorecard. Retain qualitative research in
the separately approved research system.

## Readiness score contract

The engineering baseline before this improvement increment was **84/100**. A
post-implementation score may be reported as **provisional, capped at 89/100**
until the participant study and pilot below pass. The validated target is
**93/100**:

| Dimension | Baseline | Validated target |
|---|---:|---:|
| Core communication workflows | 28/30 | 29/30 |
| Admin and operations interfaces | 17/20 | 18/20 |
| Reliability and responsiveness | 19/20 | 19/20 |
| Accessibility and responsive design | 12/15 | 14/15 |
| Onboarding and real-world adoption | 8/15 | 13/15 |
| **Total** | **84/100** | **93/100** |

No release note may call the score validated unless the evidence identifies the
immutable application revision, environment, dates, participant mix, results,
open defects, and approver.

## Participants

Run a five-person formative baseline before the validation study. The formal
study has 12 participants:

- six members who use communication tools in everyday work;
- one tenant administrator, one moderator, and one compliance user;
- three support or platform operators;
- at least four participants who routinely use a screen reader, keyboard or
  switch access, low-vision zoom or high contrast, or voice/touch access; and
- at least two mobile-first participants.

Characteristics may overlap. Do not recruit only from the delivery team.
Sessions are 60–75 minutes, moderated, and recorded only with consent.
The structured study contains exactly 12 unique synthetic participant codes:
six `member`, one `admin`, one `moderator`, one `compliance`, and three
`operator` sessions. Accessibility and mobile characteristics may overlap with
those cohorts.

## Environment and fixtures

1. Deploy one immutable candidate to the internal staging composition.
2. Seed a synthetic workspace with representative members, public and private
   channels, direct conversations, message history, notifications, safe and
   quarantined attachments, one expired session, one failed notification, and
   content-blind operations conditions.
3. Give participants role-specific test accounts. Never use production data or
   credentials.
4. Enable a controllable disconnect and one failed-send condition.
5. For media evaluation, use synthetic direct and three-person group calls with
   non-sensitive camera test patterns and a synthetic share source. Never
   capture a participant's personal desktop, notification, or unrelated app.
6. Record browser, viewport, input/access method, revision, and environment.
7. Verify the normal security, durability, browser, and staging gates before
   the first session.

## Core tasks

| ID | Structured cohort | Scoring category | Task | Critical |
|---|---|---|---|---|
| `invite-first-message` | `member` | `invite` | Accept an invitation, sign in, and send a first direct message | Yes |
| `channel-collaboration` | `member` | `routine` | Find and join a channel, mention a teammate, reply, react, and open the thread | Yes |
| `attachment-safety` | `member` | `routine` | Attach a file and correctly interpret scanning or quarantine state | Yes |
| `history-search` | `member` | `routine` | Find an earlier message and return to the intended conversation | Yes |
| `send-recovery` | `member` | `routine` | Recover from a disconnect or failed send without losing the draft | Yes |
| `notification-control` | `member` | `other` | Read a notification and change notification preferences | No |
| `device-revocation` | `member` | `other` | Revoke a synthetic device or session and explain the effect | Yes |
| `admin-access` | `admin` | `admin_safety` | Invite a person, review and change a role/status with a reason, and revoke a session | Yes |
| `moderation-review` | `moderator` | `admin_safety` | Review and resolve a synthetic report without entering an unauthorized area | Yes |
| `audit-evidence` | `compliance` | `admin_safety` | Filter and export bounded audit evidence | No |
| `ops-triage` | `operator` | `ops_safety` | Identify a queue/provider condition, user impact, owner, and safe runbook | Yes |

Every participant completes every task assigned to their structured cohort.
Task IDs, cohorts, scoring categories, and critical flags are fixed by this
matrix; changing them requires a protocol and schema version change.

`unassisted` means the participant completed the task with zero facilitator
interventions and zero critical errors. `assisted` requires at least one
recorded facilitator intervention. A failed task may record zero or more
interventions and critical errors, but it never counts as completed.

For every task capture unassisted completion, assisted completion, failure,
duration, critical errors, backtracks, facilitator interventions, unintended
destructive actions, and a 1–7 Single Ease Question response. Time is diagnostic
and must be stratified by access method; never use it to penalize assistive-
technology users.

After all tasks, collect the standard ten System Usability Scale responses and
confidence in sensitive-action consequences on a 1–5 scale. Keep qualitative
notes separate from the scorecard if they could contain identifying data.

## Structured study evidence

Start from
[`usability-study-template.json`](usability-study-template.json) and validate
the resulting version 2 record against
[`usability-study.schema.json`](usability-study.schema.json). The template is
an intentionally incomplete, non-passing example; copying it is not evidence
that a study or human gate occurred.

Each session records a unique synthetic participant code, fixed cohort,
access method, mobile-first status, browser and version, CSS-pixel viewport,
ten SUS responses, sensitive-action confidence, and the exact assigned task
receipts. Each task receipt records outcome, duration, critical errors,
backtracks, facilitator interventions, Single Ease Question score, and any
unintended destructive action. An `unassisted` outcome requires zero facilitator
interventions; an `assisted` outcome requires at least one. This invariant is
enforced by both the schema and scorer so coached work cannot satisfy an
unassisted release threshold.

The release-level record also identifies the full Git revision, environment,
study dates, security, authorization, tenant-isolation, durability, and staging
regression status, coded accessibility findings, the manual WCAG and
assistive-technology matrix status, and a role-only approver receipt. Approval
references are opaque evidence identifiers; do not put a person's name,
address, ticket text, or other identifying content in them.
The study completion date and release approval date must be valid UTC calendar
dates no later than the UTC day on which the scorer runs; future-dated receipts
are rejected.

## Accessibility matrix

Automated checks run against representative login, invitation, recovery, empty,
populated, error, offline/reconnecting, search, thread, notification, settings,
admin, and operations states. A passing automated scanner is necessary but is
not a conformance claim.

Manually exercise:

- Windows 11 Edge with NVDA;
- Windows 11 Chrome with JAWS;
- Windows keyboard-only use in Edge and Firefox;
- Windows High Contrast and 400% zoom;
- macOS Safari with VoiceOver;
- iOS Safari with VoiceOver;
- Android Chrome with TalkBack;
- 320 CSS px reflow, 200% text, WCAG text spacing, reduced motion, forced
  colors, and real touch at 320–390 CSS px; and
- focus visibility above sticky headers, mobile navigation, drawers, dialogs,
  and the virtual keyboard.

Verify skip navigation, route orientation, authentication tabs, every dialog,
Escape, Tab/Shift+Tab containment, focus restoration, composer, search results,
threads, notifications, errors, and destructive confirmations.

For calls, manually verify understandable audio/video choice, default-off
camera and microphone, preview/device selection, non-color capture and speaking
state, accessible participant names, logical grid focus order at responsive
sizes, keyboard camera/mute/share/leave/end controls, persistent sharing status,
immediate stop sharing, focus restoration, permission-denial recovery, and
complete track cleanup. Screen-reader users must receive state changes without
continuous speaking/activity announcements.

## Validated release gates

All of the following must pass:

- at least 90% unassisted completion across critical tasks;
- at least 90% unassisted success for `invite-first-message`, with median time
  at or below five minutes;
- at least 95% unassisted success for routine messaging and search tasks;
- at least 90% unassisted success for admin safety tasks, with zero unintended
  destructive actions;
- median Single Ease Question at least 5.5/7;
- mean System Usability Scale at least 80, with no role cohort below 75;
- 100% completion of critical tasks in keyboard and screen-reader sessions;
- no open critical or serious accessibility defect;
- no unresolved WCAG 2.2 A or AA failure in the audited scope; and
- no security, authorization, tenant-isolation, durability, or staging
  regression.

Run `node scripts/score_usability_study.mjs <study.json>` to validate the
structured evidence. The output reports `quantitative_pass` separately from
the overall `pass`. A zero exit status requires the quantitative gates, manual
WCAG and assistive-technology receipts, regression gates, and role-only release
approval receipt to pass. The scorer verifies receipt structure and thresholds;
it cannot perform the human study, accessibility assessment, or approval.

## Internal pilot

After the formal study passes, run a pilot for at least 14 elapsed days with
20–30 invited internal users, at least two tenant administrators, and two
trained operators. Exit requires:

- at least 80% invited-user activation;
- at least 60% weekly active usage;
- fewer than 0.2 usability support requests per active user;
- no accessibility blocker, Sev-1/Sev-2 incident, acknowledged-message loss,
  or tenant-boundary failure; and
- retained sign-off from product, accessibility, security, and operations.

Activation is `activated_user_count / invited_user_count`. Weekly active usage
is calculated for every required weekly receipt as
`active_user_count / invited_user_count`; every interval must meet the 60%
floor. Weekly receipts are a complete sequence, not a sample: derive starts at
`pilot_started_on`, then every seven elapsed days while the start is before
`pilot_completed_on`. Each receipt covers that start through the next derived
start, or through `pilot_completed_on` for a shorter trailing interval. The
scorer rejects gaps, omissions, duplicate, out-of-order, or shifted dates so a
pilot cannot retain only favorable weeks. Usability support rate is
`usability_support_request_count / active_user_count`, where the denominator is
the distinct number of users active at least once during the pilot.

Start from
[`usability-pilot-template.json`](usability-pilot-template.json), validate it
against [`usability-pilot.schema.json`](usability-pilot.schema.json), and run:

```text
node scripts/score_usability_pilot.mjs <pilot.json>
```

The pilot template deliberately records the formal study, staging receipt, and
all four human sign-offs as unfulfilled. Do not change those statuses until the
corresponding exact-revision evidence and role-only approval references exist.
The scorer consumes only aggregate counts and opaque receipt references; never
add participant identities or support-ticket content.

The pilot validates controlled internal use. It does not close the external
production infrastructure and organizational gates in
`docs/10-infrastructure-and-deployment/environments/production.md`.
