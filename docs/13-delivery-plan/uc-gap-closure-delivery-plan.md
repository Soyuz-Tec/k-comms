# UC interface gap delivery plan

Date: 2026-10-04

Target: full unified communications, including telephony

Current increment: reliable use of existing member and administrator workflows

The interface assessment compared rendered K-Comms surfaces with the documented
workflows in Zoom Meetings, Team Chat, Phone, and Whiteboard. The assessment's
recommended next milestone is implemented in this change. The larger platform
capabilities below remain separate milestones with explicit acceptance gates.
This document is a scope ledger, not a claim that the full platform has shipped.

## Current increment

| Surface | Implemented improvement | Remaining gap or boundary |
|---|---|---|
| Desktop navigation | Labeled pinned navigation by default; content reserves its width; compact preference retained | Broader user research and navigation analytics |
| Mobile navigation | Calls launcher begins collapsed; primary controls remain reachable | Physical-device and background behavior qualification |
| Go To | Explicit workspace content search and Directory handoff | Cross-surface ranked results and keyboard result groups |
| Public instant room | Paste existing same-origin join links with validated readiness intent | Scheduled meeting lifecycle |
| Sign in | Validated member destinations survive authentication | SSO/MFA and enterprise identity lifecycle |
| Invitation / first workspace | Existing invitation scrubbing retains a safe return destination | Domain discovery and enterprise onboarding |
| Recovery / reset | Preserve safe destination without guest bearers in query strings | Additional account recovery factors |
| First-run onboarding | Direct notification and Audio & video setup links | Persisted onboarding progress and broader guidance |
| Guest entry | Shared paste-link entry and safe sign-in continuation | Richer host approval and guest account lifecycle |
| Guest room / menu | Existing admission links can be pasted; sign-in returns to guest context | Guest feature expansion remains policy-dependent |
| Inbox / chat | Distinguish title filtering from content search; scoped header search | Rich composition, saved items and synchronized drafts |
| New conversation | Searchable recipient selection with retained selected users | Richer group lifecycle and contact identity |
| Thread | Main-message author/status actions, reaction handling and retained failed edits | Rich composition and attachment-only replies |
| Search | Explicit workspace or conversation scope; URL-backed entry | Ranked/faceted unified retrieval |
| Notifications | Mentions/Messages and conversation filters; loaded-result scope disclosed | Persisted DND and additional event categories |
| Calls home / history | Meetings/Phone entry, Start/Join controls and truthful initiator/end-time attribution | Scheduling and individual room-participant attendance |
| Call prejoin | Audio Join follows microphone choice; muted join retained | Physical browser/device qualification |
| Connection test | General network guidance; detailed diagnostics secondary | Real regional/network measurement remains operational |
| Active call | Participants opens actual roster; separate Directory invite; automatic/gallery/speaker and local pin views | Captions, recording and advanced moderation |
| Phone dialer / history | History independent of admission; explicit setup states, refresh recovery and pre-call keypad | In-call DTMF, hold, transfer and carrier qualification |
| Directory People | URL-backed query, preserved rows and recoverable action/page errors | Rich profiles and availability |
| Directory Rooms | Preserved results and retryable action failures | Scheduled room lifecycle |
| Shared Files | Server filename/category filters before pagination; safe raster thumbnails, provenance and share continuation | Optional drive features require a product decision |
| Whiteboard | Unavailable explicit board does not open another conversation's board | Gallery, durable assets, versions and export workflows |
| Profile | Verified email presented as account information; tools available in every settings section | Avatar, timezone and richer profile model |
| Security | Friendly known device/session labels; full identifiers available on demand | MFA/SSO and richer session telemetry |
| Notifications settings | Clear message/mention presets that preserve other event preferences | Policy-backed DND and richer delivery schedules |
| Accessibility / Audio & video | URL-backed sections; reusable explicit local device tests and saved device choices | Physical-device assistive technology and media qualification |
| Administration navigation | Existing role-scoped entry retained | A broader administrative information architecture review |
| Workspace administration | Human units, grouped policy fields, impact/save state and retained exact raw values | Permission delegation and richer usage analytics |
| Phone administration | Provider → Number → Assignment → Verify guidance and accurate readiness | Number acquisition, dispatch provisioning and live acceptance |
| People administration | Role/status filters, sorting, counts and existing-data details | SCIM, bulk lifecycle and verified device metadata |
| Safety | Server status/priority/scan filters, case/action detail and source continuation | Bounded inventory remains capped at 100 rows |
| Governance | Conversation retention scope, reviewed edits and actual lifecycle/error/hold evidence | Historical execution timeline needs a durable model |
| Integrations | Existing webhook edit/re-enable command, event chooser and delivery details | Rich application catalog and integrations framework |
| Audit | Server free text/structured filters, cursor paging, full metadata and matching CSV scope | Operational limits still apply to exports |
| Service Operations | Existing operator-only controls retained | Broader status summaries and operational UX assessment |

