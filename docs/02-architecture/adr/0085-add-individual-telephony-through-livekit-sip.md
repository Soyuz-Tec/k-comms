# ADR-0085: Add individual telephony through LiveKit SIP

- **Status:** Accepted
- **Date:** 2026-10-03
- **Owners:** Telephony, Identity, Security, Operations
- **Related decisions:** ADR-0025, ADR-0043, ADR-0057, ADR-0075

## Context

Conversation calls describe a room's lifecycle. They deliberately do not persist
an individual ringing, answer, decline, or missed-call outcome. The first UC
telephony milestone needs one tenant phone number and one assigned extension,
inbound and outbound external calls, device-exclusive answering, and durable
individual history. No carrier account, acquired phone number, trunk, or public
SIP service is supplied by the development environment.

## Decision

Add `CommsCore.Telephony` as an independent business context. It owns phone
assignments, individual calls, processed provider events, and bounded room-end
tombstones. Its facade exposes
Ecto-free call, credential-request, and provider-command projections. Web and
worker adapters use only those projections and declared facade operations.
The strict architecture baseline stays empty. Register all context namespaces,
tables, facade operations, and collaboration bindings in the existing manifests;
do not introduce boundary exemptions or a second owner of conversation calls.

The configured webhook verification port and its behavior belong to Telephony.
The integration implements that exact Core-owned contract and therefore has an
explicit `comms_integrations -> comms_core` umbrella dependency. This is an outer
adapter depending on a domain contract; Core still has no dependency on
Integrations, Web, or Workers. Composition starts Core before the integration
application and its Finch pool. Durable jobs must tolerate the provider pool
not yet being available and follow retry/reconciliation semantics; startup
ordering cannot be used as proof that an external command ran.

Use LiveKit SIP through an integration adapter and the existing audio media
plane. The deployment flag defaults to disabled. Enabling it requires an enabled
LiveKit media provider and the existing validated LiveKit endpoints and secrets.
A tenant administrator separately assigns an acquired E.164 number, inbound and
outbound trunk identifiers, and an active local user with a numeric extension.
Configuration changes require current administration authority, recent password
verification, an audit reason, and tenant ownership checks. Non-administrators
never receive trunk identifiers. Provider secrets remain deployment secrets.

Incoming dispatch must use a trunk-restricted **individual**, no-PIN rule with
room prefix `kc_tel_inbound_` that creates a new private room for each incoming
call. A shared room or unconditional
automatic media subscription is not an acceptable substitute. A verified SIP
participant event maps an exact provisioned DID and inbound trunk to an assigned
tenant and user; telephone caller ID is display data, not an authenticated app
identity. The external participant receives no chat, files, or normal app
session. An authenticated app user obtains a short-lived room credential only
after the current session and device atomically claim the call. The browser
joins and subscribes after that action; competing devices cannot join it.

Persist `ringing`, `answered`, `declined`, `busy`, `no_answer`, `cancelled`,
`failed`, and `ended` as individual outcomes. Outbound connection requires a
verified SIP answer, including the provider's `wait_until_answered` operation;
a successful HTTP request, room creation, or generic participant join is
insufficient. For incoming calls, the app's Answer claims admission while the
record stays ringing. Read-only reconciliation of the exact SIP participant must
observe `sip.callStatus=active` before stamping answer time. The resulting
connected duration is elapsed time from that provider observation, excluding
ringing. It is not an assertion of uninterrupted audible media, carrier-rated
seconds, tariff, or an invoice. Terminal facts do not reopen on delayed events.

A brief incoming connection can end between provider observations. If the app
claimed and joined the call but SIP-active evidence was never retained, terminal
processing records `failed` with `end_reason=answer_unconfirmed`, no answer time,
and zero observed connected seconds. It makes no missed-call, successful
connection, or billable-duration claim. Unclaimed incoming calls retain normal
no-answer semantics; a retained SIP-active observation supports answered/ended
history and its measured interval.

An authenticated `room_finished` event can precede the first SIP participant
event. For the restricted inbound prefix, retain a tenantless SHA-256 room-end
tombstone for 24 hours, capped at 10,000 live entries and pruned on callbacks.
It contains no raw room, phone number, or caller identity. A delayed mapped join
then records a terminal no-answer history and cleanup instead of resurrecting
ringing admission. A mapped DID/trunk for an inactive assignee or audio-disabled
tenant similarly records a failed outcome and cleanup without issuing access.
Ring admission and dispatch recheck deadlines even if the expiry queue is late.
An answered browser disconnection allows only a 30-second same-device reconnect
grace; the exact SIP leg ending remains immediately terminal.
Connection identifiers and signed event time order browser presence; delayed
join/leave events from a prior connection cannot erase the grace deadline or
terminate its replacement connection.

