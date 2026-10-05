# ADR-0092: Compose full UC through exact owner contracts

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Architecture, Core, Security
- **Reviewers:** Architecture, Security, Release and Quality
- **Related decisions:** ADR-0027, ADR-0035, ADR-0045, ADR-0075, ADR-0085,
  ADR-0087, ADR-0088, ADR-0089, ADR-0090, ADR-0091

## Context

The full UC roadmap introduces scheduled meetings, durable telephone controls
and routing, consented meeting artifacts, enterprise identity, persistent
availability, and richer conversation content. These workflows must remain
inside the existing modular monolith with one owner per canonical table and
persistence-neutral public interfaces. Provider configuration and synthetic
protocol checks do not establish carrier, identity-provider, production-media,
physical-device, or protected-release qualification.

## Decision

1. Calls owns meetings, occurrences, artifacts, consent receipts, normalized
   artifact provider-event receipts, and transcript segments. Telephony owns
   advanced commands, routes, mailboxes, and voicemail. IdentityAccess owns MFA
   factors, authentication challenges, federated identities, and SCIM directory
   resources. Collaboration owns board assets and durable versions;
   ConversationContent owns saved messages and synchronized drafts.
2. Public operation growth is frozen in the complete facade inventory. Every
   adapter-visible operation uses explicit persistence-neutral specs and DTOs.
   New schema-backed records remain owner-internal; they cannot become public
   contracts. Owner-internal console helpers do not acquire browser routes.
3. Calls dispatches recording, object storage, and transcription through exact
   consumer-owned configured technical interfaces. These interfaces use
   separate behaviour modules, bounded typed requests and receipts, explicit
   errors, and explicit adapter identity. Workers and controllers use the
   Calls facade. Recording remains disabled until tenant policy, provider
   configuration, current participant consent, and admission fences allow it.
4. Calls consumes legal-hold and retention policy through its transaction-bound
   ArtifactProtectionPort. Governance implements that contract while retaining
   sole ownership of its tables and tenant serialization lock. The sole
   operation is `protection/3`; it returns the Calls-owned ArtifactProtection
   projection. Calls does not import Governance schemas or issue foreign SQL.
   MeetingErasure reuses this exact Calls-owned projection for held-scope-safe
   authored-history cleanup; its sole additional runtime caller retains the
   transaction and Governance tenant serialization fence.
   Telephony uses the corresponding `protection/2` contract for voicemail.
   Both projections include a capture-blocked decision for pending governed
   erasure, without exposing Governance's deletion-request records.
5. Collaboration consumes approved raster attachments through its exact
   BoardAssetPort. ConversationContent implements `claim/3` and `read/4` in the
   dedicated Messaging.BoardAssets facade. The adapter checks live conversation
   admission, source-message state, clean scan state, object-version identity,
   and bounded size. This preserves the prohibition on Attachments importing
   Messaging. Restoring a board version cannot resurrect an erased asset.
   Library and the schema-only AssetValidation leaf are the exact port callers;
   Commands and Library share that validation without a reverse dependency.
6. Telephony dispatches controls and voicemail through explicit owner contracts.
   Native LiveKit SIP DTMF and REFER capabilities remain distinct from optional
   Asterisk ARI bridge, hold, consultation, routing, and recording capabilities.
   Configuration and qualification flags default closed. Durable states report
   submitted or pending work until verified provider convergence establishes a
   stronger result; adapter acceptance does not prove carrier acknowledgement.
   The exact `execute_control/1` technical operation is invoked by
   Telephony.Controls after fresh tenant, identity, device, session and call
   ownership checks. Telephony.Routing invokes it for internal queue-waiting
   work after current tenant, route, membership and call admission checks.
   Owner locks remain held through each bounded provider effect, preventing a
   previously claimed job from bypassing current revocation or route admission.
   Lifecycle uses exact `bound_call_status/1` and `cleanup_call/1` operations with
   the existing typed ProviderCommand. Terminal cleanup requires authenticated
   absence of owned PBX channels/bridges and LiveKit room cleanup; uncertainty
   leaves the receipt pending. Legitimate transferred handoffs remain until
   verified remote end or fixed call expiry. Pending caller-only voicemail
   similarly survives intentional app departure while the exact external call
   is observed; verified caller end, capture completion or its fixed deadline
   permits termination. Explicit transaction and remaining
   effect budgets prevent cleanup from outliving the owner lock. Cleanup uses
   retained credentials when new admissions are disabled and never redials.
