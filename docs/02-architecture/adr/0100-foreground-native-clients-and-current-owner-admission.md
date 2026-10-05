# ADR 0100: Foreground native clients and current owner admission

Status: Accepted for implementation; runtime and device qualification pending.

## Context

The web client and retained mobile read DTOs do not provide installable iOS and
Android applications, OS audio integration, or native background-ring authority.
The existing member, message, meeting, audio-call and telephony contracts already
own admission. Web Push registrations cannot be reused as APNs/FCM registrations.

## Decision

Provide a SwiftUI iOS application with a direct Xcode project and a Compose Android
application with a checksum-pinned Gradle wrapper. Pin LiveKit Swift 2.17.0 and
Android 2.29.0. Use CallKit and CoreTelecom for foreground OS call/audio integration.
Keep application media adapters replaceable and keep credentials out of UI state,
plain preferences, logs, protocol fixtures and repository files. Keychain/Keystore
credentials bind current server origin, tenant, human user, device and generation.
Persist absolute access expiry and bound single-flight refresh to the initiating
generation. Reject late former-identity reads, writes, refreshes and media results.
Retain current owner access scope and role. Active conversation-only humans keep
their authorized communication; workspace tabs, commands and caches require
current workspace eligibility. A legitimate role change does not itself revoke
a valid session or call: current owner capabilities and admission remain decisive.
Retain the positive owner version: older projections cannot re-expand access, and
workspace replies started before withdrawal cannot survive a later regrant. Token
rotation preserves newer owner metadata while replacing credentials.

Use the qualified `x-k-comms-socket-ticket` header for native Phoenix handshakes.
The auth adapter accepts one exact case-insensitive header and rejects duplicates
or simultaneous query/header tickets before consuming the same Accounts one-use,
expiring, current-session ticket. Browser query transport remains compatible.
Native URLs carry only protocol version; no credential query fallback is enabled.

Native clients call actual advertised owner APIs and decode their current DTOs.
They do not infer admission from a directory entry, meeting invitation, cached call,
OS action or socket event. Revalidate the current identity and exact call/participant
or telephony device authority before publication, after connection/reconnection and
on a bounded observation lease. Stop media on denial, expired credentials, logout,
identity change, unconfirmed authority timeout or app backgrounding. Permission
and OS activation callbacks remain prerequisites for audio/camera hardware.
Use monotonic lease deadlines and bind asynchronous authority/control callbacks
to each admission generation. A rejoin of the same backend call receives a new
CallKit identity, so stale OS actions cannot terminate the replacement admission.

Reconcile message revisions using bounded REST ranges, because edits and deletions
do not advance creation sequence numbers. Replace current retained-label sidecars;
do not preserve a stale person's name when a refreshed authorization omits it.
Limit rendered caches and pages. Bind each message retry to one original idempotency
key and identity. Disclose uncertain group or dial outcomes instead of silently
creating another operation. Telephony DTMF follows owner dispatch authorization,
one SDK submission, and owner submitted/unknown completion; reconciliation never
silently emits an uncertain tone again.

Native push remains explicitly unavailable. No invented native registration or
wake-admission endpoints are called. A separate default-closed backend increment
must establish Notifications registration/dispatch ownership and call-owner wake
admission with session/device/version binding. PushKit/APNs/FCM, signing and physical
locked-device ringing require their own provider and device qualification.

## Consequences

Unsigned builds and protocol/replay/identity/expiry tests can run in macOS and
Android SDK CI without production credentials. Source syntax checks are separate
evidence from compilation, tests, simulator/device media, carrier completion and
deployment. Pin tooling and retain actual build/test outputs and resolved package
versions. Never call an authored workflow a passed build or a foreground app a
qualified background calling implementation.
