# ADR-0105: Package the existing UC interface in a constrained Electron client

Status: Accepted for implementation; unsigned evaluation only
Qualification: source and focused protocol tests; native packaging, OS media, signing and distribution pending
Date: 2026-10-05
Owners: Web; Desktop; Release

## Context

The current React client already owns member and guest authentication, MFA,
current-session refresh and revocation, one-use Phoenix socket tickets,
LiveKit calls, direct audio, screen sharing and the Member/Role/Usage/Governance
History workflows. A desktop executable must use those implementations and
their current owner checks. A second UI or authentication protocol would
duplicate authority and media cleanup. Neither a desktop wrapper nor an
unsigned package establishes native provider or platform qualification.

## Decision

Use maintained Electron and electron-builder, pinned with integrity-bearing
npm lock entries. `clients/desktop` packages the actual built `clients/web`
assets in ASAR. Native CI produces Windows x64 per-user NSIS, macOS x64/arm64
DMG, and Linux x64 AppImage/deb evaluation artifacts. CI actions and Node are
pinned. Packaging uses no publishing or signing credentials and explicitly
rejects them. This adds no database schema, owner facade, API operation,
service capability or backend contract.

The package contains a fixed versioned configuration: one exact authorized
HTTPS service origin, at most eight exact media origins and eight exact
resource origins. No wildcard, nonstandard port, URL credential, numeric host,
localhost, `.local` or `.internal` origin is accepted. An unconfigured package
or `qualificationOnly: true` exits before creating a window or network session.
The committed and CI defaults have both fences. Authorized evaluation builds
must configure their own exact service and provider origins explicitly.

The session-specific HTTPS protocol serves packaged assets and SPA routes at
that service's original HTTPS origin. API requests use the same in-memory
Electron session to reach the real service with protocol interception bypassed.
The existing bearer, MFA, CSRF/CORS/trusted-origin and one-use socket-ticket
flows remain authoritative; no cross-origin proxy credential API is added.
Main-frame navigation stays on packaged UI routes. Remote documents, child
frames, popups and webviews are refused. All HTTP/WSS egress is restricted to
the configured origins. Primary service authorization, cookies and native
socket headers are stripped from other permitted provider origins.

Renderer sandbox, context isolation and web security are mandatory; Node
integration, DevTools, insecure mixed content and generic IPC are absent.
Launch flags that disable the sandbox/security or enable remote debugging are
refused. Packaging disables Electron's RunAsNode, NODE_OPTIONS and inspect
fuses and requires ASAR. Embedded ASAR integrity is enabled on Windows/macOS;
Electron does not support that fuse on Linux. Unsigned evaluation packages
provide no publisher authentication. CSP permits bundled scripts and necessary
inline styles used by the actual UI, refuses eval, frames and objects, and
restricts media/resources to explicit origins.

## Session ownership and erasure

The sandbox preload exposes three fixed identity commands: state, credential
load, and credential replacement. Each native handler authenticates the
current owning main frame and validates argument count. Replacement accepts
only a bounded member or guest session DTO and an increasing generation; it
does not accept paths, network destinations, shell commands or caller-selected
storage keys. Member and guest credentials form one exclusive current identity.

The shell adds a separate finite UI boundary: shell state, one of the
File/Edit/View/Help menus, a light/dark/system theme choice, and subscription to
five application intents (new instant room, workspace, search, navigation
visibility and help). Shell handlers authenticate the owning main frame and
exact packaged service origin, and validate argument counts and fixed enums.
Subscriptions are removed when the window closes. This boundary accepts no
paths, URLs, network destinations, clipboard content or general window commands.
Explicit native Edit menu selections use Electron's standard OS editing roles;
they do not grant renderer clipboard API permission. Window controls are drawn
and operated by the OS through Electron's hidden titlebar/overlay facilities.
The renderer reserves their area and supplies a drag strip with non-draggable
interactive controls. Browser versions show application menus without imitation
OS controls. Native public/authentication screens mount the same header without
member identity; authenticated media providers remain above the route outlet.

Credentials are sealed through Electron safeStorage's maintained OS provider
and written atomically to one per-user file. Linux `basic_text`, unknown or
unavailable storage is rejected. No plaintext key, custom password encryption,
environment token, browser credential storage or silent fallback exists.
The Chromium partition is nonpersistent. Renderer storage helpers remove
legacy credential keys and use only the in-memory native snapshot. Existing
server-backed member data remains server backed; browser-local drafts are
ephemeral in this client. The PWA service worker is not registered, so remote
web updates cannot replace the packaged UI through that path.

A saved envelope is confirmed through existing `/api/v1/me` or the existing
guest conversation API before the app mounts. The actual transport handles
refresh; the response must match the saved tenant/user/device or guest room.
Current member profile data replaces cached role data. Definitive owner denial
clears the vault and returns to sign in; a service failure clears cached access
and blocks that launch. An encrypted current-profile write must settle before
mount. This also prevents a failed earlier file deletion from granting restored
access without current service confirmation.

Replacement generations take effect synchronously before queued disk work.
Logout/switch supersedes pending writes, rejects stale revival and invalidates
media grants. Existing server session revocation is unchanged. Native storage
failure clears the renderer cache and unmounts the active app, invoking its
socket/call cleanup. Provider loss still permits a null credential deletion.
There is no claim that local logout can revoke a remote session while offline.

## Media and external actions

Camera/microphone permission requires the owning, foreground main frame, an
OS-encrypted current identity and explicit native consent. macOS additionally
uses the real OS access request. Screen capture requires a foreground user
gesture and an explicit source selected through the native prompt; cancellation
is the default and system audio is refused. Async permission/source results
recheck the current media epoch. The renderer wraps the actual browser capture
APIs used by LiveKit and direct audio, stops existing tracks on logout/switch,
and stops late returned tracks. No placeholder call implementation is added.

Downloads use Electron's native save dialog, a sanitized suggested basename,
the current session generation and a 100 MiB transfer bound. No arbitrary
renderer filesystem IPC, automatic opener, shell action or URL launcher is
provided. Corporate OIDC sign-in/linking remains available through the
authorized web client: this evaluation has no system-browser callback. Its
existing UI refuses desktop OIDC initiation/completion with that explanation.
Password and MFA flows reuse the existing UI and service policy.

## Updates and qualification

Automatic updates are hard disabled. There is no feed, update installer,
electron-updater dependency or unsigned-update bypass. Production enablement
requires a separately reviewed signing/notarization and authenticated update
design, real protected credentials/feed, publisher verification, upgrade and
rollback qualification, and protected delivery. Supplying credentials to the
evaluation packaging command is an error rather than implicit release enablement.

The UI identifies itself as an unsigned evaluation and states that automatic
updates are off and platform media qualification is pending. Native build
success, OS secure-storage behavior, camera/microphone/display permission,
WebRTC routing, Gatekeeper/SmartScreen, accessibility, signing and distribution
must each have actual platform evidence. HTTP/WSS origin restrictions do not
establish a firewall over server-authorized WebRTC ICE/TURN transport. Local
tests use explicit fake OS/Electron providers and do not qualify those systems.

Use the [desktop qualification runbook](../../12-development-guides/desktop-client.md).
