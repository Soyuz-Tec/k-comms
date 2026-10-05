# Meeting artifact privacy and provider qualification

Recording and saved transcription ship disabled. No live provider, jurisdiction
or production readiness is inferred from configuration or synthetic tests.
Participant room grants remain unable to record a room.

Deployment configuration must disable direct peer-to-peer audio before enabling
qualified recordings. Enabling both fails startup; Calls independently rejects
capture creation/start when `direct_audio_p2p_enabled` is true. Set
`DIRECT_AUDIO_P2P_ENABLED=false` deliberately and qualify every participant on
LiveKit. A client's own transport state cannot prove another participant's
media is available to Egress.

## Configuration

The composition root binds the Calls-owned artifact provider, approved storage,
transcription and governance protection ports. Existing LiveKit API and S3
secrets remain protected environment bindings. Never place values in source,
test evidence, logs or setup instructions.

Enablement requires `meeting_artifact_policy` privacy approval, independent
provider qualification and an explicit tenant allowlist. Provider admission
additionally requires `meeting_artifacts_enabled` and `egress_enabled`.
Transcription requires the separate `artifact_transcription` enabled and qualified
flags, fixed HTTPS origin and approved TLS trust. Runtime enablement must use
reviewed environment configuration after privacy/residency/jurisdiction review.

The transcription adapter caps media at 25 MiB, output at 1 MiB and timeout at
60 seconds; lower configured bounds are supported. It sends a fixed model and
`verbose_json` format to `/v1/audio/transcriptions`. The implementation has no
automatic paid-provider selection, provider API key or client-controlled URL.
Operators must verify the chosen self-hosted service's retention, telemetry and
erasure policy before enablement. Successful processing of synthetic data alone
does not establish an approved processor relationship.

## Qualification gates

Use synthetic tenants and distinct participant sessions. Preserve content-free
receipts, exact revisions/digests and result summaries; avoid copying meeting
media or transcript content into operational evidence.

1. Verify every participant sees the capture/transcription disclosure and must
   choose consent. Prove the initial capture command fails before all accept.
   Prove refreshed/new sessions do not inherit another session's consent.
2. Prove explicit host start, persistent recording indication, host stop and
   withdrawal. Measure the stop acknowledgement and provider enforcement bound
   during healthy service, timeout, crash and recovery. Do not enable a policy
   that requires instantaneous enforcement when this provider cannot supply it.
3. Attempt new admission while capture is starting/active/stopping and confirm
   credential issuance is denied. Revoke member/session/device/tenant access and
   confirm durable stop, no authorized new capture and rejected retrieval.
4. Confirm StartRoomCompositeEgress targets only the approved bucket and exact
   server-derived key. Simulate an uncertain response and prove ListEgress adopts
   a single matching job without issuing another start.
5. Capture the raw-body verification outcome without raw bearer tokens. Reject
   wrong key, altered body, expired token, room/job/output substitution, duplicate
   callback identity with different bytes and nonterminal egress-ended events.
6. Prove S3 bucket versioning and server-side encryption. HEAD must include a
   concrete version and full-object SHA256 checksum. ETags, user metadata and
   multipart `COMPOSITE` checksums are insufficient. Some Egress/object-store
   combinations do not provide this proof; these remain unavailable until the
   approved composition can meet it. Do not relax verification to enable them.
7. Prove available playback uses the verified exact object version. Test current
   membership revocation and expired retention. Record the existing approved
   storage download URL lifetime (normally 120 seconds). Already authorized URLs
   remain bearer capabilities until expiry; never claim immediate URL revocation.
8. Manually request transcription from a verified recording. Confirm fetched
   bytes match its exact size/version/SHA256 before provider submission. Reject
   corrupted media, oversized input/output, malformed segments, unsafe origins
   and TLS failures. Verify stable timestamps and no transcript text in logs,
   audit, error responses, artifact metadata or unauthorized search results.
9. Create tenant, conversation and each participant-user legal hold. Prove
   manual and retention purge preserve recordings and transcripts. Run a hold
   creation/purge race and confirm serialization through Governance's tenant
   advisory lock. Expired held artifacts remain physically preserved while
   ordinary member retrieval is unavailable.
10. Remove a hold through the authorized governance process, request deletion
    and prove all versions of the exact unique approved recording key are gone.
    Confirm transcript segments are removed and artifact metadata records the
    completed deletion. Do not erase protected data as a qualification shortcut.
11. Verify caption events from the approved LiveKit composition with the local
    captions toggle off and on. Show the empty-stream explanation when absent.
    Hide captions, change call and end the call; confirm volatile text clears.
