# Mobile Communication Experience Delivery Plan

**Date:** 2026-07-24
**Delivery branch:** `agent/mvp-staging-completion`
**Runtime target:** local Podman composition, with the same-image staging path retained
**Product target:** responsive K-Comms web application for desktop and mobile browsers

## Outcome

Deliver a stable, low-friction communication experience with:

- a five-destination member shell: Inbox, Calls, Directory, Files, and You;
- direct, group, and room messaging with durable replay;
- safe message-owned file upload and authorized file discovery;
- one-to-one and group audio/video calls with prejoin controls and screen sharing;
- role-gated administration and operations without crowding member navigation;
- accessible layouts from 320 CSS pixels through desktop;
- exact-revision build, deployment, browser verification, and rollback evidence.

The implementation extends the existing Phoenix/React/LiveKit foundation. It does
not replace the working message timeline, attachment safety lifecycle, call
authorization, media teardown, or modular-monolith boundaries.

## Scope decisions from the plan audit

| Mockup or proposal | Delivery decision | Reason |
|---|---|---|
| Separate Calls and Video destinations | One Calls destination | Audio and video are modes of the same call lifecycle. |
| Individuals and Rooms as separate inboxes | One Inbox with All, Unread, Direct, and Rooms filters | Users see all pending work without switching inboxes. |
| Detached file cards | Every file remains owned by its source message and conversation | Preserves authorization, retention, audit, and download safety. |
| Scheduled filter | Do not expose until a scheduling aggregate exists | A non-functional affordance would be misleading. |
| Missed/declined labels | Do not infer from ended calls; add only after durable invitation/provider facts exist | Existing call rows do not prove ringing or answer state. |
| Recording, transcription, and captions | Excluded from this delivery | ADR-0025 requires a separate security and architecture decision. |
| Native App Store application | Excluded | Mobile delivery is the responsive, browser-installable PWA; no store package or native wrapper is required. |
| Progressive web application | Included | Users can install from the browser; private communication data remains network-only and is not an offline cache. |
| Large client rewrite | Incremental vertical slices with compatibility routes | Protects sequencing, read cursors, deep links, media cleanup, and accessibility behavior. |

## Click-friction targets

Action counts are measured as pointer clicks, taps, keyboard activations, or
submitted forms. Two baselines are retained:

- **daily-use baseline:** from the default signed-in Inbox landing;
- **end-to-end baseline:** from a signed-out browser or invitation link.

Required authentication, step-up, reason entry, destructive confirmation, and
explicit media consent are recorded as justified exceptions and are never
removed merely to improve an action count.

| Task | Target |
|---|---:|
| Sign in and reach Inbox | 1 submitted form after credentials |
| Accept invitation and reach Inbox | 1 submitted account form |
| Open an unread conversation | 1 action |
| Start or resume a direct message from Directory | 1 action |
| Open a room from Directory | 1 action |
| Open a file's source conversation | 1 action |
| Start an audio or video call from a conversation | 1 action to lobby, 1 explicit join/start action |
| Rejoin an active call from Calls | 1 action to lobby |
| Reach profile, devices, notifications, or settings | 1 destination action |
| Reach Admin or Operations when authorized | At most 2 actions |
| Recover from an ordinary network failure | 1 Retry action or automatic safe retry |

Explicit media consent is not removed to reduce clicks. Microphone and camera
remain off until the user chooses settings and joins.

## Front-page onboarding implementation

The signed-out front page is now task-driven instead of presenting three
competing modes:

- returning members see only sign-in, with the last non-secret workspace slug
  remembered locally and editable through one `Change` action;
- invitation links open a two-field account form directly, keep the one-time
  token out of rendered content and browser storage, and sign the accepted user
  in with the same submission;
- authorized `?setup=workspace` links open one owner/workspace form directly,
  derive the workspace address from its name, and keep manual slug editing
  behind an optional disclosure;
- server bootstrap capability remains authoritative, so a URL cannot expose or
  bypass disabled workspace creation;
- after entry, first-run users receive one contextual next action rather than a
  numbered checklist: invite the first teammate, message a known teammate, or
  browse rooms.

The browser acceptance suite measures these as one submitted form for sign-in,
invitation acceptance, and workspace setup; first-teammate invitation and a
known-teammate direct message are each one action from Inbox.

## Delivery slices

### Slice 0 — Baseline and compatibility

1. Characterize the current Inbox, deep-link, upload, call, teardown, and focus
   behavior in tests.
2. Preserve legacy `/app?conversation=<id>` notification and bookmark links by
   normalizing them to the canonical `/app/?conversation=<id>` route.
