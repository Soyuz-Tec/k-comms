# Remaining full-UC roadmap

Snapshot: 2026-10-05 UTC. Target: full unified communications including telephony.

The next software milestones can be implemented and tested with synthetic local
services. Live launch still requires provider, physical-device and infrastructure
acceptance. A draft implementation or authored test is not a completed release.

| Milestone | Available software work | Current evidence | Remaining acceptance |
|---|---|---|---|
| Member administration and history | Private setup, contacts/groups, eligible-owner role controls, six usage reports, CSV exports, immutable deletion history | [PR #238](https://github.com/Soyuz-Tec/k-comms/pull/238): 38 actual local HTTP/browser/socket/migration/erasure stages passed; current hosted backend/security/validation pass; browser CI running | Required checks/review, protected merge and same-digest deployment |
| Shared documents | Text editing, replay, presence, copies, export and governed author-lineage erasure | [PR #242](https://github.com/Soyuz-Tec/k-comms/pull/242): 43 client tests and nine owner/channel cases passed; three stronger identity-order cases passed; full current CI running | Real browser/realtime journeys, concurrency/load, accessibility and deployment |
| Workspace discovery | Exact domain claims, DNS proof, verified leases and private workspace hints | [PR #241](https://github.com/Soyuz-Tec/k-comms/pull/241): owner backend and validation passed on the preceding feature source; current parent integration running | Real DNS, discovery privacy journeys and deployment |
| Calendar synchronization | Delegated Google/Microsoft authorization, hosted-meeting mapping, conflict handling and managed-event erasure | [PR #243](https://github.com/Soyuz-Tec/k-comms/pull/243): actual warnings-as-errors compile and contract/architecture checks passed; current fixture and security-policy failures are being corrected | Real OAuth applications/accounts, provider uncertainty/erasure and deployment |
| IVR and contact-center routing | Bounded menus, signed caller-only DTMF, queue agent state and durable cleanup | [PR #240](https://github.com/Soyuz-Tec/k-comms/pull/240): owner backend and validation passed on the preceding feature source; current parent integration running | Approved prompts, real PBX/carrier lines, audible media and recovery |
| Phone administration | Inspect/adopt existing LiveKit SIP resources, assignment, one-use apply and read-only reconciliation | Source and release contracts implemented; actual application tests and current-session UI fixes running | Existing carrier/DID/trunk, actual provider effect and recovery; number purchase/porting is outside this increment |
| Native foreground clients | iOS/Android sign-in, conversations, calls, secure credentials and current admission | [PR #239](https://github.com/Soyuz-Tec/k-comms/pull/239): unsigned iOS build and 35 simulator tests passed; Android unsigned builds/lint and 48 JVM tests passed; all native bytes preserved in parent rebase | Physical media, interruption/network behavior, signing and store distribution |
| Desktop application | Sandboxed packaged client, secure vault, calling and current-authority controls | [PR #244](https://github.com/Soyuz-Tec/k-comms/pull/244): source checks passed; unsigned Linux/macOS/Windows packaging is being requalified after fixture corrections | OS/device media, signed packages, distribution and updates |
| Native background call wake | Encrypted registrations, opaque one-use hints, PushKit/CallKit and FCM/CoreTelecom | Source, protocol and release checks passed; new application/native tests are being executed | APNs/FCM credentials, real background/terminated-device delivery and platform limits |
| Recognition and quote summaries | Saved post-recording transcription, separately consented extractive quotes and governed lineage | [PR #245](https://github.com/Soyuz-Tec/k-comms/pull/245): real licensed waveform/MP4 inference, HTTP refusal, disconnect cleanup and full inference timeout passed; 12 owner and ten integration cases passed; additional retrieval-boundary tests running | Complete application/browser acceptance, pinned HTTPS service deployment, privacy and real capture/storage qualification |
| Federation | Explicit plaintext Matrix bridge, participant consent, trust policy and retained remote-cleanup obligations | Source implementation and strict owner/contracts checks in progress | Combined identity integration, real homeserver trust/abuse/residency and remote-cleanup acceptance |
| Private encrypted rooms | Maintained Matrix/Rust crypto, device verification, recovery and separate encrypted content mode | Source implementation in progress; no claim of executed crypto/browser acceptance | Actual SDK interoperability, multi-device/recovery and deployment; recipient keys/copies and all remote backup versions cannot currently be proved erased |

## Completion order

1. Finish member administration and shared documents, preserving current-session
   privacy and original-author erasure guarantees.
2. Qualify calendar, discovery, IVR and phone administration against their actual
   owner contracts, migrations and rollback inventories.
3. Finish native/desktop packages, background wake and recognition acceptance.
4. Integrate and qualify federation and private encrypted rooms, including their
   different trust, recovery and deletion limits.
5. Run combined architecture, regression, migration, retention, backup/restore,
   load, accessibility and release checks before live acceptance.

## External prerequisites

The user confirmed staging VM 101 is intentionally offline. Manual deployment
retries are paused. Protected staging qualification must resume when the intended
infrastructure is available; this snapshot provides no staging or production
acceptance receipt.

No carrier/DID, real identity/calendar account, APNs/FCM credentials, signing
identity or physical-device acceptance was supplied. Provider gates remain off.
Production requires an independent authorized reviewer and the same immutable
digest already qualified in staging, with the required backup and recovery proof.

Encrypted-room deletion stays pending when recipient-held keys/copies or complete
remote-backup cleanup cannot be proved. A local purge or an operator checkbox
does not authorize a complete-erasure claim. Live captions still depend on actual
arriving media-provider transcription events; saved recognition is not a live
caption producer.

The historical [36-feature portfolio](feature-progress-matrix.md) remains a dated
production snapshot. These unreleased implementations do not promote its totals.