7. Persistent availability is an IdentityAccess projection consumed by
   notification and telephone owners. In-app history remains available while
   external delivery and ringing obey the applicable DND policy. Scheduling
   events use the existing transactional outbox and active-member notification
   fanout, without a Calls-to-Notifications compile dependency.
   Sensitive identity effects retain current tenant, user, device and session
   authority through factor proof and mutation. OIDC link/step-up rechecks this
   authority after provider work. SCIM writers retain current service-account,
   user and device authority and revalidate credential generation, expiry and
   scope after waits. These owner-internal locks and absolute effect deadlines
   add no facade, schema borrowing or configured interface permission.
   Conversation creation preserves current active human and service member
   semantics through the exact transactional Accounts collaboration
   `lock_active_directory_users/1`. Conversations.Commands is its sole
   consumer. The IdentityAccess-owned DirectoryUsersLockQuery carries the exact
   tenant, selected user IDs and absolute monotonic deadline; the returned
   LockedDirectoryUser projections contain only ID, tenant and human/service
   type. IdentityAccess retains active tenant and canonically sorted current
   user locks before the caller retains its current actor device/session
   authority. Quota or identity waits cannot authorize stale actors or members.
   The existing human-only directory lock remains separate and unchanged.
   Guest lifecycle composition retains exact tenant-bound identity parents
   through `Accounts.lock_guest_identity_parents/1`, using the IdentityAccess
   GuestIdentityParentsLockQuery and GuestIdentityParentsLockReceipt. This is a
   transaction-only parent lock, not an access grant. Canonically sorted Users
   precede Session and room/link/membership resources. Live admissions retain
   the active tenant first; expired or inactive cleanup preserves its existing
   eligibility without acquiring a later tenant lock beneath retained Users.
   Fresh guest/session expiry and exact room binding remain owner obligations.
   Ordinary content writers use the exact transactional
   `Accounts.lock_content_write_grant/2` collaboration with the existing
   AccessGrant projection and an absolute monotonic deadline. Its `/1`
   convenience delegates to the same owner authority. MessageCommands,
   PersonalContent and Whiteboards.Commands retain quota, active tenant,
   actor User, Device and Session authority before conversation/resources;
   current expiry is checked after those waits. Collaboration therefore adds
   the direct compiled IdentityAccess edge for Whiteboards.Commands to consume
   the declared Accounts facade grant and current-grant operations; identity
   schemas and implementation modules remain unavailable across the boundary.
   Service messages retain the
   corresponding exact `ServiceAccounts.authorize_service/3` scope and
   deadline contract without reversing service-account/user lock order.
8. The manifest carries one exact, sorted ADR-backed semantic transition bound
   to the canonical manifest from protected main commit
   `23896227a80055eb2b393b8f7260fd3244942481`. The transition permits only the
   observed table, contract, facade, operation-inventory, event, and precise
   interface additions. It is removed after the same composition reaches the
   protected branch; it cannot authorize another delta.
