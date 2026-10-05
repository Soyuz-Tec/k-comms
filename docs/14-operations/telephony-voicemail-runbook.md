# Voicemail capture and retrieval

Voicemail is disabled until the PBX control plane and encrypted, versioned S3
storage have been qualified. Provider credentials and PBX file paths stay on the
server. A configured endpoint alone is not proof of working recording or playback.

Configure the existing Asterisk ARI adapter, then bind these runtime adapters:

| Setting | Implementation |
| --- | --- |
| `:comms_core, :voicemail_provider_adapter` | `CommsIntegrations.Telephony.VoicemailARI` |
| `:comms_core, :voicemail_storage_adapter` | `CommsIntegrations.Telephony.VoicemailS3` |
| `:comms_core, :voicemail_protection_adapter` | `CommsCore.Governance.VoicemailProtection` |
| `RuntimePorts :telephony_voicemail` | `CommsWorkers.TelephonyVoicemailWorker` |

`telephony_voicemail_storage_qualified` defaults to `false`. Set it only after
qualifying bucket versioning, server-side encryption, SHA-256 verification,
short-lived public HTTPS playback, exact-key version purge, restore and operator
access controls. The existing `telephony_pbx_qualified` gate must also pass.

Before enabling a mailbox, install an approved recording notice as a PBX sound
asset. An administrator with recent step-up selects the active human mailbox
owner, a notice such as `sound:custom/k-comms-recording-notice`, and 1–90 retention
days. A longer active workspace retention policy applies at capture time. This
setting does not purchase a number, install the sound asset, or enable a carrier.

Recording is reserved durably before any media effect. Its name is derived from
the server-owned call UUID. The existing qualified ARI control checks the exact
call, tenant, room and participant binding, plays the notice before capture and
limits recording to 120 seconds. The voicemail worker polls authenticated ARI
stored-recording metadata and bounded WAV bytes. A real stored recording with the
exact expected name and format is required; synthetic events cannot make a
message available.

The worker fetches bounded provider media and calls the Telephony storage
operation. The mailbox owner retains the voicemail row lock through conditional
storage ingestion and database completion, so a previously claimed worker
cannot upload after a completed purge. Storage uses the tenant-specific object
key with `If-None-Match: *`, SHA-256 and AES256 server-side encryption. Retrying an
uncertain upload verifies the same object instead of creating another version.
A verified size, checksum, encryption receipt, ETag and immutable version must
exist before the database marks a message available. Playback uses that exact
version even if an operator later overwrites the key.

The assigned mailbox owner and current active shared-line members can retrieve
messages. Tenant isolation, current persisted sessions and current shared-line
membership are checked for every list, playback, read and delete request. Read
state belongs to the individual member. Removed shared-line members and revoked
sessions cannot obtain another playback URL. A URL already issued remains valid
until its short expiration, normally 120 seconds; S3 does not provide immediate
per-URL session revocation. Do not increase that window without a reviewed change.

After verified ingestion the worker deletes the PBX source promptly, unless a
legal hold requires preservation. The PBX recording volume must therefore use
encryption at rest, restricted operator access and bounded storage before
qualification. This source-volume policy is an external deployment requirement;
the S3 encryption receipt does not prove PBX disk protection.

Deletion first removes message playback access and queues durable erasure.
Provider source deletion and all versions of the exact approved object key are
retried idempotently. The message becomes deleted only when both effects succeed.
A governance tenant lock spans legal-hold evaluation and external erasure, so a
new hold cannot race an already evaluated deletion. Active tenant or mailbox-user
holds preserve both source and approved storage; reconciliation checks again
daily while held. Unknown governance state fails closed.

Governed user/conversation erasure prepares the voicemail plan in the deletion
request's transaction. It checks every affected mailbox/call-user hold before
marking messages, removes retrieval immediately and queues durable purge.
Pending relevant governance requests block new reservation, recording and
ingestion through the protection projection. The request cannot complete until
Telephony confirms no affected voicemail remains pending physical erasure; the
Calls recording barrier must also clear. A provider timeout, active recording,
missing purge receipt or legal hold keeps the request pending. Preserve the
jobs and retry through reconciliation instead of manually declaring completion.
The barrier includes authenticated absence of both live and stored ARI
recordings, all exact-key S3 versions and physical removal of per-user read rows.
Protected subjects include the captured mailbox/call users and current call
assignment; moving a mailbox or call does not remove a prior subject's hold.

Historical completed governance requests without current media-erasure evidence
are revisited by the completed-request reconciler. Qualification must prove a
provider/storage failure and a held message do not receive completion evidence,
then prove recovery and authorized hold release remove the exact PBX source and
all approved object versions before evidence is recorded. Legacy messages
already labeled deleted without verified erasure are re-proved against the
providers instead of treating the old status as physical-purge evidence.

An authenticated provider response confirming that no stored recording exists
after the 180-second recording deadline queues protected cleanup. Provider
unavailability retries reconciliation; elapsed time alone never discards a
recording that might exist on an unavailable PBX.
Mailbox capacity is 500 live messages; recording/media bounds are 120 seconds and
8 MiB. Operators should monitor Oban retries, pending/deleting age, provider source
cleanup failures and actual bucket usage. Do not remove failed deletion jobs or
declare erasure complete while an object/provider receipt is missing.

Worker effects use an explicit 150-second transaction. Before contacting a
provider, the mailbox owner requires enough time after lock acquisition for
the effect and a 10-second commit margin: 30 seconds for conditional S3
ingestion, 20 seconds for PBX source deletion, and 80 seconds for combined
provider/all-version storage purge. The shared S3 purge has a fixed 60-second
aggregate limit. Exhausted budgets fail before HTTP; timeout or partial purge
retains the durable retry/barrier. Qualify database/worker capacity, lock
contention, cancellation and hold/erasure latency under these maximum bounds.

Rollback requires `uc_voicemail_lifecycle_v1` while voicemail or its provider,
storage/read-state erasure and pending jobs remain. Unfinished advanced calls or
control/routing work also require `uc_advanced_telephony_v1`. The current
release's quiesced owner-count/job preflight refuses incompatible targets;
retaining the schema alone cannot retain enforcement. Keep the approved target's
actual immutable capability declaration and use a compatible bridge or roll
forward when blocked. Do not discard held media or pending purge work.

Qualification must include a real inbound unanswered call, caller notice timing,
complete audio capture, stable playback, revoked/shared-line membership checks,
provider restart during recording, uncertain upload recovery, legal hold before
erase, held-source disk protection, upload/purge concurrency, governed capture
fencing, request completion barriers and complete erasure after hold release.
Local protocol and MinIO tests validate implementation and bounds; they do not
prove carrier routing, physical audio, production retention or live PBX policy.
