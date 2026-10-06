# UC interface design refresh

The next functional increment is documented in the
[daily workflow milestone](daily-workflow-milestone.md), including its
unfinished-work, Inbox, meeting, calling and availability acceptance criteria.

The refresh addresses the design review of the five public/authentication,
twelve member-workspace, and nine administration screens. It uses the existing
capability, role, identity, provider, and retention contracts.

## Implemented improvements

| Surface | Result |
|---|---|
| Public room, sign-in, guest entry, password recovery | Consistent brand and purpose; room details followed by invite/call; optional first message; password sign-in and organization sign-in clearly separated; entry choices fit the narrow phone view. |
| Shared workspace shell | Visible destination groups, direct Phone/Recordings/Documents links, one active Calls-or-Phone destination, compact page headings, and all mobile overflow destinations in You. |
| Inbox and Directory | Consistent controls and headings; formatting actions use the shared button language while preserving selection behavior and existing message/search flows. |
| Calls, Phone, Meetings | Clear conversation-call/calendar/phone boundaries; compact provider-off guidance; agenda-first scheduling, next or in-progress occurrence, preserved lobby/admission controls. |
| Recording retrieval | Recent calls with conversation, date, starter, and type; local search/filter and older-call pagination; exact-call artifacts, explicit content retrieval, and visible consent. |
| Files and Saved | Readable aligned inventory metadata/actions, message source/date, removal undo using the existing save endpoint, and invalidation after authority changes. |
| Whiteboard and Documents | Compact canvas header/gallery controls; document excerpts, last-edited context, continuation, and retention details. |
| Private rooms and You | Guided encrypted-device setup/recovery, accurate erasure limits, confirmed key removal, accessible verification dialogs, one profile save, and separate admin/operations shortcuts. |
| All nine admin pages | Section-specific headings, grouped navigation, compact mobile navigation, inventory-first layouts, deliberate creation disclosures, status meanings, source-aware usage metrics, and applied audit scope. |
| Phone administration | Setup, Numbers, Routing, Voicemail, Queues, and Caller menu tabs preserve mounted drafts and pending operations; keyboard tab navigation and setup transitions retain focus. |

## Qualification and delivery

The change extends behavior tests for account replacement, delayed responses,
profile edits, saved-message undo, disclosure drafts, artifact deep links and
pagination, and keyboard focus. Browser qualification includes narrow layouts,
authentication entry choices, first-run invitations, permission boundaries,
consent, step-up, retained versions, and applied report/export scope. Synthetic
screen captures are presentation evidence; routed fixture responses do not
qualify real provider connectivity or a production deployment.

The recording landing page is a paginated recent-call browser. Its filters apply
to loaded calls; artifact availability is checked only when a call is opened.
It does not claim a global recording inventory or perform automatic playback,
transcription, or summary generation. In-progress meeting labels describe the
scheduled time window rather than asserting that a live media session exists.

No dependency, backend API, schema, migration, deployment topology, or provider
configuration changes are required. Role/step-up, consent, private recovery,
provider-disabled, and governance protections remain in force. The small reviewed
UI asset allocation and its measured before/after evidence are recorded in
[web performance budgets](../11-testing-and-quality/web-performance-budgets.md).

Exact final validation counts, source revision, PR, immutable image, and release
receipts belong in the delivery record. Promotion follows the
[required completion standard](../14-operations/development-to-production-completion-standard.md).
Staging is intentionally offline; a published or merged design refresh must not
be represented as production deployed without its protected runtime receipts.
Physical-device, assistive-technology, and real-provider acceptance remain
separate from automated browser/fixture qualification.