9. Governance prepares media erasure through the exact Calls and Telephony
   `prepare_governance_erasure/3` facade collaborations on its transaction.
   Calls returns ArtifactErasurePlan and Telephony returns VoicemailErasurePlan;
   these receipts contain only pending counts. The corresponding
   `governance_erasure_pending?/3` queries return booleans. Governance cannot
   mark a deletion complete while either owner reports pending provider or
   storage work. Markers immediately deny retrieval and prevent new capture;
   durable stop, terminal provider convergence, full object-key version purge
   and derived transcript removal precede completion. Reconciliation also
   revisits prior completed requests that lack current media erasure evidence.
   These operations grant no foreign schema or Repo access.
   Governed user erasure retains sorted identity-write fences and drains current
   Sessions/Devices before selecting final content. The exact transaction-only
   `Accounts.drain_user_for_governance/1` consumes GovernanceErasureCommand
   and returns GovernanceErasureReceipt containing only user and revoked
   session IDs. GovernanceErasure is the sole additional caller of the existing
   IdentityAccess CallLifecyclePort; its existing user-access-revocation
   command closes room and telephone lifecycles on the same transaction.
   The cached revocation receipt is reused for membership and completion.
   `Accounts.finalize_user_for_governance_erasure/1` consumes the same command
   only after lower owner effects and verifies the drained identity before
   keyed anonymization. It neither revokes Sessions again nor invokes another
   lower-resource call contribution. Strong
   unique-key anonymization follows lower call and content effects, so a prior
   admitted reader can finish its foreign-key references without a reverse
   lock order. Ordinary content writers retain current actor authority before
   conversation and private resource waits; current expiry is checked again
   after waits. Conversation erasure retains its archive fence, and the content
   owner locks exact Message rows before derived copies or revisions are
   scanned through `Messaging.lock_for_erasure/3`, returning its existing
   GovernanceImpact projection, including tombstoned parents. The sole
   consumer is Governance.DeletionWorkflow. Governance's public message-delete
   entry retains its policy tenant lock before actor and message resources.
   Held or pending work rolls back the complete caller transaction.
   Historical requests without current writer-fence proof require fenced
   reconciliation rather than relying on older completion evidence. Only
   fenced completion establishes `writer_fence_erasure_version: 1`.
   A missed physical attachment requeues a historical completed request with
   an exact version transition to in-progress, preserves historical evidence
   and leaves writer proof absent. The actual registered deletion worker must
   remove the fresh object scope and supply its current count before completion;
   local repair cannot certify physical deletion or report that request repaired.
   Authored meeting history is an additional Calls-owned erasure obligation.
   Cancelled status and ended rooms do not prove title/host/time erasure.
   Governance must prepare and await the owner proof for affected user and
   conversation scopes. The owner holds the existing governed protection
   fence, scrubs readable fields and suppresses calendar/get/ICS/search results;
   holds and unresolved cleanup prevent completion. Retained opaque retry IDs
   and versions do not justify retaining erased authored fields.
   The exact facade collaborations are `prepare_meeting_governance_erasure/3`,
   returning MeetingErasurePlan with nonnegative pending/scrubbed meeting
   counts, and `meeting_governance_erasure_pending?/3`, returning a boolean.
   Governance.DeletionWorkflow is their consumer. Private author lineage and
   erasure proof remain in Calls-owned meetings; the public MeetingView stays
   unchanged because erased rows are excluded. Legacy author reconstruction
   uses Audit.list projections and verifies version attribution without
   importing Audit persistence. Unknown lineage cannot establish completion.
10. Release rollback compatibility consumes content-free nonnegative hazard
    counts through the owning Accounts, ServiceAccounts, Calls, Telephony,
    ConversationContent and Collaboration facades. Each owner queries only its
    canonical records; Release does not import their schemas or issue their
    SQL. Used enterprise authentication/SCIM, retained artifact/voicemail,
    advanced telephone, scheduling and rich-content erasure state requires the
    corresponding target capability or a quiesced zero-hazard proof. Unknown
    or unavailable evidence refuses rollback. An older binary cannot receive
    the new capability declaration from the current host template: immutable
    target-image provenance and the actual target capability set must survive
    rollback rendering. Schema retention alone does not establish enforcement.
    Scheduled-meeting hazards include retained readable history without
    verified owner erasure, even when the series is cancelled and rooms ended.

