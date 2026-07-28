# PWA Operations

## Scope

K-Comms ships the responsive React client as an installable PWA. There is no
App Store package. The worker is registered from `/app/k-comms-sw.js` with the
`/app/` scope and continues to own Web Push events.

## Release contract

Every protected OCI build injects `OCI_REVISION` as
`VITE_K_COMMS_RELEASE_REVISION`. The client adds that revision to the
service-worker registration URL. The runtime image also declares
`io.k-comms.pwa=1`. Packaged-image and deployment verification must prove:

- `/app/k-comms-sw.js` is JavaScript, contains the exact release revision, has
  `Cache-Control: no-store, max-age=0, must-revalidate`, and has
  `Service-Worker-Allowed: /app/`; deployment verification requests the
  browser's exact `?revision=<OCI revision>` worker URL;
- `/app/manifest.webmanifest` is manifest JSON and revalidates;
- the offline document and exact launcher/icon assets exist;
- the manifest ID and visual scope are `/`, its start URL is `/app/`, and the
  service-worker control scope remains `/app/`; and
- content-hashed `/app/assets/` responses may be immutable, while API and
  authenticated responses retain their existing non-public behavior.

Deployment verification reads a real content-hashed JavaScript bundle from the
served application index and requires its exact JavaScript MIME type plus the
immutable cache policy. It also requests a missing hash-shaped bundle and
requires `404`, `text/plain`, and `no-store`. This prevents an SPA fallback
document from being cached under a stale JavaScript URL.

The CDN must not redirect the worker request, override its no-store response, or
serve a cached worker after promotion or rollback. Public verification requires
an exact HTTP 200 for the revisioned worker URL, permits only absent,
`CF-Cache-Status: BYPASS`, or `CF-Cache-Status: DYNAMIC` edge-cache states, and
checks the headers and embedded revision.

## Update behavior

The browser downloads a candidate worker and leaves it waiting while the
current client has control. K-Comms displays Update ready with a Reload action.
Only that action asks the waiting worker to activate. The page reloads after
`controllerchange`. Administration and operations documents are outside the
worker's `/app/` control scope, so they reload after observing the waiting
worker's activated state instead.

Do not add unconditional install-time `skipWaiting()`, automatic reload, or an
activation timer. Those behaviors can interrupt calls, erase unsent UI state,
and make rollback evidence ambiguous.

If an update appears stuck:

1. Confirm the public worker response contains the target OCI revision and
   no-store header.
2. Confirm the manifest and application document reference the current build.
3. Inspect the browser registration for `/app/`, including active and waiting
   workers.
4. Check CDN cache status and purge only the exact worker/manifest URLs if the
   edge violates the release contract.
5. Preserve browser diagnostics before unregistering a worker or clearing site
   data.

## Offline behavior and privacy

The cache contains only the fixed offline document and revisioned static
application assets. API, authentication, WebSocket, message, contact, file,
attachment, invitation, call, media, signed-URL, and non-GET traffic is
network-only. There is no service-worker message database, send outbox,
background sync, or offline authorization claim.

When an `/app/` navigation cannot reach the network, the worker returns the
fixed offline document. Once connectivity returns, normal server session and
cursor reconciliation remains authoritative.

## Promotion and rollback

Promote the same attested OCI digest through staging and production. Verify PWA
headers, embedded revision, online startup, offline fallback, and worker update
behavior at staging before production approval.

Rollback restores the retained previous digest and configuration through the
protected workflow. Verify that the public worker now embeds the restored
revision. Existing clients may keep the newer worker until their next update
check; the newer worker's network-only privacy boundary must therefore remain
backward compatible with the restored server.

The first PWA release has a deliberate compatibility seam: its retained
predecessor does not contain PWA assets or the `io.k-comms.pwa=1` image label.
`verify.sh` therefore runs PWA checks automatically only when the active
container has that label. Candidate deployment and the retained, reactivated,
and post-restore staging checks pass `--require-pwa`, which fails closed if the
label or assets are absent. The rollback rehearsal and legacy-adoption paths do
not pass that flag, so they can still prove the health of a pre-PWA predecessor.
After rollback, existing tabs may remain controlled by the newer worker until
its lifecycle permits the restored worker to activate; closing all K-Comms tabs
allows that transition. The newer worker must remain compatible with the
restored server throughout this interval.

## Device qualification

Automated browser tests do not replace physical-device proof:

- On current iOS, use the browser Share menu and Add to Home Screen, then launch
  from the home-screen icon and verify standalone navigation, safe areas,
  200% text, notifications as a separate consent action, offline state, and an
  update.
- On current Android/Chromium, use the Install K-Comms action and native prompt,
  then verify the same launch, offline, notification-consent, and update
  behavior.
- Re-run install and update receipts for the exact release candidate when
  manifest, icon, worker, CSP, routing, or cache behavior changes.
