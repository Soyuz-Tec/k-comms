# Individual phone calls: first milestone

The Phone surface adds one tenant number and one assigned extension, an outbound
dialer, incoming answer/reject, hangup, and personal call history. It uses LiveKit
SIP with the existing LiveKit media plane. Normal deployment keeps it disabled;
local synthetic test success does not enable a carrier or acquire a number.

The [architecture decision](../02-architecture/adr/0085-add-individual-telephony-through-livekit-sip.md)
defines its ownership and security boundary. The canonical
[OpenAPI contract](../../contracts/openapi/openapi.yaml) documents configuration,
individual call records, actions, and the authenticated provider callback.
Conversation calls keep their existing room-session semantics.

## What a user can do

After an administrator assigns the number to an active tenant member, that
member opens Phone, grants microphone permission, and enters an external number
in E.164 form, including `+` and country code. Dial starts one owned call. The
same request key retries the same destination without starting a second call.
The user can cancel an outbound ringing attempt or hang up an answered call.

Incoming calls show the external caller's number and offer Answer or Reject.
Only the first authorized device to answer obtains media admission. Another
device cannot join by copying the call ID. The browser requests microphone
permission and joins the isolated room after an explicit action. History records
answer, decline, busy, no answer, cancellation, failure, and end independently of the
conversation meeting history. Unanswered calls have zero connected seconds.

Caller ID is not verified app identity. History's connected seconds measure
elapsed time after the observed SIP answer, not an invoice or proof of uninterrupted
audible speech. Use the carrier's records when reconciling charged usage.

If an incoming call was claimed and joined but ended before a SIP-active
observation could be retained, history records a failed outcome with
`answer_unconfirmed`, no answer timestamp, and zero observed connected seconds.
This expresses uncertainty; it does not label that call missed or assert that
the carrier never connected it.

This foreground browser milestone does not promise reliable ringing with the
device locked or the app suspended. It does not implement internal extension
dialing, SIP desk phones, hold, transfers, IVR, queues, voicemail, emergency
routing, recording, transcription, or billing. The extension identifies the
number's assigned member; it is not yet a tenant dial plan.

## Provider prerequisites

Before enabling real calls, the operator needs:

1. An approved SIP carrier, an acquired DID, and permitted outbound caller ID.
2. A LiveKit project/service with SIP supported and the existing secure media
   endpoints and API key/secret configured.
3. An inbound SIP trunk scoped to that carrier and DID, and an outbound SIP trunk
   authenticated to the carrier. Provider-console trunk IDs are configuration;
   carrier passwords remain in the carrier/LiveKit secret mechanism.
4. An **individual** inbound dispatch rule restricted to the inbound trunk, with
   no PIN, room prefix `kc_tel_inbound_`, and a new room per call. It must preserve the SIP trunk, called number,
   caller number, and provider call identity attributes used for attribution.
5. A public HTTPS webhook URL at
   `/api/v1/telephony/livekit/webhook`, configured with the matching LiveKit
   signing key. The proxy must preserve request bytes and the Authorization
   header. Never replace verification with a shared query-string token.

Do not use a dispatch rule that connects separate callers to a shared room. The
callee subscribes only after app Answer; qualify actual ringing and connection
behavior against the selected LiveKit and carrier versions. Keep a separate
synthetic test number for qualification rather than using production customer
traffic.

## Runtime configuration

Supply secrets through the existing deployment secret mechanism. Do not commit
keys, carrier credentials, signed request bodies, or participant tokens.

| Variable | Value or behavior |
|---|---|
| `TELEPHONY_PROVIDER_MODE` | `disabled` by default; `livekit` enables the integration |
| `AUDIO_PROVIDER_MODE` | Must be `livekit` when telephony is enabled |
| Existing `LIVEKIT_*` variables | Reuse the validated media/API endpoints, API key, and secret |
| `TELEPHONY_RING_TIMEOUT_SECONDS` | Default `45`; bounded `10`–`90` |
| `TELEPHONY_MAX_DURATION_SECONDS` | Default `1800`; bounded `60`–`14400` |

Apply forward migrations before starting the new application. Start with the
flag disabled, then enable it only in a synthetic qualification environment
with provisioned trunks. In tenant administration, assign the acquired E.164
number, numeric extension, active member, inbound trunk ID, outbound trunk ID,
and audit reason. Recent password verification is required. Number assignment
does not create provider trunks, purchase a number, or turn on the feature flag.
Non-administrators receive only their assigned number and action permissions;
trunk IDs and provider room identifiers are not part of their phone contract.

## Failure and recovery behavior

