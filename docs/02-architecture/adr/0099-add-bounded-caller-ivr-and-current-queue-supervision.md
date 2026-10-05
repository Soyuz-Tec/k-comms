# ADR-0099: Add bounded caller IVR and current queue supervision

- **Status:** Proposed; source prototype, integration and qualification pending
- **Date:** 2026-10-05
- **Owners:** Telephony, Identity, Security, Operations
- **Related decisions:** ADR-0085, ADR-0088, ADR-0089, ADR-0092

## Context

The current Phone owner has one Number and one optional Route per tenant.
Qualified ARI supplies caller-only holding, notice-gated voicemail and exact
paid-resource cleanup. It does not currently select an inbound route from a
caller menu or present current queue totals. No carrier, DID, qualified PBX,
physical endpoints or audible prompt receipt has been supplied.

## Decision

Add one versioned IVR menu for the existing Number. An approved PBX-owned
`sound:` name, one to nine single-digit choices, a fixed fallback, a 5–30 second
digit window and at most two retries describe one level. Targets are the same
Number's current queue/shared line, its qualified mailbox, an independently
qualified prefix-approved E.164 destination, or hangup. There is no recursive
menu, arbitrary URL, arbitrary SIP URI, user identity supplied by a caller,
multiple-queue cardinality change or emergency-routing claim.

Telephony owns immutable per-call menu snapshots, current steps, durable event
receipts and effect claims. The caller's original fixed call deadline clamps
every digit window, retry, origination and voicemail capture. Expiry terminates
and cleans up; it never initiates an expensive fallback after authority expires.
An IVR caller consumes bounded Number/tenant admission but does not reserve an
agent's active-call slot or receive browser credentials. The existing Route must
atomically choose an eligible agent before any app answer or media credential.
The final owner integration must prove the common admission lock and caller cap
across IVR, routed and individual admissions; the prototype alone is not proof.

Only the selected qualified ARI implementation supports this feature. The new
port defaults unavailable. Provider configuration, current tenant policy,
sorted current workspace human parents, exact Call and Run locks, and absolute
network/commit budgets fence effects. Human menu administration requires a live
workspace owner/admin and current recent verification after lock waits. Caller
events confer no human session or role. Governed voicemail selection acquires
the existing Governance tenant policy fence before quota, identity, mailbox,
Call, capture and media effects. The menu introduction is never consent evidence
for voicemail: the existing separate notice playback remains mandatory.

Freeze exact tenant, call, room, SIP participant, external caller channel and
optional app leg before playback. Move only the caller to the private holding
bridge. Keep an exact app leg outside caller audio so a queue selection can
resume its original mixing bridge. Every channel/bridge preflight rejects
foreign or substituted members. Existing termination removes only owned roles
and bridges and must re-enumerate their absence before a cleanup receipt.

Issue a once-only opaque effect claim to the configured worker, store its
non-enumerable fingerprint, and commit claim consumption before a forward
network transaction. Worker crash, lost response, timeout or commit failure
permits exact read-only reconciliation. It cannot republish a prompt, redial a
destination or repeat an uncertain connection. Each retry has a new deterministic
Run/step playback ID. Submission never means the caller heard a prompt.
Actual matching PlaybackFinished or exact retained ARI playback state supplies
completion evidence before digit selection is admitted.

External destinations use the existing deterministic `kc_consult_<call>` role
and fixed caller lifetime. Origination is one claim. Read-only observation of
that exact bound channel being Up permits a separately consumed connection
claim. Only read-back of an owned mixing bridge containing exactly the bound
caller and target establishes connection. Neither HTTP acceptance nor a generic
channel event establishes convergence. Current prefix qualification is checked
again at every new effect. Pending and uncertain handoff retains the original
caller and existing cleanup/maximum-deadline semantics.

One ARI application WebSocket carries both voicemail notices and IVR events.
Do not register competing application event streams. Its bounded private spool
for IVR expires events after 180 seconds; a received random event receipt persists
unchanged across delivery retries. Forward ChannelDtmfReceived only for the
exact external role and complete server-owned `KC_*` bindings including Run and
step. App and consultation digits are excluded. Playback events require the
deterministic IVR ID, external channel target and approved prompt. HMAC protects
the exact bounded body and timestamp, and received input is retained only as a
domain-separated HMAC fingerprint. No raw received digit, caller profile or
credential enters event receipts.

Add explicit self-controlled Ready/Away/Wrap-up state for active current Route
members. State expires within one hour; Wrap-up is at most 30 minutes. Missing
or expired state preserves current Routing eligibility. Existing Identity DND,
revocation, current membership, queue order and exclusive-device answer remain
authoritative. This is a requested queue disposition, not observed online
presence or a background mobile ring guarantee. Identity lifecycle erasure
removes this owned user state before final key anonymization; retained current
identity authority fences its writers.

The supervisor projection requires current workspace owner/admin and recent
verification. It exposes current aggregate waiting, offered and answered calls,
configured member count, capacity and oldest observed wait using retained
Call.started_at. It contains no per-person activity series, content, listening,
whisper, barge, call quality, historical SLA, billable seconds or invoice.

## Migration, rollback and qualification

The additive migration retains menus, Runs, receipts and agent dispositions.
Its down operation refuses any retained state or IVR Call. Register the exact
new immutable `ivr_contact_center_v1` release capability and owner hazard counts
before rollout. Older images must not ignore retained enabled menus or agent
dispositions. Application rollback disables new admission, drains and reconciles
the exact paid resources, and preserves history and protected cleanup credentials.
Do not weaken a capability, backup, erasure, hold or cleanup gate.

Tests must cover fixed lifetime, caller-only input, exact notice versus menu
proof, stale/replayed events, current authority after real lock waits, sorted
owner locks, Number cap races, device exclusion, current DND/member removal,
once-consumed claims, process restart and unknown outcomes, foreign channels,
unchanged-state migration refusal and historical rollback hazards. Public HTTP,
actual worker execution, desktop/mobile interaction, architecture, release and
protected CI qualification follow integration onto the committed parent.

Source tests do not qualify a carrier, two-way audible media, heard prompts,
received DTMF, destination charging, emergency obligations, cleanup of a real
PBX, mobile background ringing or production. Provider admission stays disabled
until the [IVR qualification guide](../../14-operations/ivr-contact-center-qualification.md)
and existing Phone/voicemail qualification gates have current evidence.
