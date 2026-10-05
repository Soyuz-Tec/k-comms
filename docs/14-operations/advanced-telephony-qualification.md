# Advanced telephony qualification and recovery

Status: Implemented adapters; external qualification required.

No carrier, DID, PBX or physical endpoints are supplied by development. Keep
telephony, transfer and PBX admission flags off until evidence below exists.
Configuration and synthetic tests do not establish provisioned service.

## Provider and exact PBX binding

Complete [first-line qualification](../12-development-guides/telephony-first-milestone.md)
first. Retain isolated individual dispatch and exact DID/trunk attribution.
Verify native reliable SipDTMF at a physical RFC2833 receiver. Qualify native
REFER with permitted E.164 destination prefixes; arbitrary SIP URIs are rejected.

Deploy Asterisk ARI behind the LiveKit SIP trunk as separately managed qualified
infrastructure. Its trusted SIP/Stasis application must create distinct external
and app legs and a private mixing bridge, and expose these ARI `channelvars`:

| Variable | Required authority |
|---|---|
| `KC_TENANT_ID` | Provisioned Core tenant UUID |
| `KC_CALL_ID` | Exact persisted Core call UUID |
| `KC_LIVEKIT_ROOM` | Exact private LiveKit room |
| `KC_SIP_IDENTITY` | Exact signed SIP participant identity |
| `KC_ROLE` | `external`, `app`, or server-created `consult` |

The trusted PBX application establishes the mapping from authenticated trunk and
persisted Core call before controls run. Strip equivalent untrusted carrier
headers. Caller ID and dialed digits never establish a binding. Missing or
ambiguous values fail closed; the adapter never guesses another channel from a
phone number. Qualify mixing isolation, Stasis ownership, absolute call timeouts,
and remote hangup propagation. Successful transfers must not leave unbounded
chargeable legs.

The ARI URL is an HTTPS DNS origin on port 443 using the existing pinned HTTP
policy. Use a narrow separate ARI account and managed deployment secret files.
The consulted PJSIP trunk is an operator-selected slug with prefix-approved
destinations. Set `TELEPHONY_CONTROL_PROVIDER=asterisk_ari` and optional
`TELEPHONY_PBX_*` configuration only after qualification. PBX enabled/qualified
flags default false; native REFER has separate transfer enablement and prefix
policy. Keep protected credentials during disable/drain so cleanup continues.

## Actual caller notice relay

ARI supplies TLS WebSocket events and does not POST native HMAC callbacks.
[ari_event_relay.py](../../deploy/telephony/ari_event_relay.py) is the optional
shipped notice adapter, with no third-party Python dependencies. It does not
start automatically. Run it as a least-privilege managed service with:

- HTTPS `ARI_ORIGIN`, `ARI_APPLICATION`, `ARI_USERNAME_FILE`, `ARI_PASSWORD_FILE`.
- HTTPS `KCOMMS_WEBHOOK_URL` ending exactly in `/api/v1/telephony/pbx/webhook`.
- `KCOMMS_PBX_WEBHOOK_SECRET_FILE`, matching app `TELEPHONY_PBX_WEBHOOK_SECRET_FILE`.
- Persistent private `ARI_RELAY_SPOOL`, bounded to 1,000 mode-0600 receipts.

The relay authenticates and DNS/TLS-pins its WSS source, bounds frames, and
forwards only minimal K-Comms PlaybackFinished notice evidence. The HMAC covers
timestamp plus exact raw body. Five-minute expiry, exact channel/call/notice
checks and durable event identity reject substitutions and replay effects.
Capture remains fail closed without notice completion. Recording completion is
independently reconciled through exact ARI stored resources and validated WAV.

## Acceptance and recovery

Capture provider resources/CDRs and physical endpoint evidence without secrets or
PINs. Verify:

1. Received digits `0–9`, `*`, `#`; single-use SDK authorization and unknown/replay
   controls; stored receipts contain HMAC fingerprints and no raw digit sequence.
2. Actual caller MOH, app/caller isolation, exact resume and restart reconciliation.
3. Accepted/rejected native REFER, destination ringing/answer, actual original-leg
   end and truthful uncertain outcome without automatic retransmission.
4. One consultation channel, observed target Up, caller held, complete/cancel,
   remote hangup, no answer and outage. Restart cannot redial a missing target.