The release-only collaboration caller is
`CommsCore.Release.RollbackCompatibility`. Each following operation returns
`non_neg_integer()` and has no browser route or mutation:

| Owning facade operation | Required target capability for retained hazards |
| --- | --- |
| `Accounts.rollback_enterprise_identity_hazard_count/0` | `enterprise_identity_v1` |
| `ServiceAccounts.rollback_scim_credential_hazard_count/0` | `enterprise_identity_v1` |
| `AudioCalls.rollback_artifact_hazard_count/0` | `uc_artifact_lifecycle_v1` |
| `AudioCalls.rollback_meeting_hazard_count/0` | `scheduled_meeting_lifecycle_v1` |
| `Telephony.rollback_voicemail_hazard_count/0` | `uc_voicemail_lifecycle_v1` |
| `Telephony.rollback_control_hazard_count/0` | `uc_advanced_telephony_v1` |
| `Messaging.rollback_rich_content_hazard_count/0` | `rich_content_erasure_v1` |
| `Whiteboards.rollback_rich_content_hazard_count/0` | `rich_content_erasure_v1` |

All facades are the existing `CommsCore` modules. Pending artifact, voicemail,
control/routing and reminder jobs also contribute through the existing release
job-count interface. The empty periodic artifact reconciler does not create a
retained-media hazard by itself.

## Consequences

The deployment units, authoritative database, strict enforcement, empty finding
baseline, namespace prohibitions, historical migration hashes, and public
persistence-neutrality remain intact. New migrations must each mutate one
canonical owner and use statically attributable targets. Technical dispatch
uses exact callable operations rather than dynamic application of public
interfaces. Runtime dependency inversion is explicit and does not grant broad
foreign-context access.

Implementation completion is reported separately from provider qualification
and protected production promotion. No enabled control, stored consent, local
provider fixture, or mocked browser journey substitutes for those gates.

## Validation

- Frozen facade exports and adapter/collaboration classifications match source.
- Public contracts and exact interface operations have non-generic typespecs.
- Runtime collaboration callers, bindings, operations, transactions, and graph
  semantics match source exactly; cross-owner Repo access remains rejected.
- Every new migration maps to declared tables and one owner, without new
  historical exceptions or unresolved targets.
- Erasure-marker and restore-lineage migrations modify their existing owner's
  tables. Restored whiteboard content retains original author lineage so a
  later governed user erasure cannot leave text in restored operations/caches.
- Revocation/effect races and media erasure barriers require application and
  provider qualification independently of static architecture validation.
- Governed meeting-history cleanup must deny retrieval and calendar export,
  retain held subjects, cancel stale admission/reminders and supply owner proof
  before completion. Retained cancelled content must block an incompatible
  rollback; cancelled status alone is insufficient evidence.
- Rollback hazard projections remain content-free integers on owner facades;
  target capability provenance and incompatible retained-state refusal require
  release and recovery tests against the same immutable candidate.
- Immutable-base manifest comparison accepts exactly the declared change tokens.
- Architecture validation retains zero findings with the unchanged empty
  baseline; provider, privacy, revocation, tenancy, and recovery tests qualify
  behaviour independently of this manifest transition.

## Landed transition

PR #236 merged this owner composition normally at protected main
`4dd01c79f3fe53a71bcb7219ef4bd3644a2fe82e` on 2026-10-05. The exact
`compose-full-uc-owner-contracts` transition has therefore fulfilled its explicit
removal condition and is retired from the active manifest. Its 93 approved
semantic additions remain recorded in that merged Git revision and this ADR.
All owner declarations, public operations, strict enforcement and the empty
violation baseline remain unchanged. Future permission growth still requires its
own exact immutable-base transition and architecture review.
