# Desktop evaluation client

The Desktop client packages the current React UC interface with maintained
Electron. [ADR-0105](../02-architecture/adr/0105-packaged-electron-uc-client.md)
defines its security boundary. It adds no backend operation or migration.
Source and focused tests are available; native packaging and platform receipts
are required before claiming installability or call readiness.

## Build inputs and disconnected defaults

Use Node 22.22.0 and the committed web/Desktop npm locks. Run packaging on the
target OS. The pinned CI workflow builds the actual web UI and unsigned native
artifacts on Windows, macOS and Linux. CI supplies no service origin and uses
`qualificationOnly: true`; those artifacts exit with a setup explanation before
network access. They are build-evaluation artifacts, not configured clients.

For an explicitly authorized evaluation service, build with public configuration
only. Do not put tokens, passwords, OIDC secrets or signing keys in these values.
The web build must use its default same-origin API base; unset
`VITE_API_BASE_URL`. The service must already be reachable through authenticated
HTTPS and its existing web/socket/media policy.

```sh
cd clients/web
npm ci
npm run build
cd ../desktop
npm ci --ignore-scripts
npm run check:source
npm test
```

Set these public build variables using your platform's environment syntax,
then run `npm run prepare:ui` followed by `npm run package:unsigned`:

| Variable | Required value |
| --- | --- |
| `K_COMMS_DESKTOP_SERVICE_ORIGIN` | Exact authorized HTTPS origin such as `https://comms.example.org`, with no trailing slash, URL credential, path, port or query |
| `K_COMMS_DESKTOP_MEDIA_ORIGINS` | JSON array of exact approved HTTPS/WSS signaling origins; HTTPS and WSS are separate entries when both are needed |
| `K_COMMS_DESKTOP_RESOURCE_ORIGINS` | JSON array of exact approved HTTPS upload/download/playback origins |
| `K_COMMS_DESKTOP_QUALIFICATION_ONLY` | Exact `false` for an authorized connected evaluation; every other value keeps the disconnected fence |

Each origin list is limited to eight entries. Wildcards, numeric/local hostnames
and nonstandard ports are rejected. `prepare:ui` copies the existing built
`clients/web/dist` and writes the immutable public package configuration. It
requires the real web asset entry and never creates a placeholder UI. Inspect
that configuration before packaging and retain its hash with the artifact.
Do not commit your deployment-specific origin changes over the closed defaults.

The packaging wrapper uses a fixed local builder executable and `--publish
never`. It refuses CSC/Windows/macOS signing credentials and disables identity
autodiscovery. Electron-builder obtains the exact locked Electron distribution
for the target architecture; `--ignore-scripts` avoids a separate npm install
hook binary download. An actual CI/native build must verify this packaging path.

| Platform | Evaluation targets | Mandatory evidence still needed |
| --- | --- | --- |
| Windows | x64 per-user NSIS; no elevation | Install/uninstall, actual encrypted Windows safeStorage, mic/camera privacy, screen selection, SmartScreen behavior |
| macOS | x64 and arm64 DMG; unsigned identity | Actual Keychain use, camera/mic descriptions and prompts, Screen Recording permission, Gatekeeper behavior, architecture execution |
| Linux | x64 AppImage and deb | libsecret/KWallet actual backend, fail-closed locked/no-keyring behavior, sandbox launch, X11/Wayland/PipeWire capture and packaging dependencies |

Unsigned macOS/Windows packages may be blocked by platform trust policy. Do not
disable protections or claim notarization/publisher trust. Production signing,
notarization, authenticated update delivery and protected distribution are
separate required work; automatic updates are disabled in this source.
The macOS fuse hook resets Electron's local ad-hoc signature after binary
changes so the executable can be evaluated. An ad-hoc signature establishes
neither publisher identity nor notarization and uses no signing credential.

## Existing UI and authority

