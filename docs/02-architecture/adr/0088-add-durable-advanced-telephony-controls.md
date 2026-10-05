# ADR-0088: Add durable advanced telephony through capability-bound SIP and PBX controls

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Telephony, Identity, Security, Operations
- **Related decisions:** ADR-0085, ADR-0086, ADR-0087, ADR-0089, ADR-0090

## Context

The individual Phone context owns isolated rooms, verified SIP answer evidence,
exclusive device admission, history and cleanup. LiveKit SIP has no native true
hold, consultation, voicemail or queue routing. Mute cannot establish hold, and
dialing another number cannot establish transfer. No carrier/DID or qualified
PBX credentials have been supplied.

## Decision

Extend Telephony while conversation Calls retains its room semantics. Core owns
telephone commands, routes, mailbox metadata, recipient selection and declared
capability/event/provider/storage ports. Workers and integrations perform effects.
Provider capability output distinguishes actual transport, configuration,
qualification and unavailable reasons. Admission defaults disabled.

Native DTMF uses livekit-client `localParticipant.publishDtmf`, the reliable
`SipDTMF` packet consumed by LiveKit SIP. There is no invented `SIP/SendDTMF`
RPC: RoomService user data is a different protocol. Persist a single-use owning
session/device authorization before SDK publication. A replay never republishes
the digit. Submission acknowledges the SDK, never carrier receipt. Store an HMAC
payload fingerprint, rather than raw digits or a brute-forceable single-digit
SHA-256. Expired or uncertain outcomes remain unknown.

Native blind transfer uses actual `SIP/TransferSIPParticipant` REFER and an E.164
`tel:` target. Carrier qualification and an operator destination-prefix allowlist
are mandatory. Provider submission does not prove transfer completion. Claimed
or uncertain REFER work is never retransmitted after restart.

Optional Asterisk ARI supplies true hold, resume, consultation, completion and
cancel behind the LiveKit SIP entry. It is a separately provisioned external
infrastructure dependency. Pinned HTTPS, narrow credentials, bounded responses,
exact tenant/call/room/SIP-identity/role channel bindings and deterministic IDs
are required. Missing, ambiguous, foreign or substituted bindings fail closed.
Persist the exact provider handles before media effects.

Hold moves the external leg into a private holding bridge with actual music on
hold. Resume restores its original mixing bridge. Consultation creates one
allowlisted PJSIP channel with a fixed ID, holds the caller and bridges an
observed Up target with the app leg. Recovery reconciles the same channel and
cannot redial an absent uncertain target. Complete joins caller and consultation
and removes the app leg; cancel removes the consultation and restores the caller.
The owning device may reconcile safe unknown PBX work. DTMF and REFER cannot be
replayed through that operation. Current identity, device and policy are checked
at every new command, claim and actual provider effect. Core holds current tenant,
user, device, session and call locks through the typed provider-control port,
with a bounded network budget. Expired authorization cannot start a forward
effect; explicit safe reconciliation renews the owning device's authorization.

Call termination also controls the paid PBX resources. Project the frozen channel
and bridge bindings into cleanup, preflight every owned role and bridge member,
remove only exact owned legs and private bridges, and re-enumerate to prove their
absence before persisting a cleanup receipt. Admission may be disabled while
retained credentials still permit cleanup. An unavailable provider or a foreign
substitution leaves cleanup incomplete; it never authorizes another origination.
The terminal call lock fences the effect with a 35-second transaction, a reserved
25-second provider budget and commit overhead. Stored voicemail remains subject
to its separate governed erasure path.

After completed or claimed uncertain consultation completion, app/SIP departure
and LiveKit room completion can be an intentional handoff. Preserve the exact
external pair and poll the original bound PBX external channel every five seconds
until verified remote absence or the unchanged maximum call deadline. Then end
the call and remove the remaining owned consultation and bridges. Explicit End,
voice disable and identity revocation terminate the pair immediately through the
same cleanup path. An uncertain completion cannot originate another leg.

Caller-only voicemail similarly removes the app leg intentionally. Preserve only
exact pending capture identity, poll the original PBX caller, and finish on
verified caller absence, persisted capture completion/erasure, or the original
fixed recording deadline. Reservation shortens a manual call deadline to at most
180 seconds and replay cannot extend it. Queued capture uses the already stored
recording deadline. Browser join credentials are denied after actual or claimed
uncertain handoff/capture, while the owning device retains explicit End.
LiveKit cleanup wraps the complete HTTP lifecycle in a supervised absolute
five-second deadline; a blocked transport or late acknowledgment leaves cleanup
pending.

Versioned, audited route configuration requires administration and recent
verification. Active human membership is tenant-contained and capped at 25.
Queues use oldest-waiting-first and round-robin assignment, bounded to 100 calls
and a 10–600 second wait. Shared lines offer one or all eligible members. Current
DND, revocation and capacity are checked before offer, routing retries and answer.
One atomic answer selects the durable history owner and exclusive device. Current
route members receive effective number readiness and shared outbound caller ID;
trunks remain private.

Waiting callers receive actual PBX holding-bridge music. Exact bridge resume
precedes SIP answer reconciliation. Expiry allows a bounded 15-second routing
handoff. A qualified mailbox can capture a timed-out queued call through a
server-owned command; otherwise it ends no-answer with cleanup. Capture does not
manufacture an app answer time and its isolated leg expires within 180 seconds.

Voicemail persists owner, notice, capture identity, retention and storage object
before recording. A real ARI TLS WebSocket relay supplies signed, bounded, durable
PlaybackFinished evidence for the exact caller notice. ARI does not natively POST
HMAC webhooks. Core verifies the exact raw body, timestamp, channel, playback ID
and notice URI. Capture stays fail closed without notice completion. Recording
completion uses exact stored-recording reconciliation and validated WAV bytes;
ARI stored metadata has no invented duration field. Remove the caller from its
bridge before caller-only channel recording, bounded to 120 seconds. Encrypted
version-pinned storage, current playback authority, revocation, retention, holds
and source cleanup follow the voicemail runbook and owned ports.

## Consequences

The migrations are additive. Application rollback disables admission, drains and
reconciles provider work, and retains history, commands and mailbox receipts.
Keep protected provider credentials until cleanup finishes. Do not destructively
roll back schema while retained or active records remain.

Local ownership, protocol, DND, queue and recovery tests qualify source behavior.
They do not prove carrier routing, two-way audio, received DTMF, REFER acceptance,
consent law or physical-device background ringing. Enablement requires the
[qualification runbook](../../14-operations/advanced-telephony-qualification.md)
and [voicemail runbook](../../14-operations/telephony-voicemail-runbook.md).