Persist state and provider work before external effects. Outbound start is
idempotent for the same user, request key, and destination; changed requests
conflict. Provider dispatch has a durable claim. An uncertain dispatch outcome
must not be redialed blindly, because the first request may already have incurred
a charge. Durable teardown retries are safe for the same isolated room and
survive worker restart. Expiry bounds both unanswered attempts and active calls.
Recheck current identity, phone assignment, session, and device for every new
credential. Identity and tenant-audio revocation contribute terminal state and
teardown on the existing transaction-scoped lifecycle ports.

Verify LiveKit webhook authentication against the exact raw body before trusting
parsed fields: HS256 signature, API-key issuer, expiry, and body SHA-256. Bind
known participant, trunk, DID, and room identifiers to the existing call. Keep
processed event receipts and reject unsafe attribution. Repeated and reordered
events cannot duplicate calls, add connected duration twice, reopen ended calls,
or substitute a tenant. Poll provider participant state where a lifecycle
webhook alone cannot establish a SIP answer or disconnection.

Enforce the 262,144-byte webhook bound while reading the body, before JSON
parsing; oversized requests receive HTTP 413 without domain mutation. Disabling
telephony blocks new admission while existing signed callbacks and durable
cleanup continue with the protected control credentials. A new mapped incoming
call arriving while disabled records a terminal failure and teardown rather
than issuing access or stranding the external leg.

## Consequences

The existing conversation Calls page and contracts retain their room-session
meaning. A separate Phone surface provides a dialer, incoming answer/reject,
hangup, and owned call history. This milestone assigns one number and extension
per tenant; it does not offer extension-to-extension dialing, number purchase,
porting, phone registration, hold/transfer, IVR, queues, voicemail, emergency
routing, billing, recording, or reliable locked/background mobile ringing.

The feature can be developed and tested with synthetic adapters while remaining
disabled in normal deployment. Local deterministic tests qualify authorization,
durability, event handling, and UI behavior. They cannot establish that a real
carrier accepts caller ID, routes the number, supplies two-way audio, or charges
according to local call duration.

The migration is additive. Deploy the migration before enabling the flag. An
older application can run with the new tables retained; operational rollback
disables admission, drains and reconciles active provider rooms, and retains
history. Do not drop phone records or processed-event receipts as an application
rollback. Disabled admission retains durable cleanup through the existing
protected LiveKit credentials; keep those credentials until teardown is confirmed.

## Alternatives considered

- Extending conversation room sessions with phone states would conflate a group
  room and a personal call, including incompatible missed-call semantics.
- Operating a PBX/SBC immediately adds a second media and operations stack. Reuse
  LiveKit for this bounded first integration; reconsider if carrier, resilience,
  or desk-phone requirements demand an independently operated SIP boundary.
- Shared inbound rooms simplify dispatch but permit cross-call audio exposure.
  Isolated individual dispatch is a hard configuration requirement.
- Automatically retrying uncertain outbound starts improves apparent success
  while risking duplicate charged calls. Preserve a failed/unknown outcome and
  reconcile the original provider identity instead.

## Validation and launch gates

Contract, architecture, backend, worker, controller, and browser checks cover
disabled mode, cross-tenant/user isolation, stale identity, first-answer races,
idempotent start, webhook signature/body mismatch, duplicate/reordered events,
answer-based duration, expiry, restart, and retryable teardown.

Before a carrier-enabled rollout, acquire a number and qualify an isolated
inbound dispatch plus outbound caller ID with two physical endpoints. Capture
ring/answer/reject, remote hangup, no answer, outage/recovery, and provider CDR
reconciliation. Approve served countries, destination and spend restrictions,
carrier obligations, emergency calling/location requirements, retention and
access for call records, and actual operational response coverage. A ring timeout
and maximum duration bound exposure; they do not constitute complete toll-fraud
protection. The [operator and qualification guide](../../12-development-guides/telephony-first-milestone.md)
records the configuration and evidence required before enablement.