The bundled UI loads at the configured service's exact HTTPS origin. Only local
packaged assets and recognized client routes are served there; existing API
calls reach the real service using the same nonpersistent Chromium session.
Phoenix one-use socket tickets, current-session refresh/revocation, admission,
MFA, role/scope checks, media capabilities and actual call components are reused.
There is no desktop-specific trusted-origin exception or new broad API.

Saved member/guest envelopes require current owner confirmation before app
mount. Current profile data replaces cached member role data. Revoked access
returns to sign in after clearing local credentials; a service outage blocks
that launch. Native storage failure stops capture and unmounts the active UI.
Logout immediately supersedes pending native writes and the existing server
revocation request still runs. Offline local clearing does not prove remote
revocation; the next restore must pass the service again.

The vault file is `encrypted-session/credentials.v1.enc` beneath Electron's
per-user `userData` directory. Only OS-encrypted safeStorage is accepted; Linux
`basic_text`, unknown and unavailable backends are refused. Do not move the
file between services/users or supply your own encryption key. Credentials
never fall back to localStorage/sessionStorage. The Chromium partition is
memory-only; browser-local drafts/preferences and caches are ephemeral.

Corporate OIDC sign-in and corporate recent-authentication linking require the
authorized web client. This evaluation has no system-browser callback; the UI
stops those flows with an explanation. No URL handler accepts external login
tokens. Password/MFA workflows obey the actual existing service policy. Native
push/notifications, clipboard permission, generic external navigation and
background/system audio are not enabled by this package.

## Media and session qualification

Run all checks against an authorized evaluation environment with synthetic
users. Record platform, architecture, OS version, artifact SHA-256, public
configuration hash, Electron version, service revision and evidence timestamp.

1. Verify unconfigured and qualification-only packages make no connection.
   Verify missing/locked/plaintext OS storage blocks startup without writing
   tokens to browser storage or logs.
2. Sign in through the actual password/MFA UI. Restart and verify service owner
   checks run before cached UI/capture. Revoke the session, disable the user or
   expire guest admission at the service; restarting must clear saved access.
3. Start a real LiveKit/direct audio call through the existing controls. Verify
   deny/cancel defaults and OS denial for microphone and camera, exact foreground
   main-frame ownership, and no permission grant to child/foreign windows.
4. Share a screen/window. Verify an explicit actual source is selected, cancel
   stops capture and system audio is absent. Exercise platform Screen Recording
   and Wayland portal behavior rather than relying on mock tests.
5. While an OS prompt or capture request is pending, log out or switch member/
   guest identity. Verify returned tracks are stopped, existing streams and
   sockets close, native grants are invalidated and old writes cannot restore
   credentials. Refreshing the same identity must preserve its active call.
6. Exercise Member organization/onboarding, fixed-role preview, usage and
   Governance History UI against current service authority. Verify downloads
   require the native save dialog and cancel when the session changes.
7. Exercise approved resource/media signaling origins and reject foreign HTTP/
   WSS/navigation. WebRTC ICE/TURN uses server-issued media configuration;
   this egress allowlist is not a native packet firewall or provider receipt.
8. Verify no PWA worker, remote web replacement, update feed, shell opener,
   signing credential or unsigned updater can be enabled implicitly. Preserve
   install/uninstall, accessibility and clean-start evidence per platform.

## Source checks versus platform receipts

`npm test` in `clients/desktop` executes policy, actual preload, credential race,
media permission and unsigned-packaging guard tests with fake OS/Electron
providers. The fake encryption provider exists only in test sources and is
excluded from the packaged file list. These tests do not boot Electron or
certify OS storage, screen capture, network providers or native artifacts.

Focused web tests exercise the actual existing transports using synthetic
fetch responses, current-profile restore, guest binding, generation races,
capture APIs, failure cleanup and the unchanged browser/PWA path. CI also runs
the full existing web gates before building. Native CI and manual platform
qualification have not been claimed by these source receipts.