3. Keep `/app/settings` as a compatibility redirect to `/app/you`.
4. Add route-level lazy loading so LiveKit, Admin, and Operations code do not
   block the initial Inbox shell.

### Slice 1 — Member shell and unified Inbox

1. Add routes for `/app`, `/app/calls`, `/app/directory`, `/app/files`, and
   `/app/you`.
2. Install a consistent five-item mobile bottom navigation with `aria-current`.
3. Rename the member-facing Messages destination to Inbox.
4. Replace the current select/checkbox filters with one reusable segmented
   control for All, Unread, Direct, and Rooms.
5. Retain role-gated Admin and Operations access in the account/You surface.
6. Preserve mobile list/detail navigation, browser back behavior, and focus
   restoration.

### Slice 2 — Directory and low-click conversation start

1. Add a searchable People and Rooms directory.
2. Expose only active human users in the people list.
3. Add a cursor-based, searchable active-human directory API. Keep the legacy
   unbounded users endpoint only for compatibility.
4. Add an atomic get-or-create-direct operation so repeated or concurrent
   actions return the same authorized conversation instead of surfacing
   `direct_conversation_exists`.
5. Provide Message, Audio, and Video quick actions that navigate directly to the
   conversation or its call lobby.
6. Reuse public-room discovery and membership behavior for room join/open.

### Slice 3 — Authorized Files surface

1. Add an owner-contained ConversationContent query for recent files and files
   shared by the current user.
2. Return Ecto-free file projections with source conversation, message,
   sequence, safety state, owner, and timestamps.
3. Add `GET /api/v1/files` with bounded, deterministic pagination.
4. Deep-link each file with the established
   `/app/?conversation=<id>&search_message=<id>&search_sequence=<n>` contract and
   fetch a bounded window around the source message when it is not loaded.
   Downloads continue through the existing authorized attachment endpoint.
5. Add per-file upload progress, cancellation, retry, policy rejection, scan
   state, and restart-after-reconnect recovery without detaching files from
   messages. Do not claim byte-resume until multipart upload exists.
6. Clean up cancelled/orphaned upload intents and define archived, left,
   deleted, retained, and quarantined visibility explicitly.
7. Add owner-scoped stable-cursor indexes and cross-tenant/cross-conversation
   negative tests.

### Slice 4 — Calls destination and call continuity

1. Add a Calls-owned query over existing room-lifecycle records and expose
   `GET /api/v1/calls`.
2. Show truthful Active and Recent session views plus audio/video modality,
   active/ended state, and **room-session duration**. Do not present ringing,
   answered, missed, declined, per-user duration, or scheduled state.
3. Add a New call chooser with direct Message/Audio/Video actions.
4. Route active/recent session actions directly to the source conversation or
   its call lobby.
5. Hoist the single call-session owner above feature routes so navigation does
   not accidentally terminate an active call.
6. Preserve default-off media, device selection, permission recovery,
   participant grid, active speaker, screen sharing, reconnect, revocation,
   Leave, and server-authorized End for everyone using `can_end`.
7. Add call duration, clear connection state, and a compact collaboration sheet
   for Chat, People, and Files without creating a second realtime connection.
8. Keep a visible capture/call bar on every member route. Stop every local track
   and leave the provider room on logout, rejected refresh, tenant/session/
   device/member/capability revocation, provider end, page lifecycle exit, or
   track end.

Authoritative incoming, ringing, missed, and declined calls are a later contract:
they require Calls-owned invitations, signed idempotent LiveKit webhook facts,
expiry-to-missed transitions, user-topic delivery, and matching OpenAPI/AsyncAPI
events. Those labels remain absent until that whole slice is implemented.

### Slice 5 — You, Admin, and Operations

1. Consolidate Profile, Devices, Sessions, Notifications, and Settings in You.
2. Add role-aware Admin and Operations entry cards.
3. Retain direct `/admin` and `/ops` routes and authorization guards.
4. Make common device/session revocation and notification changes single-screen
   operations with clear confirmation and recovery states.

### Slice 6 — Qualification and deployment

1. Run formatter, lint, typecheck, unit, integration, architecture, contract,
   migration, build, security, and browser suites.
2. Add mobile browser coverage for the new navigation, quick actions, files,
   call lobby, active call, and failure states.
3. Add an immutable local release composition that builds the Dockerfile
   `runtime` target, serves the packaged web client from Phoenix, records the
   image ID/digest and revision, and does not bind-mount source or run Vite.
4. Build the exact candidate revision once and retain the prior image and
   rendered configuration.
5. Recreate the local Podman release services from that image and migrate
   forward.
