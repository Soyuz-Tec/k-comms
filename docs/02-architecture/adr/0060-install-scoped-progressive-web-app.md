# ADR-0060: Add an install-scoped progressive web application

- **Status:** Accepted
- **Date:** 2026-07-28
- **Owners:** Product, web client, security, and operations
- **Related decisions:** ADR-0014, ADR-0058

## Context

K-Comms already provides its mobile experience through the responsive React
client under `/app/`. Users need an installable, home-screen experience without
an App Store release, while the existing service worker also owns Web Push.
Treating installation as a generic offline-first conversion would risk caching
authenticated HTML, messages, files, tokens, signed URLs, or API responses and
could make an old client remain active after a protected release.

Browser installation behavior also differs. Chromium can expose a deferred
install prompt. Safari and other iOS browsers require the browser's
Add to Home Screen flow and do not expose Chromium's prompt event.

## Decision

K-Comms is an installable progressive web application with:

- a manifest served at `/app/manifest.webmanifest`, a stable `/` ID and visual
  scope, a `/app/` start URL, standalone display, and neutral launcher icons
  sized for major browser requirements;
- one module service worker at the existing `/app/k-comms-sw.js` path and
  `/app/` registration scope so Web Push registration remains compatible;
- eager service-worker registration at client startup without requesting
  notification permission;
- an explicit, user-invoked Install K-Comms action. Chromium may present its
  native prompt; iOS and unsupported prompt environments receive short manual
  Add to Home Screen instructions;
- a fixed offline document and only same-origin, revisioned static application
  assets in Cache Storage;
- network-only handling for API, authentication, WebSocket, message, file,
  attachment, invitation, call, media, and signed-URL traffic; and
- network-first `/app/` navigations that fall back to the fixed offline
  document. The service worker does not create an offline message store,
  background-send queue, or authoritative client history.

A newly installed worker waits. The client tells the user when an update is
ready and applies it only after the user chooses Reload. The waiting worker then
activates and the page reloads after controller change, or after the activation
state is observed from an administration route outside `/app/`. K-Comms does
not force `skipWaiting()` during installation or silently reload an active call
or draft.

The service-worker response is never edge- or browser-cached and carries
`Service-Worker-Allowed: /app/`. The manifest revalidates. Content-hashed assets
may be cached immutably. The immutable OCI revision is injected into the web
build and the service-worker registration URL so each protected release checks
for its exact worker.

The visual application remains free of a branding logo. Launcher and maskable
icons are technical operating-system assets and are not rendered as page
branding.

## Consequences

### Positive

- Users can install K-Comms directly from a supported browser without an App
  Store package.
- Existing Web Push behavior and permission consent remain separate from PWA
  installation.
- The offline surface is useful and predictable without persisting private
  communication data in Cache Storage.
- Waiting updates avoid disrupting active calls, drafts, or accessibility
  context.
- Revision and cache headers make worker rollout and rollback observable.

### Negative and accepted trade-offs

- iOS installation remains a browser/operating-system action rather than one
  in-page native prompt.
- Offline mode does not expose conversations, attachments, calls, or a send
  outbox.
- The worker remains scoped to `/app/`; signed-out and administration routes
  outside that path are not controlled by this decision.
- Physical iOS and Android installation, launch, update, and icon behavior
  remain release-device gates in addition to automated browser checks.

## Validation

- Validate manifest fields, icon dimensions and purposes, start URL, scope, and
  standalone display.
- Prove eager registration does not call `Notification.requestPermission()`.
- Unit-test the request classifier so sensitive and non-GET traffic remains
  network-only.
- Prove the fixed offline fallback works after a packaged secure-origin worker
  has activated and contains no user, tenant, message, file, token, or API data.
- Prove a waiting worker does not activate until the user chooses Reload, then
  activates and refreshes on controller change.
- Verify service-worker, manifest, and hashed-asset cache headers from the
  packaged OCI image and the public edge.
- Verify Chromium install prompt handling, iOS manual instructions, installed
  mode, keyboard/focus behavior, 320 CSS-pixel reflow, and 200% text.
- Re-run Web Push registration, safe same-origin notification click-through,
  and explicit notification-permission tests.

## Revisit triggers

- Offline message reading or queued sending becomes a product requirement.
- The application needs routes outside `/app/` controlled by the worker.
- The browser platform provides a standardized install prompt across iOS.
- A native store package, background media behavior, or native push is required.