The database records the call before dispatch. A durable worker claims outbound
work and accepts answer only from provider evidence. Provider availability
failure stays visible. If a network failure leaves the dial outcome uncertain,
the implementation must not redial automatically; inspect the original provider
room/call before retrying as a new attempt. Replaying a request cannot invent an
answered state or duplicate a charged leg.

For incoming calls, Answer claims the current device's media admission while the
record remains ringing. A read-only provider reconciliation stamps answered
only after the exact SIP participant reports `sip.callStatus=active`. A browser
joining the room alone is insufficient evidence. For outbound calls, the SIP
creation request waits for actual answer before recording answered.

Hangup and reject record terminal state before durable teardown. Provider outage
can delay physical teardown; retry and reconcile the exact isolated room. Ring
and maximum-duration expiry prevent unbounded local active records. Identity,
session, device, phone-assignment, and tenant-audio access changes block new
credentials. Lifecycle revocation queues provider teardown on the same database
transaction.

Answer and dispatch recheck ring deadlines directly; a delayed expiry job cannot
authorize a late charge or answer. An answered browser disconnect allows a
30-second reconnect grace for the same admitted device. Provider confirmation
that the SIP leg ended terminates immediately. A signed room-end event that
arrives before its first SIP join leaves a bounded hashed tombstone, so a late
join cannot reopen the call. A mapped inbound call for a suspended assignee or
audio-disabled tenant records rejection and provider cleanup without app access.

Webhook authentication binds the LiveKit JWT to the exact raw body and issuer.
Duplicate events are harmless, and delayed events cannot reopen a terminal
record. An incoming event can create a call only for an exact provisioned DID and
trunk. Generic room or participant events cannot attribute arbitrary tenants or
prove an outbound telephone answer.

Old browser-connection join/leave events cannot end a replacement connection or
reset its reconnect grace. Webhook bodies above 262,144 bytes receive HTTP 413
before JSON parsing. With telephony disabled, existing signed callbacks still
converge active calls and cleanup; newly mapped incoming calls are rejected
durably and torn down. Keep the protected provider control credentials while
draining calls.

## Qualification record

Retain evidence for the exact candidate revision, deployed digest, environment,
provider versions, and test-number assignment. Keep phone numbers redacted in
general reports and restrict full call records to authorized users/operators.

| Scenario | Required observation |
|---|---|
| Disabled or unassigned | Useful unavailable state; no new outbound provider dial or media credential; existing legs still drain |
| Outbound answered | External phone rings, app and phone hear each other, correct approved caller ID; durable answered/end record |
| Inbound answered | Correct assigned member rings; no audio exposure before explicit answer; two-way audio after answer |
| Competing devices | Exactly one answer wins; second device cannot obtain a token or listen |
| Inbound reject/no answer | Caller disconnects or times out; declined/no-answer history has zero connected seconds |
| Outbound busy/no answer | Truthful observed outcome; no fabricated answered timestamp |
| Remote hangup | Owned record becomes terminal and local microphone stops |
| Replay/reorder | Start key, repeated callbacks, and late join cannot duplicate a call or reopen it |
| Access removal | Logout, device revocation, user suspension, assignment change, and tenant audio disable block fresh admission and converge provider teardown |
| Worker/provider outage | Durable cleanup survives restart; uncertain outbound work does not redial blindly |
| Duration | Ringing excluded; unanswered zero; repeated terminal events do not add duration twice |
| Brief connection between observations | Claimed/joined inbound call without retained SIP-active evidence ends as failed/answer-unconfirmed, rather than a fabricated missed call or duration |
| Carrier reconciliation | Match application record and provider call identity to the carrier outcome; record any charge/duration differences |

Tests using local fake adapters establish domain, authorization, callback, worker,
and UI behavior. Real two-way audio, caller ID, trunk restrictions, carrier
completion, media cleanup, and charging require physical phone evidence and a
real provider. No carrier or phone number is bundled with cloud onboarding.

## Enablement and rollback

Approve served countries, allowed destinations, tenant/user spend and concurrency
limits, toll-fraud response, carrier terms, applicable emergency calling/location
requirements, call-record retention/access, and on-call coverage before an
external calling rollout. Ring and duration bounds limit individual call length;
they do not provide complete spend or destination controls. Keep the feature
disabled while these launch gates or physical qualification remain incomplete.

For rollback, disable new phone admission, drain active calls, and confirm
provider room cleanup. Durable cleanup can continue with the feature disabled
while the existing protected LiveKit credentials remain available; retain those
credentials until teardown is confirmed. Retain the additive tables and call
history when running an older application image. Dropping call/event data is not
an application rollback. Re-enablement needs a fresh assignment/provider check
and a witnessed inbound/outbound smoke after secret or trunk changes.