6. Verify health, messaging, files, direct audio/video, three-person video,
   screen sharing, Admin, Operations, responsive UI, and accessibility in the
   browser.
7. Retain the previous image/configuration and use expand-contract migrations;
   application rollback never automatically runs down migrations.

The external staging/production chain is a separate deployability gate:
successful exact-SHA CI → scan before publication → digest/attestations →
protected staging → packaged-image browser synthetics → approval → promote the
same digest → observation window → restore the prior bundle on abort. The
repository must not claim that this chain is executable until deployment
environments, credentials, and rollback automation exist.

### Slice 6A — Browser installation and safe offline shell

1. Add a standards-based manifest, neutral launcher icons, Apple touch icon,
   standalone display, and an `/app/` start URL.
2. Register the existing push-capable module service worker eagerly without
   requesting notification permission.
3. Offer an explicit Install K-Comms action. Use the native Chromium prompt
   when available and accessible manual Add to Home Screen instructions on
   iOS and other browsers.
4. Cache only a fixed offline document and revisioned same-origin static
   application assets. Keep authentication, API, socket, message, file,
   attachment, invitation, call, media, and signed-URL requests network-only.
5. Let a new worker wait and offer a user-controlled Reload action. Never
   interrupt an active draft or call with automatic activation or reload.
6. Serve the worker with no-store and its explicit `/app/` allowance, revalidate
   the manifest, and verify the exact OCI revision through packaged-image and
   public-edge checks.

### Slice 7 — Post-deployment fine-tuning

1. Measure task actions, first-load bundle size, render timing, UI errors,
   message-send failures, call-join failures, and reconnect behavior.
2. Re-run the full task inventory from onboarding through daily member and
   administrator operations.
3. Remove redundant confirmation screens and duplicate navigation only where
   security, destructive-action, and explicit-media-consent controls remain
   intact.
4. Complete formative tuning before release-candidate freeze.
5. Treat every code change after deployment as a new revision and image. Rerun
   affected and regression gates, issue new evidence, and deploy the new
   candidate through the same process.

## Architecture rules

- Keep one Phoenix release, one PostgreSQL database, and one deployment unit.
- Calls owns call persistence and exposes Ecto-free projections.
- ConversationContent owns message and attachment queries.
- Conversations owns lifecycle, membership, discovery, and read cursors.
- Web may compose public projections but may not query business tables directly.
- Do not create a generic shared kernel or new service.
- Every public API addition updates OpenAPI, tests, and an ADR when it changes a
  durable contract or ownership decision.
- New Ecto-free directory, file, and call-session projections are listed in the
  manifest; new indexes or tables are owner-scoped migrations.
- Realtime call contracts update AsyncAPI as well as OpenAPI. Provider secrets,
  room identifiers, credentials, SDP/ICE, and media details never cross public
  projections.
- The strict `context-boundaries.yaml` validator, empty baseline, and both xref
  cycle gates must remain green.

## Acceptance gates

### Functional

- Direct, group, and room conversations send, receive, replay, search, thread,
  react, mention, and mark read without acknowledged-message loss.
- Files upload, cancel, retry, scan, reject, download, and return to source with
  tenant and conversation authorization intact.
- Direct and three-person audio/video calls exchange media; screen sharing
  publishes, subscribes, and cleans up.
- Active calls survive in-app route changes and terminate all local tracks on
  Leave, End, logout, revocation, or provider end.
- Admin and Operations remain role-gated.
- The mobile web client installs from supported browsers without an App Store,
  starts at `/app/`, and preserves notification consent as a separate explicit
  action.

### Accessibility and usability

- No horizontal overflow at 320, 360, 390, 480, 700, and 768 CSS pixels.
- Interactive targets are at least 44 by 44 CSS pixels.
- 200% text, forced colors, reduced motion, text spacing, portrait, landscape,
  safe-area insets, and software keyboard layouts remain usable.
- New states pass automated WCAG 2.2 A/AA checks and manual keyboard/screen
  reader verification.
- Focus is trapped and restored for dialogs and sheets.
- The action-friction targets above are verified as complete browser journeys,
  including signed-out onboarding, member work, administration, operations,
  and recovery. The usability protocol, schema, templates, and scorer are
  versioned for the new information architecture.

### Reliability, security, and operations

- Session refresh, 403/409/413/422/429, timeout/5xx, offline, reconnect,
  duplicate/out-of-order events, upload interruption, scanner/object-store
  outage, media permission denial, LiveKit outage, and revocation are covered.
- No cross-tenant data or media access, provider-token persistence, unintended
  capture, media after teardown, or sensitive provider data in logs/events.
