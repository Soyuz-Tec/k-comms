# Usability and Accessibility Validation

## Purpose

This protocol converts K-Comms usability readiness from an engineering estimate
into release evidence. Automated tests establish that the product is testable;
they do not substitute for representative people completing real tasks.

The protocol uses synthetic tenants, synthetic conversations, and test accounts.
Do not record message bodies, search terms, email addresses, tenant slugs,
invitation credentials, access tokens, or raw user identifiers.

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
- three tenant administrators, moderators, or compliance users;
- three support or platform operators;
- at least four participants who routinely use a screen reader, keyboard or
  switch access, low-vision zoom or high contrast, or voice/touch access; and
- at least two mobile-first participants.

Characteristics may overlap. Do not recruit only from the delivery team.
Sessions are 60–75 minutes, moderated, and recorded only with consent.

## Environment and fixtures

1. Deploy one immutable candidate to the internal staging composition.
2. Seed a synthetic workspace with representative members, public and private
   channels, direct conversations, message history, notifications, safe and
   quarantined attachments, one expired session, one failed notification, and
   content-blind operations conditions.
3. Give participants role-specific test accounts. Never use production data or
   credentials.
4. Enable a controllable disconnect and one failed-send condition.
5. Record browser, viewport, input/access method, revision, and environment.
6. Verify the normal security, durability, browser, and staging gates before
   the first session.

## Core tasks

| ID | Role | Task | Critical |
|---|---|---|---|
| `invite-first-message` | Member | Accept an invitation, sign in, and send a first direct message | Yes |
| `channel-collaboration` | Member | Find and join a channel, mention a teammate, reply, react, and open the thread | Yes |
| `attachment-safety` | Member | Attach a file and correctly interpret scanning or quarantine state | Yes |
| `history-search` | Member | Find an earlier message and return to the intended conversation | Yes |
| `send-recovery` | Member | Recover from a disconnect or failed send without losing the draft | Yes |
| `notification-control` | Member | Read a notification and change notification preferences | No |
| `device-revocation` | Member | Revoke a synthetic device or session and explain the effect | Yes |
| `admin-access` | Admin | Invite a person, review and change a role/status with a reason, and revoke a session | Yes |
| `moderation-review` | Moderator | Review and resolve a synthetic report without entering an unauthorized area | Yes |
| `audit-evidence` | Compliance | Filter and export bounded audit evidence | No |
| `ops-triage` | Operator | Identify a queue/provider condition, user impact, owner, and safe runbook | Yes |

For every task capture unassisted completion, assisted completion, failure,
duration, critical errors, backtracks, facilitator interventions, unintended
destructive actions, and a 1–7 Single Ease Question response. Time is diagnostic
and must be stratified by access method; never use it to penalize assistive-
technology users.

After all tasks, collect the standard ten System Usability Scale responses and
confidence in sensitive-action consequences on a 1–5 scale. Keep qualitative
notes separate from the scorecard if they could contain identifying data.

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
structured evidence. A zero exit status means the quantitative gates passed;
the release approver must still review qualitative findings and the manual WCAG
assessment.

## Internal pilot

After the formal study passes, run a two-week pilot with 20–30 internal users,
at least two tenant administrators, and two trained operators. Exit requires:

- at least 80% invited-user activation;
- at least 60% weekly active usage;
- fewer than 0.2 usability support requests per active user;
- no accessibility blocker, Sev-1/Sev-2 incident, acknowledged-message loss,
  or tenant-boundary failure; and
- retained sign-off from product, accessibility, security, and operations.

The pilot validates controlled internal use. It does not close the external
production infrastructure and organizational gates in
`docs/10-infrastructure-and-deployment/environments/production.md`.