## Acceptance criteria

1. A supported Files, Directory, Phone or Whiteboard destination survives sign-in
   and recovery; unsafe return URLs are rejected and guest credentials do not
   enter authentication query strings.
2. An unavailable explicit board never edits another board. Failed Directory,
   file, thread and phone reads/actions retain useful state and expose recovery.
3. File filters operate before paging within current active membership; audit
   list/export filters agree within the current authorized tenant. A terminal
   audit page has no continuation cursor.
4. Audio Join follows the visible microphone choice. Device tests require
   explicit consent, release tracks on close or late responses, and do not
   contend with conversation or phone media ownership.
5. Phone history remains readable when disabled or unassigned. Setup states
   distinguish configured deployment from line assignment and real carrier
   qualification. No provider is enabled by this release.
6. Thread, webhook, retention, moderation and administrator changes reuse their
   existing authorized/versioned commands and privileged verification gates.
7. Real rendered desktop/mobile browser journeys and accessibility checks pass,
   followed by required CI and the protected immutable release chain.

## Following milestones

| Milestone | Required implementation | Acceptance gate / dependency |
|---|---|---|
| Provision and qualify first phone line | Acquire carrier/DID, create restricted individual dispatch, securely configure trunks, qualify inbound/outbound/caller ID and recovery | User has supplied no carrier or number; require provider account and actual two-way audio evidence under ADR-0085 |
| Meetings lifecycle | Scheduled/recurring meeting model, timezone-safe invitations, calendar surface, cancellation and host policy | Define recurrence and provider calendar contracts; tenant/guest access and reminder/retry tests |
| Advanced phone controls | Durable DTMF, hold/resume, blind/consult transfer, voicemail and then queues/shared lines | Provider capability and call state/event contracts; multi-device ownership, failure/recovery and live carrier acceptance |
| Meeting artifacts | Captions/transcript/recording, consent and retention, secure playback and post-meeting retrieval | Recording/storage provider, policy and jurisdiction choices; access/revocation/deletion and media acceptance |
| Enterprise identity / availability | SSO/MFA/SCIM, profile/timezone, presence and policy-backed DND | Identity provider selection and security ADR; recovery, tenant isolation and lifecycle qualification |
| Rich content | Board gallery/assets/versions/export and unified retrieval; optional drive functions | Asset ownership/retention model; explicitly decide whether a drive is a product goal |
| UC launch qualification | Physical desktop/iOS/Android, background ringing limits, accessibility study, load/recovery and operations evidence | Provisioned dependencies, staged acceptance, backup/restore/rollback and protected production approval |

Implement these in independent reviewed increments. Each requires backend,
contracts, UI, negative controls, browser journeys, and actual runtime evidence;
a control rendered against a synthetic response does not establish provider
capability. SMS and advanced routing follow reliable calling and recovery.

## Architecture, release and evidence

[ADR-0086](../02-architecture/adr/0086-make-uc-workflow-context-and-retrieval-explicit.md)
records the additive retrieval/readiness contracts, destination validation and
device consent boundary. This increment needs no database migration and adds no
architecture exemption. Podman remains the repository's default container
engine. Native cloud tools are an environment fallback, not a runtime change.

Qualification and actual release receipts belong in the pull request and
release workflow artifacts. Follow the
[completion standard](../14-operations/development-to-production-completion-standard.md)
through required CI, protected merge, one attested digest, staging, independent
production approval and verification. An older digest is the application
rollback; no telephony history or other existing data is dropped.

Local browser tests use synthetic APIs and never dial a carrier. Live media,
physical devices, carrier acceptance, and production health require their own
evidence and must not be inferred from those tests.