- Exact-image evidence includes revision, digest, migration result, health,
  browser traces/screenshots on failure, and rollback target.
- Packaged-image browser qualification runs against Phoenix, PostgreSQL, MinIO,
  and LiveKit on mobile Chromium and WebKit/iPhone emulation. Release evidence
  additionally covers physical iOS/Android with VoiceOver/TalkBack, forced TURN,
  landscape, safe areas, software keyboard, three-party video, upload failures,
  and rollback proof.
- Privacy-safe telemetry covers browser errors, Web Vitals, message send/upload
  failure, call join failure, and reconnect rate. Owners, retention, dashboards,
  alerts, cohort comparison, and numeric abort thresholds are recorded before
  pilot expansion.
- Offline PWA proof shows only the fixed offline state and static assets in
  Cache Storage, no private communication or credential-bearing response. An
  available worker update waits for the user's Reload action.

## Rollout and stop conditions

1. Local exact-revision deployment and browser qualification.
2. Staff dogfood on the frozen candidate. Use the retained previous image as the
   rollback path until an explicitly owned tenant experience-version control
   exists.
3. Formal accessibility/usability study.
4. At least 14 days with 20–30 internal pilot users.
5. Staged tenant expansion only after product, accessibility, security,
   operations, and business sign-off.

Stop expansion for tenant isolation failure, acknowledged-message loss,
unauthorized media, unintended capture, unrecoverable data error, serious
accessibility defect, Sev-1/Sev-2 incident, alerting failure, failed rollback,
or usability regression.

## Work packages

| Package | Owner | Depends on | Estimate | Acceptance command/evidence | Completion signal |
|---|---|---|---:|---|---|
| WP-1 Contract freeze and characterization | Architecture + QA | None | 1–2 engineer-days | focused ExUnit/Vitest/Playwright baseline, ADR review | Existing deep links, ordering, focus, upload, and call teardown are protected |
| WP-2 Shell, Inbox, and compatibility routes | Web client | WP-1 | 2–4 engineer-days | `make web-check`; mobile and accessibility E2E | Five member destinations work; legacy links redirect safely |
| WP-3 Directory and atomic direct start | Identity + Conversations + Web | WP-1 | 3–5 engineer-days | controller/core concurrency, privacy, quota, rate-limit tests | Active-human search and repeated one-action direct start return one conversation |
| WP-4 Authorized Files | ConversationContent + Web | WP-1 | 3–5 engineer-days | core/controller/file browser tests; OpenAPI | Stable cursor listing, safe download, source return, cancel/retry cleanup |
| WP-5 Calls destination and continuity | Calls + Web client | WP-1, WP-2 | 4–7 engineer-days | Calls/core/controller/Vitest/live-media suites; OpenAPI/AsyncAPI | Truthful active/recent sessions and route-safe single media owner |
| WP-6 You/Admin/Ops friction pass | Web client | WP-2 | 1–3 engineer-days | role E2E, keyboard/axe, action-count receipts | Common member/admin operations meet action targets |
| WP-7 Immutable local release path | Delivery + Operations | WP-1 | 2–4 engineer-days | release build, migrate, health, retained image/config and rollback receipt | Packaged app runs without source mounts or Vite |
| WP-8 Full qualification | QA + Security + Accessibility | WP-2–WP-7 | 3–6 engineer-days plus human/device gates | `make check`, `make web-check`, architecture/contracts, exact-image synthetics, live media | All automated gates green and manual exceptions recorded |
| WP-9 Formative tuning and RC freeze | Product + Web + QA | WP-8 | 1–3 engineer-days | action-count comparison, bundle/performance evidence, regression rerun | Final candidate frozen with no unresolved P0/P1 usability defect |
| WP-10 Pilot and production promotion | Product + Accessibility + Security + Operations | WP-9 and external environment readiness | minimum 14 elapsed days | completed readiness ledger, pilot scorer, approvals, same-digest promotion/rollback evidence | All application, environment, and people gates signed |
| WP-11 Installable PWA | Web client + Security + Operations | WP-2, WP-7 | 2–4 engineer-days plus physical devices | manifest/worker unit and browser tests, packaged-image headers, offline proof, Chromium and iOS/Android install/update launch receipts | Browser installation works without a store; caches contain no private communication data; updates remain user controlled |

## Definition of done

The code phase is complete when all automated gates pass and the exact revision
is deployed and browser-verified. Internal-production readiness is complete only
after the separate environment and people gates in
`internal-production-readiness.md` are evidenced; local success alone is not a
production-readiness claim.
