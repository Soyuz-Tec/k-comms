# K-Comms iOS

Open `KComms.xcodeproj` in **Xcode 16.4**. The app targets iOS 17 or later and
references LiveKit Swift **2.17.0** by exact package version. Its package manifest
requires Swift 6.1/Xcode 16.3 or later; this project pins Xcode 16.4 in CI and uses
Swift 5 language mode for the application. No developer team, signing identity,
APNs entitlement, PushKit registration, or embedded server credential is supplied.

The foreground app uses the current member APIs for password/MFA sign-in,
refresh/revocation, authorized directory and direct/private group conversations,
bounded message history, stable per-message idempotency keys, edits/deletion,
meeting listing/scheduling/cancellation/start, audio/video, and assigned-line
telephony. Enter an HTTPS origin and your existing workspace credentials at runtime.
Server authority remains decisive for every write and call admission.
Active conversation-only humans retain authorized chat and conversation calling.
Directory, new direct/groups, meetings and phone require current workspace scope;
their tabs and cached projections disappear when `/me` withdraws that scope.
Current role/scope metadata updates the secure envelope without treating a
legitimate role change as a different identity. Current capabilities and actual
call/participant/device admission still decide ongoing media authority.
Retain the positive owner version: older projections cannot re-expand access, and
workspace replies started before withdrawal cannot survive a later regrant. Token
rotation preserves newer owner metadata while replacing credentials.

Credentials occupy one non-synchronizing, device-bound Keychain item available
only while unlocked. Absolute access-token expiry survives restart. Delayed old
identity results cannot install tokens or restore content. Logout clears local
authority before remote revocation; an unconfirmed revocation is disclosed.
Observable account state contains identity only. SDK logging is disabled before
the application model initializes.

Phoenix v2 user/conversation/call channels are invalidation hints. REST refreshes
the visible message range, including edits/deletes at old sequence numbers, and
replaces current retained sender labels in batches of at most 200 message IDs.
The visible cache holds at most 500 rows. Earlier retrieval checks successive
500-sequence windows; gaps can require another explicit earlier-history action.
Neither a socket event nor an old token authorizes media. CallKit actions obtain
fresh owner admission; media operations validate current identity, exact call and
participant/device authority, credential expiry and recent observations.
Authority and credential leases also use monotonic deadlines, so clock rollback
cannot extend them. A rejoin receives a fresh OS call UUID; late actions from an
earlier admission cannot match it through the backend call ID. App
backgrounding ends local media. Permission dialogs temporarily making a scene
inactive do not end it. No camera or microphone starts at sign-in or on a wake hint.

Native socket handshakes put the real one-use socket ticket in the
`x-k-comms-socket-ticket` header. The WebSocket URL contains only protocol version;
access, refresh and socket credentials never enter application URLs or logs. This
requires the qualified owner header transport; legacy servers accepting only a
browser query ticket cannot authenticate this native socket. No query fallback is used.

The Phone screen distinguishes disabled provider, missing assignment and ready
service. Dial retries retain the same destination/operation key until confirmed.
SDK tones require an exact current owner dispatch receipt, then submit a completion
receipt as submitted or unknown. A pending/uncertain tone is reviewed without
automatically emitting it again. SDK submission does not prove carrier delivery.

Background call notifications are visibly unavailable. Web Push is not native
APNs; no proposed native-push routes are called. Provider credentials, reviewed
backend registration/wake authority, signed builds and locked physical-device
qualification are separate prerequisites.

From the repository root, on a compatible macOS runner:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
xcodebuild -resolvePackageDependencies -project clients/ios/KComms.xcodeproj -scheme KComms
xcodebuild -project clients/ios/KComms.xcodeproj -scheme KComms -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/kcomms-ios-device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project clients/ios/KComms.xcodeproj -scheme KComms -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/kcomms-ios-tests \
  -resultBundlePath /tmp/kcomms-ios-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

Use fresh output paths for each receipt. Commit the generated package-resolution
lock after the first qualified macOS resolution; the direct SDK version is already
exact. The native workflow retains that lock and unsigned application alongside
XCTest evidence. Auth, replay/edit/delete/redaction, stale identity, persisted
expiry, lease expiry, owner tone receipts and unqualified wake refusal have
meaningful authored test cases. Linux source parsing is not an Xcode build or
XCTest receipt. No macOS build, simulator run, physical device, carrier/provider,
background ringing, signing, or production readiness is claimed by source alone.
