# ADR-0102: Post-recording recognition and explicitly consented quote summaries

Status: Accepted

Implementation: source candidate; full backend, browser, actual waveform, provider and release qualification pending.
Parent: frozen Phase2 `4b6522fbaaf6e5b1caca42d1ec705a2dcbb3827f`.

Calls remains the existing recording, consent, transcript, provider-effect and
retained-content owner. Recognition consumes its exact verified versioned media
object through the actual Whisper-compatible HTTPS adapter. The maintained CPU
engine is faster-whisper 1.2.1 with CTranslate2 4.8.2, a pinned MIT tiny.en model,
and a killable inference child. The service does not download models during a
request. Recognition produces bounded saved post-recording segments; it does
not produce a live caption stream. Existing LiveKit caption events continue to
be consumed only when that transport actually supplies them.

Summaries require a separate disclosure at recording request time, a separate
`meeting-summary-v1` decision from every original capture admission, and an
ended call. Ordinary recording/transcription consent grants no summary consent.
The actual local extractive adapter selects unchanged complete transcript lines
in source order, preferring decision/action/question language. Its output is
labeled `extractive_quotes`; it makes no generative, speaker-attribution or
external-provider receipt claim. Source text is untrusted Restricted content.
No automatic summary or recording is enabled.

Governance's barrier precedes retained identity authorization. All sorted
identity parents and original Device/Session authorities are retained before
conversation, call and source-before-derived artifact locks. A rejoined session
cannot replace an original capture admission's consent. Normal call-end admission
revocation is distinguished from removal/eviction; retained identity or membership
revocation, expiry and pending erasure prevent production and retrieval. Consent,
source digest, original session grants and expiry are checked again while the
bounded effect still holds the owner locks. Consent withdrawal remains possible
from the participant's fresh current session and invalidates summary access;
physical erasure waits for any legal hold.

A summary's one-use random claim fingerprint is committed before execution.
Only the claiming process receives the token. Reconciliation preserves a claim
while legitimate execution may be in flight. A lost/unknown result becomes a
terminal failure and is never automatically repeated. A unique retained summary
per transcript prevents another idempotency key from repeating an uncertain
operation. Receipt text and source/output digests commit atomically. Parent
recording/transcript deletion and Governance erasure include derived summaries;
source retention bounds all derived expiry. Audits contain identifiers and state,
never transcript or summary text.

Public operations remain on `CommsCore.AudioCalls`; new persistence-neutral
summary request/result/view and configured dispatcher contracts are Calls-owned.
Only the exact configured extractive adapter and summary worker bindings are
added. Migration `20261006000800` owns the summary content table and additive
consent/proof fields. The original empty architecture baseline is unchanged.
The exact manifest transition is bounded to the frozen parent above.

The immutable current candidate declares parent fourteen capabilities plus
`uc_recognition_summaries_v1`. Its rollback inventory includes retained summary
content, disclosed/withdrawn consent metadata, recognition proof metadata and all
active summary jobs, including orphan jobs. Prior known M1 twelve and Member /
History fourteen operator targets remain recognized; lack of the new capability
requires zero new owned rows/jobs. Downgrade never erases content as a side effect.
