# Full UC gap closure and qualification ledger

Date: 2026-10-05

Target: full unified communications, including telephony.

The first delivery increment implements scheduled meetings, advanced phone controls,
voicemail, consented meeting artifacts, enterprise identity and availability, and
rich content. Local backend qualification passed all 1,273 tests with 80.35%
coverage. Final native runtime qualification passed on an unchanged source and helper
snapshot. [PR #236](https://github.com/Soyuz-Tec/k-comms/pull/236) merged normally
at main `4dd01c79f3fe53a71bcb7219ef4bd3644a2fe82e`; exact-main CI passed on its
second attempt. The minimal future-authentication fixture correction and retirement
of the fulfilled architecture transition merged in
[PR #237](https://github.com/Soyuz-Tec/k-comms/pull/237), at
`734c9e1daf48f2280789a13f977d220f250b9890`.
The attested first-increment image is
`ghcr.io/soyuz-tec/k-comms@sha256:6f40740d2bdbcab0e64c610bc24b182dc574a5b60533092e97bd9e01647f910e`.
Staging upload stopped before remote deployment. The user confirmed staging VM
101 is intentionally offline, so manual retries are paused. Staging and production
acceptance remain pending.
Real carrier, IdP, PBX, capture and storage qualification are separate from local
synthetic fixtures and are not claimed complete.

The earlier interface reliability increment was merged in
[PR #231](https://github.com/Soyuz-Tec/k-comms/pull/231), at main
`23896227a80055eb2b393b8f7260fd3244942481`. Its staging upload failed before remote
deployment. It provides no staging or production receipt for this increment.

## Implementation and external acceptance

| Milestone | Current source implementation | Provider and acceptance gates |
|---|---|---|
| First phone line | Existing tenant line assignment and LiveKit SIP provisioning/call APIs remain the carrier boundary; provider/setup states distinguish configuration, assignment and qualification | No carrier account, DID or number was supplied. Acquire the intended line, configure restricted trunks/dispatch, and prove inbound/outbound calls, caller ID, actual two-way audio, ownership and outage/recovery under ADR-0085. No number has been acquired or carrier enabled. |
| Meetings lifecycle | Calls-owned schedules and occurrences; bounded daily/weekly recurrence; IANA local-time validation with explicit DST ambiguity/gap rejection; authenticated ICS export; create/edit/cancel/calendar/start UI; versioned host and guest policy; durable current-version reminders through active-member notification fanout; held-scope-safe author-lineage erasure, retrieval denial and owner completion proof for authored history | Local schedule/recurrence, host/editor erasure, private retrieval, held/unknown-lineage and reminder cases passed. Qualify actual delivery and tenant timezone/policy acceptance. Google/Microsoft synchronization remains a separate source increment; ICS export does not claim provider synchronization. |
| Advanced phone controls | Device-owner-bound durable commands; current identity, device, session and call locks retained through bounded provider execution; browser SDK DTMF authorization/completion; LiveKit SIP blind REFER transfer; optional Asterisk ARI hold/resume, consultation and completion/cancellation; tenant routes for queues/shared lines; exclusive answer ownership, DND-aware routing, retries and provider-event convergence; exact owned-channel/bridge cleanup and fixed-bound handoff monitoring | Local command, current-authority, lock-budget, queue and cleanup cases passed. Qualify actual DTMF, hold/MOH, REFER and consultation, carrier/PBX channel binding, audible media, remote handoff and recovery. Submission is distinct from verified convergence; PBX and destination-prefix qualification gates default closed. |
| Voicemail | Durable reservation before notice/capture; pending caller-only capture preserved through intentional app departure and monitored until verified caller end/completion/deadline; authenticated ARI stored-recording retrieval; bounded WAV ingestion into encrypted, checksum-verified, version-pinned storage under the mailbox row lock; authorized list/play/read/delete UI; per-user read state; shared-line access; legal-hold/retention-aware purge; governed capture fencing and provider/storage completion barrier | Local capture/storage/current-authority/erasure cases passed, including local versioned encrypted S3-compatible storage. Install and approve actual notice audio; prove notice-before-capture, signed PBX events, caller-only recording, encrypted PBX disk, physical provider erasure, playback and recovery. Provider/storage qualification defaults closed; already issued playback URLs retain only their bounded expiry. |
| Meeting artifacts | Explicit request and consent by every current admitted session; host start/stop; admission fencing and durable stop on consent/access withdrawal; LiveKit Egress reconciliation and authenticated callbacks; verified version-pinned playback; post-meeting retrieval; legal-hold and retention protection; governed capture fencing and terminal-provider/full-version/transcript erasure barrier; explicit Whisper-compatible transcription; local opt-in captions from actual LiveKit transcription events | Local consent, admission, callback, storage and governed-erasure cases passed. Approve jurisdiction/residency/retention and qualify real multiparty Egress/transcription/storage, capture withdrawal and physical deletion. Enablement/privacy/provider gates default closed. Captions consume actual arriving provider events; they do not start recognition. Direct audio and recording enablement are mutually exclusive. |
| Enterprise identity and availability | Actual TOTP sign-in challenge and recovery credentials; encrypted factor/challenge material and replay/rate limits; OIDC Authorization Code/PKCE/state/nonce/JWKS validation with explicit immutable subject linking; tenant-scoped SCIM Users/Groups lifecycle and last-owner protection; bounded avatar/timezone profiles; persisted availability and weekly DND enforced for delivery/ringing; attributed console recovery command | Local password/MFA/recovery, signature-negative OIDC, SCIM, revocation and DND cases passed. Configure and qualify an actual IdP/SCIM assurance/mapping policy; approve operator custody/alerts and recovery drills. The inherited limited-human privileged-role/eligible-owner repair remains the next increment and blocks production promotion. OIDC is disabled by default; SCIM groups do not grant application roles. |
| Rich content | Board gallery/title management, approved raster assets, bounded named checkpoints, version-safe restoration and export; original-author lineage retained through nested restores for governed erasure; saved message references; versioned main/thread drafts with conflict recovery and expiry cleanup; escaped rich formatting and approved attachment-only replies; authorized unified retrieval across messages/files/boards/meetings/artifacts with facets, ranking and scoped cursors | Local current-admission, original-author lineage/erasure, saved/draft CAS, board restoration, authorized search and relevant browser cases passed. Ranking covers a bounded candidate union. Physical pen/touch, manual accessibility, production load/retention and actual support recovery remain open; optional drive functions require a product decision. |
| UC launch | Existing immutable release, backup/restore/rollback, readiness and operations mechanisms remain the delivery path; new features have operator runbooks and closed enablement defaults | Complete physical desktop/iOS/Android, background ringing limits, assistive-technology evaluation, load/recovery, provider outage exercises, on-call ownership and real backup/restore/rollback evidence. Qualify protected staging and independently approve production promotion of the same attested digest. No new live launch evidence is claimed. |

Scheduled meetings support at most 52 occurrences, intervals of 1–4 days/weeks
and a 366-day horizon. Board libraries admit 100 checkpoints and 100 approved
image references per board. Saved items and draft scopes are limited to 500 per
user. Expired draft bodies are hidden after 30 days and scrubbed in bounded hourly
batches. Unified search ranks a bounded authorized source union; it is not an
exhaustive global index. The interface discloses limits where they affect a choice.

## Current local qualification

| Gate | Result and scope |
|---|---|
| Backend formatting, compile and forward migrations | Passed with warnings treated as errors; all 11 additive migrations applied on a new synthetic database |
| Full backend coverage | 1,273 passed: observability 5, core 805, shared support 1, integrations 185, workers 72 and web 205; 80.35% coverage; existing coverage policy unchanged |
| Core dependency cycles | Both compile-connected and all-edge xref commands report exactly `No cycles found` |
| Architecture | Strict original-main manifest/report validation: zero tracked violations, 49 compiled and 10 runtime edges; all 196 validator regression cases passed; empty baseline unchanged |
| Contracts | JSON Schema/OpenAPI/AsyncAPI mirror validation passed; all 67 contract regression tests passed |
| Documentation | All 294 document checks passed after the evidence ledger refresh |
| Security and release | Sobelow medium gate, Hex audit, production warnings-as-errors compilation and native release passed; production npm audit reports zero vulnerabilities |
| Web application | 1,133 unit tests across 164 files plus 5 asset checks passed before the final board layout correction; final correction passed 61 relevant cases, lint, type checks and production/PWA build with all 6 budgets |
| Browser journeys | Composite coverage of 685 distinct stock-project cases: 461 passed, 224 existing project skips, zero unresolved failures; affected cases were rerun after corrections; this is not a single full run of the final source |
| Real native runtime | 70 direct HTTP checks plus 24 actual governed-erasure HTTP requests, 296 browser API responses, bidirectional Phoenix WebSocket checks and 14 desktop/mobile captures passed without API mocks; all 11 additive migrations applied, disposable empty-state down/up preserved the original tables, retained-state legacy binary rollback and erased-meeting migration reversal correctly refused |
| Independent delivery review | 480 source delivery paths screened; no runtime exports, private environment files, binaries, symlinks or nonfixture credentials found; protected instructions and ownership/protection files unchanged |
| Protected delivery | No current-task merge, image, staging or production receipt yet; required CI must run against the final candidate |

The complete backend run binds a new synthetic database rather than resetting
an existing one. Earlier failed test/helper attempts are retained separately.
Actual concurrency cases verify PostgreSQL blockers and live authority, rather
than treating a delay as proof of a race. A temporary OTP missing-library warning
contaminated an exact xref output guard after all tests had passed. A locally
extracted, SHA256-verified official Debian libsctp1 package resolved that native
runtime dependency; both exact xref guards and the remaining release gates then
passed. No cycle or warning gate was relaxed.

The runtime source manifest before the final contract and evidence updates is
`23672d089d31d1eba452af9f6d605802b12ff9050998d912e9f70be15b6ba407`.
Source and qualification-helper bytes are fenced before and after the run.
The only later delivery changes are the missing versioned Conversation/member
request schemas, their exact documentation mirror, local-reference validation
and its regressions, and this evidence ledger. They passed canonical contract
validation and all 67 regression cases. No executable application code changed.
Final commit binding and GitHub CI remain required.

## Authority, privacy and rollback

Sensitive writes retain canonical current authority through quota, Tenant, sorted
User, Device/Session and lower-resource waits, with one absolute time budget.
Identity User fences use `FOR NO KEY UPDATE`, permitting admitted reader foreign
key checks while excluding concurrent lifecycle writers. Privileged actions
repeat current recent-proof checks immediately before their effect or commit.
Guest and conversation-only communication retain their scoped admission.

Governed deletion drains identity access before selecting final content, archives
conversation targets, locks exact Message parents, then removes revisions,
reactions, derived copies and authorized personal/board content. Unique identity
key anonymization occurs last. Current completion records
`writer_fence_erasure_version: 1`; historical requests missing that proof rerun the
fenced scope. Missed attachments return the request to the actual worker rather
than creating a false completion marker. Holds, unknown meeting author lineage,
active media, failed provider termination or incomplete object-version removal
prevent completion. Owner-reported artifact, voicemail and meeting-history proof
is required. Local adapter evidence does not establish physical provider erasure.

Rollback reads capability labels from the actual selected target image. Missing
capabilities require quiesced writers and zero corresponding owner-reported
retained-state/job hazards; malformed capability declarations fail closed.
Periodic empty cron jobs do not count as active demand. Migration refusal and
safe empty-database reversal are different exercises: reversing disposable empty
state does not qualify a populated production rollback. Issued media playback
URLs remain usable only for their bounded expiry; previously downloaded content
cannot be recalled.

A separately identified inherited limitation allows legacy conversation-only
humans with privileged role values to be considered by administrative authority
or owner-preservation checks. The next increment implements the workspace-scope
and eligible-human-owner repair. **Production promotion must wait for its
integration and qualification.** The first increment does not claim this wider
role-policy repair is already included.

## Remaining source increments

The current implementation and executed-test status is recorded in the
[remaining full-UC roadmap](full-uc-remaining-roadmap.md). The table below preserves
the original increment scope; its early source statuses are superseded by that
dated evidence snapshot.

| Increment | Current state | Required completion |
|---|---|---|
| Synchronized setup and contacts/groups | Isolated owner-backed source and interface implemented | Rebase onto this candidate, integrate private member erasure and rollback hazards, qualify current-identity/CAS/privacy flows |
| Role guidance and workspace authority | Isolated source implemented, including shared actual role policy and eligible-owner correction | Integrate SCIM/governed-erasure eligible-owner checks and qualify real mutation/lock-wait negatives |
| Usage reports | Isolated source and UI implemented | Qualify six owner-local retained projections, current-window disclosure, step-up, CSV and approved-origin receipts |
| Chronological deletion history | Isolated source and UI implemented | Integrate dedicated signing key, bounded immutable membership snapshots and purge demand/rollback hazards; qualify pagination/export/privacy |
| Verified workspace discovery | Source and UI in progress | Qualify exact-domain DNS proof, bounded verified leases, CAS, current authority, anonymous discovery privacy and governed cleanup |
| Google/Microsoft calendar synchronization | Source in progress | Qualify fixed delegated OAuth scopes, external-account binding, hosted-occurrence mapping, uncertainty/conflicts and managed-event erasure; configure actual providers |
| IVR/contact-center extensions | Source in progress | Qualify signed caller-only DTMF/playback, bounded immutable menus, route/current-agent state, uncertainty recovery and lifecycle cleanup; install approved PBX prompts and test real lines |
| Native iOS/Android | Source in progress | Compile and test platform clients, qualify secure credentials/media/CallKit/CoreTelecom, integrate native push owner contracts and certify physical/background behavior |
| Shared documents, recognition/summaries, federation, private-room E2EE and desktop packages | Remaining source/protocol work | Implement and independently review explicit owner, consent, trust/key, recovery and incompatible-feature contracts; retain closed defaults until accepted |

The historical [36-feature portfolio](feature-progress-matrix.md) is a dated
production snapshot. Its totals and status categories are not updated from
unreleased source or synthetic evidence. Broader load, manual accessibility,
physical devices, multi-region recovery, approved policy/provider configuration,
on-call ownership and actual backup/restore/rollback evidence remain open.
Optional drive and an application catalog remain product decisions.

The member/administration increment has been rebased onto the qualified first
source and is undergoing qualification. Its focused backend correction run
passed29 cases, including actual retained-state rollback and privacy/authority
checks. Its frontend broad run passed1190 of1193 cases; all three affected files
then passed37 cases after preserving the current step-up signature and bounded
CSV download behavior. Lint, strict types, five asset regressions, build and six
published asset budgets passed. These are complementary receipts, not one final
complete-suite/runtime receipt. API validation covers14 JSON schemas and the
current nine operations, with78 contract regressions plus final affected cases.
All196 architecture regressions passed; the empty baseline is unchanged.

Native WebSocket header transport now uses the same current one-use ticket
owner, rejects ambiguous sources before consuming any ticket, and preserves the
browser query transport. Seven real socket/session cases passed with explicit
exit0. Native client compilation, background push, physical-device acceptance,
full member backend/browser/runtime qualification and protected release remain
pending. No real provider was enabled.

History signing now compares actual loaded file-backed provider credentials and
decoded identity keyrings with its dedicated key. A network-isolated pinned Elixir
container exercised all six supported file-secret formats: every reuse was refused,
every independent control was accepted, and absent history signing stayed optional.
The same actual configuration qualification is now an explicit backend CI gate.
Authenticated denial responses also carry `no-store` and `no-cache`, including
missing, invalid and revoked credentials before history snapshot capture. All 16
affected configuration and HTTP tests passed; this does not replace full final
backend and real-runtime qualification.

## Architecture and runbooks

- [ADR-0087](../02-architecture/adr/0087-add-durable-scheduled-meetings.md) and
  [meetings](../14-operations/meetings.md).
- [ADR-0088](../02-architecture/adr/0088-add-durable-advanced-telephony-controls.md),
  [advanced phone qualification](../14-operations/advanced-telephony-qualification.md)
  and [voicemail](../14-operations/telephony-voicemail-runbook.md).
- [ADR-0089](../02-architecture/adr/0089-consent-gated-meeting-artifacts.md) and
  [artifact privacy/provider qualification](../14-operations/meeting-artifact-privacy-provider-runbook.md).
- [ADR-0090](../02-architecture/adr/0090-enterprise-identity-and-persistent-availability.md)
  and [identity recovery](../14-operations/identity-operator-recovery-runbook.md).
- [ADR-0091](../02-architecture/adr/0091-durable-rich-content-and-authorized-unified-retrieval.md)
  and [rich content](../14-operations/rich-content-runbook.md).
- [ADR-0092](../02-architecture/adr/0092-compose-full-uc-owner-contracts.md)
  records 93 exact semantic additions to the original protected main manifest.
  Its review transition was retired after PR #236 landed normally; the original
  decision and exact owner contracts remain retained.
  Public facade SHA256:
  `e909b4bc20949ef55baf083694e13e7f50fd5e8f1af1542532e55b1bac3c998e`.

The empty architecture baseline remains byte-identical. No historical migration,
namespace or generic callback exemption was added. Podman remains the default
container engine; native cloud tools are an environment fallback.

## Release and external gates

Follow the [development-to-production completion standard](../14-operations/development-to-production-completion-standard.md)
through protected review/CI, normal merge, exact-main CI, immutable publication
and attestation, protected staging, independent production approval, backups,
same-digest deployment and verification. The implementing agent cannot approve
its own production deployment. There is no current staging or production receipt for this increment.

No carrier account, DID, real IdP, capture/transcription provider or physical
acceptance was supplied or enabled. Their credentials and approvals must be
configured through the intended secure environment and owner process. Public
health on 2026-10-05 at 00:15 UTC returned HTTP530; the earlier staging SCP upload
failed before remote migrations or deployment. The failed receipt is preserved.
Real infrastructure recovery must pass before live launch is reported.
