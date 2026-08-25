# Changelog

## [Unreleased]

### Changed

- Carried the mobile design system into the screens the shell work had not
  reached: Calls, Directory, Files, Whiteboard, Workspace administration and
  Service operations. Raised 124 font-size declarations across 18 files to the
  12px floor -- they ranged from 8.8px to 11.84px in nineteen distinct values,
  and Workspace administration alone rendered fourteen sizes with twenty-one
  elements under the floor. No text below 12px and no control below 44px now
  remains on any screen at 390x844 or 320x640.
- Replaced the stat-card carousel on Workspace administration and Service
  operations with a two-column grid. Cards were 260px wide in a 390px viewport,
  so the second was always sliced mid-label and the layout read as broken.
- Reworked the Calls screen. With the call launcher open the phone showed the
  same rooms twice, once in quick contacts and again in a searchable superset
  below it; it now shows one list. The launcher toggle is prominent while it
  opens and quiet while it closes, rather than making a dismissal the loudest
  control on the page, and its icon follows the action. Message, audio and video
  row actions moved from 40px to the 44px target floor.
- Operations triage reports elapsed time in human units. It previously read
  "The content-blind snapshot is 3553751 seconds old."

- Removed the phone top bar and the More drawer from the member app. The top bar
  resolved its title from the pathname, so inside a conversation — addressed by
  query string — it named the Inbox while a room was open, above a bottom bar
  that said the same thing and a back arrow that disagreed. The highlighted tab
  now names the destination and a leaf view names itself. The drawer held five
  items, three of which the You screen already carried; Whiteboard, the instant
  room and signing out moved there, and Whiteboard gave up its place in the tab
  bar because it was two taps from the inbox either way.
- Collapsed the conversation header from two rows to one and let the bottom bar
  step aside inside a conversation. Canvas, Activity, Details, message search and
  guest invites moved into an overflow sheet. Measured at 390x844, chrome fell
  from 312px to 132px in a conversation, from 311px to 249px on the inbox, and
  from 135px to 74px on the You screen.
- Moved in-app notifications to the inbox, the surface every notification in a
  communication product is already about.
- Raised every phone surface to a 12px type floor and a 44px target floor,
  replacing seven sub-12px sizes — including an 8.64px notification count and a
  9.6px message timestamp — and inbox filter chips that shrank to 38px at the
  touch breakpoint.

### Fixed

- Defined four custom properties that were referenced in CSS and declared
  nowhere, so each declaration was invalid at computed-value time and fell back
  silently. The whiteboard connection indicator was the visible consequence: it
  resolved to no background in both its connecting and its live state, so a
  board that was connecting looked identical to one that was live.
- Replaced 65 hardcoded teal shadow literals, left over from an abandoned teal
  mobile mock-up, with a themed --shadow-color token. Violet buttons were
  casting green shadows.
- Gave the mobile chrome heights a single owner. They were declared in three
  files at once at equal specificity inside the same media query, so import
  order decided which reasoning survived and an eight-line comment justifying
  62px documented an intent the cascade discarded.

### Added

- Added spacing, radius, type and touch-target scales to the design tokens.
  Measured across the 26 stylesheets, the client was carrying 81 distinct
  spacing values, 21 radii and roughly 50 font sizes against two type tokens and
  no spacing or radius tokens at all.

- Added a local-first instant workspace that opens directly into Excalidraw,
  restores a private device-local draft, supplies an editable guest identity,
  and promotes the scene and first message through the existing idempotent room
  contracts only when the visitor sends, shares, or explicitly starts a room.
- Made the draft Share action open the complete secure-link, native-share, and
  QR invite dialog immediately after durable room promotion.
- Added direct audio-call and video-call actions to the private workspace draft.
  Each action promotes the draft through the existing idempotent room contract
  exactly once, preserves the draft content, and opens the existing
  permission-aware prejoin flow before any media capture begins.

### Documentation

- Recorded the production two-iPhone cellular audio/video qualification for the
  managed LiveKit Cloud media plane while retaining the separate forced-relay,
  group-capacity, screen-share, privacy, outage, and incident gates.

## [0.3.0] - 2026-07-12

### Added

- Responsive user, tenant-administration, and content-blind platform-operations interfaces.
- Invitations and user lifecycle, tenant quotas, public channels, moderation, retention, legal holds, deletion workflows, and bounded neutralized audit CSV exports.
- Password recovery with one-time purpose-bound tokens, session/device invalidation, and rate limits.
- Scoped service accounts with one-time credentials, expiry, rotation, revocation, bot identity markers, and separate API routes.
- Canonical threads, explicit mentions, durable in-app notifications, and per-device encrypted browser-push subscriptions.
- Version-bound attachment intents, scan attempts, quarantine, and DNS-pinned provider HTTP protections.
- Hardened webhook secret storage, compare-and-swap delivery claims, retries, provider observability, and operations read models.
- Production Kubernetes overlay, controlled platform-role job, autoscaling, disruption budgets, network policies, alerts, dashboards, and local qualification/load runners.
- Automated browser journeys and backend, client, contract, manifest, secret, migration, release, restore, rollout, rollback, and resilience gates.

### Changed

- Advanced the repository from an executable messaging foundation to a complete staging-qualified communication-platform package.
- Made notification, attachment, governance, integration, administration, and operations workflows durable and auditable.
- Preserved server-readable encrypted-at-rest messages and deferred voice/video, federation, active-active multi-region writes, and true end-to-end encryption to dedicated future designs.