5. Two real shared-line members and multiple devices: current offers only, one
   answer/history owner, stale loser denied, and DND/busy/revoked/foreign controls.
6. FIFO/round-robin queue, capacity/deadline, current DND re-evaluation, real MOH,
   answer resume, and timeout mailbox or no-answer/cleanup when unavailable.
7. Notice before caller-only capture, exact encrypted version-pinned storage,
   current playback/read/revocation, retention, holds and source cleanup in the
   [voicemail runbook](telephony-voicemail-runbook.md).
8. Worker restart, synthetic backup/restore and application rollback retain and
   reconcile call, queue, command and voicemail identities.
9. Physical desktop/iOS/Android, accessibility, two-way audio, microphone consent,
   background limits, reconnect ownership and available controls.
10. Pause a claimed provider command, revoke its user, device or session, and
    resume the worker. No provider effect may occur. Qualify the converse race:
    when an authorized bounded effect already holds the current identity/call
    locks, revocation waits for that effect and subsequent execution is denied.
    Include mailbox reassignment and pending governed erasure before voicemail
    recording; a stale claimed recording command must not bypass the fence.
11. End held, consulting and transferred calls, including explicit End, session
    revocation and fixed maximum duration. With admissions disabled and credentials
    retained, prove exact external/app/consult channels and owned holding/mixing
    bridges are absent. A successful DELETE response without observed absence,
    a foreign bridge member or provider outage must leave cleanup incomplete.
    Preserve stored voicemail for its governed retention/erasure worker.
12. Complete a handoff and deliver intentional app/SIP departure and room-finished
    events. The transferred pair must continue. Original bound PBX external-leg
    remote disappearance is polled at five-second intervals and then cleans the
    remaining consultation. Repeat with an acknowledgment lost after completion:
    the claimed uncertain completion still preserves the pair and never redials.
    Provider outage cannot extend the unchanged saved maximum call deadline.
13. Caller-only voicemail keeps recording through expected app/SIP/room departure.
    Observe the original bound caller, then complete stored capture or end the
    caller remotely. Either path ends and cleans the call within the bounded
    monitor interval. The fixed recording deadline cannot be extended by replay;
    existing shorter session/call deadlines still win. No browser media rejoin
    is admitted after actual or claimed uncertain capture/handoff.
14. Block the LiveKit cleanup transport before response, including pool/connect
    or TLS setup. Its supervised five-second absolute deadline must return
    unavailable, terminate the waiting task, and leave the durable cleanup receipt
    unset. A later cleanup retry may prove absence; it never creates another leg.
11. End/revoke/expire a held or consulted call and confirm exact owned ARI
    channels, MOH/bridges and LiveKit room are gone before cleanup is complete.
    Substitute a foreign channel/bridge member, fail ARI after LiveKit success,
    restart midway and disable new admissions. Cleanup must remain pending on
    uncertainty, use retained credentials and never originate/transfer/redial.
    A transferred external/consult pair must survive ordinary app/room departure,
    then terminate on verified remote end or fixed call expiry. Stored voicemail
    remains governed by its independent hold/erasure policy. Pending caller-only
    voicemail must also survive intentional app departure until verified caller
    end, capture completion or its fixed deadline; stale offer/ringing expiry
    must not cut off capture.

Unknown DTMF and REFER cannot be replayed. Unknown safe PBX work can reconcile
only persisted IDs from its owning device. An unknown claimed consultation with
saved bindings can be explicitly cancelled by that device: the durable cancel
retires the forward command, verifies or deletes only the exact consulted leg,
and resumes the original bridge. A pending/dispatching operation or an unknown
hold/REFER cannot be superseded this way. Binding disagreement requires provider
investigation. Disable admissions, preserve recording encryption and storage,
and retain credentials until cleanup finishes. Cleanup/expiry transactions use
35 seconds and check the remaining budget after the call lock: cleanup reserves
25 seconds plus a 3-second margin for the aggregate ARI/LiveKit effect; bound
external-call observation reserves 5 seconds plus the same margin. Qualify contended
locks, provider cancellation and cleanup retries within these bounds. Retain additive tables and
receipts on application rollback. Record approved countries/spend limits,
consent policy, operational ownership, actual provider versions, backup/restore
evidence and protected immutable deployment receipts before launch.
