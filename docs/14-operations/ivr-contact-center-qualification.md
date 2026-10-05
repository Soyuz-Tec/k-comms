# IVR and current queue qualification

Status: source prototype; parent integration, source qualification and real
provider qualification are pending. Do not enable admission from this document.

This increment uses one existing tenant Number, one existing Route and one
optional mailbox. It adds one bounded menu and current aggregate queue totals.
It does not supply a SIP carrier, DID, PBX installation, historical SLA,
listening/whisper/barge, or background mobile ringing.

Use the existing protected ARI credentials, pinned HTTPS origin, application and
exact `KC_TENANT_ID`, `KC_CALL_ID`, `KC_LIVEKIT_ROOM`, `KC_SIP_IDENTITY` and
`KC_ROLE` channel bindings. IVR also requires exported `KC_IVR_RUN_ID` and
`KC_IVR_STEP` channelvars in ari.conf. Caller input never supplies these facts.
Prompt names must be explicitly approved PBX `sound:` media; arbitrary URLs or
uploads do not become approved prompts.

Run one combined `ari_event_relay.py` per ARI application. Its existing notice
destination remains `/api/v1/telephony/pbx/webhook`. An optional IVR destination
uses `/api/v1/telephony/ivr/webhook` with a separate bounded private IVR spool.
The IVR helper does not start a second application WebSocket. Persist a spool
receipt unchanged across delivery retries and expire IVR events after 180 seconds.
The menu prompt cannot satisfy the separate voicemail recording notice.

Before enablement, retain receipts for all of the following:

- The final parent-integrated commit passes owner, protocol, real lock-race,
  worker, HTTP, browser, strict architecture and release capability checks.
- A synthetic migration rehearsal proves every forward migration, guarded
  retained-state down refusal, unchanged table/catalog/ledger evidence on
  refusal, and a disposable empty-schema down/up drill.
- With two physical endpoints and the actual carrier/PBX, hear the approved
  prompt, select every configured digit, test invalid input and silence, and
  prove all retry/capture/target deadlines stay inside the unchanged caller
  lifetime. Record actual provider identities without publishing credentials.
- Inject app-leg and consultation DTMF and prove neither selects a caller menu.
  Replay, delay and reorder current/old-step relay deliveries without duplicate
  selection, prompt publication or a charged destination origination.
- Kill the worker after claim consumption and after provider acceptance. Read
  back the original deterministic playback/target/bridge; never redial an
  uncertain target. Confirm explicit operator recovery for unconverged work.
- Remove a Route member, set DND/Away/Wrap-up, expire or revoke identity, disable
  tenant audio, and end either physical leg. Verify current routing, device
  exclusion and only-owned resource teardown followed by verified absence.
- Attempt foreign/substituted channel and bridge membership. Admission and
  cleanup fail closed instead of deleting foreign resources or manufacturing a
  cleanup receipt. Record the operator resolution and reconcile the same IDs.
- Select voicemail and separately hear its approved recording notice. Only its
  matching actual notice proof admits caller-only capture. Verify holds,
  encrypted pinned objects, retention, source cleanup and governed erasure.
- Confirm supervisor totals against current retained Calls. Oldest observed
  wait begins at Call.started_at; it is not a historical service-level metric.
  Explicit agent disposition is not an observed online-presence claim.

Enablement also retains all existing served-country, destination/spend,
caller-ID, emergency/location, privacy, retention, response-coverage and provider
CDR decisions from the Phone and advanced-telephony guides. No paid acquisition
or real number calling is authorized by synthetic qualification.

Rollback preserves state and protected cleanup credentials. Disable new
admission, drain the exact frozen resources, keep history and immutable
capability receipts, and use the protected same-digest deployment chain. An older
image cannot run against retained IVR/agent state without the exact capability.
The destructive migration down is a disposable empty-database drill only.