12. Execute authorized user and conversation erasure with available recordings,
    transcripts and an active capture. Saved access must disappear immediately;
    active recording/stopping disclosure must remain visible even after expiry.
    Block new capture/transcription while the relevant request is pending. Prove
    the governance request remains in progress through provider stop uncertainty,
    object-purge failure and transcript cleanup. It may complete only after every
    recording version and transcript segment is erased. Repeat with a legal hold
    belonging to a different recorded participant and verify the entire plan is
    refused before artifact mutation.

## Recovery and retention

The minute reconciler enqueues bounded batches of unfinished capture, output
verification, transcription and deletion work. Stop work has priority over
ordinary media processing. Provider uncertainty leaves a visible starting or
stopping state. Examine content-free failure codes and retry/reconcile status;
do not manually label an object available or mint a replacement provider job.

Recording output can be processed only after provider terminal completion and
store verification. Output verification failures preserve restricted objects
and retry; they never issue playback grants. At expiry, terminal output proceeds
to exact-key physical purge even if checksum/encryption qualification failed;
legal holds preserve it. Active capture first stops and waits for terminal
provider evidence so cleanup cannot race a late provider write. Transcription results are committed
atomically and retries replace a single result. Default artifact retention is
30 days when no active governance policy applies; a conversation policy overrides
a tenant policy. Derived transcripts inherit the source deadline.

Queued transcription revalidates the original requester's saved device/session
and current membership before submitting media. Session expiry or revocation
cancels it without contacting the service. Source consent, pinned identity,
privacy approval, retention and erasure are checked under owner locks around the
bounded effect. Operators must provision worker/database capacity for the approved
media/service timeout and qualify stop latency under transcription load.

Capture start uses a 30-second transaction and refuses provider submission if
lock acquisition leaves less than 25 seconds. Recording purge uses 90 seconds
and reserves at least 65 seconds before the shared 60-second aggregate object
purge begins. Transcription uses 150 seconds and reserves at least 130 seconds
for the bounded source fetch, 60-second service request and commit margin.
Transcript-row deletion retains its 15-second transaction. HTTP pool, request
and receive limits apply independently. Qualify worker/database capacity,
contended locks, timeout cancellation and revocation/hold/erasure latency at
these bounds; exhausted budgets retry without starting the external effect.

Governance prepares user/conversation media erasure in the deletion-request
transaction. Calls marks affected artifacts before committing durable stop and
purge jobs; pending requests also block new capture and transcription through
the typed protection projection. The deletion request remains in progress while
provider termination, any object version or derived transcript cleanup is
unconfirmed. Unknown provider/storage state and participant legal holds preserve
the barrier. Operators must resolve the underlying failure or authorized hold,
then let the normal reconciler retry; changing the request or artifact to
completed/deleted manually would discard the required evidence.

The completed-request reconciler also revisits historical governance requests
without current media-erasure evidence. Qualify recovery with such a request,
including a failed purge and a participant hold. Confirm reconciliation records
completion evidence only after both media owners report no pending erasure and
the derived-content cleanup succeeds. Keep content-free request/artifact IDs,
attempt counts and provider/storage outcomes in the qualification receipt.

Disabling capture switches prevents new capture without stranding control calls:
stop, ListEgress and authenticated webhook convergence retain the protected
provider configuration. Keep those controls available until all jobs have ended.
If LiveKit reports no matching job after an uncertain start, investigate provider
inventory without issuing another start. Restore from verified backups according
to the normal production data contract; replay only authenticated provider events.

Rollback requires `uc_artifact_lifecycle_v1` on the approved target while
recording/transcript state or artifact work remains. The current release's
quiesced preflight obtains a content-free owner count and active-job evidence;
an incompatible target is refused. Preserve retained schemas, consent, hold and
erasure records and use a compatible bridge or roll forward. Never relabel an
older image with current capabilities or purge held media to make a probe zero.

## Evidence status

The code and synthetic acceptance tests implement the lifecycle. Production
privacy approval, provider credentials, regional deployment, live capacity,
recording output integrity, provider enforcement timing, legal-hold races and
external service retention require separate recorded qualification. Default-off
controls must remain in place until those requirements pass.

The supported rollback inventory guard runs after candidate migration completion.
It requires the Calls artifact, transcript, meeting and occurrence inventories;
a missing table is missing evidence and refuses rollback. Connection failures
and invalid owner counts also refuse proof. Before removing these owners, cancel
retained schedules, end their policy-linked rooms, scrub retained authored meeting
history through authorized held-scope-safe erasure and converge artifact erasure
and clear active demand jobs through the authorized lifecycle.
