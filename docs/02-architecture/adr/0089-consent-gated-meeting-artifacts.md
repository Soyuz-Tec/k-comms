# ADR-0089: Consent-gated meeting artifacts on approved providers and storage

- **Status:** Accepted for implementation; provider enablement requires qualification
- **Date:** 2026-10-04
- **Owners:** Calls, security, privacy, platform and governance
- **Related decisions:** ADR-0025, ADR-0043, ADR-0086, ADR-0087

## Context

Calls needs recordings, captions and post-meeting transcripts. ADR-0025
explicitly prohibited recording and transcription. The LiveKit room token held
by a participant remains unable to administer or record a room. Persisting
meeting content introduces Restricted data, new consent obligations, provider
processing, storage integrity and retention requirements.

No provider credentials, jurisdiction-specific recording policy or live
qualification evidence accompany this implementation. Shipping code therefore
must preserve a disabled default and distinguish capability implementation,
configuration and independently qualified use.

## Decision

Calls owns `call_artifacts`, `call_artifact_consents`,
`call_artifact_provider_events` and `call_artifact_segments`. Scheduled meeting
associations use scalar Calls-owned meeting and occurrence identifiers. Released
adapters receive Ecto-free artifact, provider, storage and transcript contracts.

Recording requires all of the following:

1. The tenant appears in the explicit enabled tenant set, privacy approval and
   independent provider qualification are enabled, and the subject is a member.
2. LiveKit Egress and the existing approved S3 composition are configured.
3. A currently admitted call host or moderator explicitly requests capture.
4. Every currently admitted session explicitly consents to storing meeting
   audio, video and screen sharing and optional later transcription.
5. The host explicitly starts capture after consent is complete.

Recording-qualified enablement and direct peer-to-peer audio are mutually
exclusive at deployment configuration. The runtime rejects enabling both;
operators explicitly disable direct audio before enabling recording. Calls also
rejects recording creation/start when its direct-audio flag is on. A local
client transport indicator cannot prove that another participant publishes
media to the provider, so it is insufficient to authorize capture.

Consent is bound to an admission and session. An account, refreshed browser
session or client-supplied participant identity cannot substitute for it. New
admissions during capture are rejected; an already consented session may refresh
its credentials while capture is recording. Withdrawal and access revocation
durably request stop. The UI retains the recording/stopping indicator until the
provider confirms capture ended. Provider stop failure is retried and reconciled;
the application does not claim instantaneous provider enforcement.

Calls uses consumer-owned provider, transcription, storage and protection ports.
Governance implements protection using its tenant advisory lock, active tenant,
conversation and participant-user legal holds, and effective retention policy.
Physical erasure holds that same lock through the bounded storage call so a hold
cannot commit between the final check and erasure. A hold preserves expired data;
ordinary member retrieval still ends at the retention deadline.

Governance user and conversation erasure includes every artifact requested by or
containing the affected user and all derived transcripts. Calls durably flags
the affected records, removes saved retrieval/search access immediately, and
keeps active capture disclosure visible while provider stop converges. A deletion
request remains in progress until the owner confirms all source object versions
and transcript segments are erased. Participant legal holds refuse the complete
plan before any erasure flag is written. Pending, approved and executing erasure
also block relevant new capture and transcription. Expired terminal output is
purged even if it never passed playback verification; a writable active capture
must first reach provider terminal completion.

LiveKit Egress receives only the server-derived room and exact unique object key
inside the approved bucket. A webhook is decoded only after HS256 issuer/time
and raw-body SHA256 authentication. Durable callback identities reject a replay
whose bytes differ. Job, room and output substitutions are rejected. An uncertain
StartRoomCompositeEgress result is reconciled through ListEgress; the command is
never automatically repeated because LiveKit supplies no start idempotency key.

Recording output is available only after HEAD verification establishes an exact
version, byte count, encryption, ETag and full-object SHA256. Metadata-only,
unversioned and multipart composite checksum evidence fails closed. Playback
rechecks current identity and active conversation membership before signing a
version-pinned approved-store URL. Existing download expiry bounds already
issued URLs; immediate cancellation of a signed URL is not claimed.

Transcription is a separate explicit host action on a verified recording. The
configured self-hosted Whisper-compatible service receives the exact version
only after the bounded media download is cryptographically rehashed. The
adapter uses the fixed `/v1/audio/transcriptions` multipart API at a protected
HTTPS origin with DNS-pinned transport, approved system TLS trust and bounded
request duration, media bytes and result size. It sends no tenant metadata or
client-controlled provider URL. Transcription stays disabled until the service
is independently qualified and privacy approved. Result segments are bounded,
ordered and committed atomically. They inherit source consent and expiration.
Restricted transcript text appears only in authorized transcript retrieval and
authorized content matching; artifact metadata and audit events contain no text.

Deferred transcription saves private requester device/session identity and
revalidates its live grant and current conversation membership before sending
media. Bounded start/transcription effects serialize with erasure and revocation
under the governance tenant barrier and owner row locks. Source recording locks
precede derived transcript locks. A queued start rechecks every admitted
participant's live grant and explicit consent immediately before the provider
effect; its durable initial claim still prevents replay after an uncertain result.

Live captions consume the actual LiveKit `TranscriptionReceived` event only
after the user enables the local view. Text stays in bounded volatile UI state
and clears on hide, room change or teardown. This does not start a speech
recognition engine, recording or provider transcription job. An empty stream
truthfully reports that configured provider captions have not arrived.

## Validation and enablement

Source tests cover disabled defaults, explicit session consent, new-admission
denial, consent withdrawal, callback signature/substitution/replay controls,
approved storage identity, membership and session revocation, legal holds,
retention, exact-key erasure, transcript source rehashing and bounded provider
contracts. Browser journeys exercise actual rendered consent, status,
post-meeting retrieval and failure recovery; synthetic providers establish
application behavior only.

Live qualification separately must prove consent with multiple participants,
admission and revocation during capture, provider outage/recovery, Egress output
versioning/encryption/full checksum, secure playback, physical erasure,
transcription results, legal-hold races and jurisdiction/residency approval.
Configured providers and passing synthetic tests do not establish this evidence.

## Rollout and rollback

All capture and transcription admission switches are off by default. Enable a
synthetic pilot tenant only after the runbook qualification gates are recorded.
To roll back, disable new capture/transcription, stop existing provider jobs and
retain authenticated callback, reconciliation and deletion control configuration
until convergence completes. Preserve artifact/consent/audit rows and protected
objects; do not drop the additive migration or override legal holds.

Rollback to an image without these owners is blocked while any artifact lifecycle
record, stored transcript segment, scheduled meeting/occurrence, policy-linked
active room, or active demand job requires the new workers. Calls supplies typed
owner counts; only physically deleted artifact metadata with a completed-erasure
timestamp is excluded. Cancel schedules and end their linked rooms before
removing meeting-policy code. The supported guard runs after migration completion
and requires every owner inventory table. Missing tables, unexpected database
failures and invalid projections refuse rollback. Periodic reconciliation with no remaining owner content is not
itself active demand work.
