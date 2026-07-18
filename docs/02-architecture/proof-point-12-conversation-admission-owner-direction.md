# Proof Point 12: Conversation admission owner direction

Status: complete and verified on 2026-07-17.

This is the repository-effective twelfth proof point. It implements the
request-numbered Proof Point 10 without overwriting the existing Proof Point 10
and 11 records.

## Executive outcome

The selected relationship is:

```text
TenantAdministration -> Conversations
```

It was the smallest non-audio cut: one production source,
`apps/comms_core/lib/comms_core/admission_quotas.ex`, produced one undeclared
edge and two foreign-schema findings.

The relationship combined two concerns:

- a reverse, decision-bearing persistence read for conversation admission; and
- a cross-owner administrative usage read.

The decision-bearing reads now belong to Conversations. The usage response is
composed by the existing Operations read model from exact Ecto-free owner
queries. No runtime dispatch, shared kernel, source-table grant, migration, or
new deployment boundary was introduced.

## SCC inventory and priority

Before this proof point the SCC was a complete directed graph:

| Relationship | Main source area | Disposition |
|---|---|---|
| Calls -> Conversations | `audio_calls.ex`, `audio_calls/*.ex` | Deferred audio/video |
| Calls -> IdentityAccess | `audio_calls.ex`, `audio_calls/*.ex` | Deferred audio/video |
| Calls -> TenantAdministration | `audio_calls.ex`, `audio_calls/*.ex` | Deferred audio/video |
| Conversations -> Calls | `conversations.ex` | Deferred audio/video |
| Conversations -> IdentityAccess | `conversations.ex`, schemas, projector | Broader identity eligibility/projection slice |
| Conversations -> TenantAdministration | `conversations.ex`, schemas | Retained policy direction |
| IdentityAccess -> Calls | `accounts.ex`, `password_recovery.ex` | Deferred audio/video |
| IdentityAccess -> Conversations | `accounts.ex`, `service_accounts.ex` | Two distinct bootstrap and service-directory workflows |
| IdentityAccess -> TenantAdministration | identity schemas and lifecycle facades | Broad tenant/security relationship |
| TenantAdministration -> Calls | `administration.ex` | Deferred audio/video |
| **TenantAdministration -> Conversations** | **`admission_quotas.ex`** | **Selected** |
| TenantAdministration -> IdentityAccess | `admission_quotas.ex`, invitations | Retained invitation workflow and tracked identity-count debt |

Non-audio priority was:

1. TenantAdministration -> Conversations: one source and one coherent quota
   concern.
2. IdentityAccess -> Conversations: two unrelated workflows plus bootstrap
   transaction semantics.
3. Conversations -> IdentityAccess: eligibility, presentation, and four
   persistence/projection sources.
4. Remaining tenant/identity directions: broad security, association, and
   lifecycle work.

No single cut can remove a context from a complete four-node SCC. The honest
result is four contexts with eleven, rather than twelve, internal
relationships.

## Exact implementation sequence

1. Capture the current advisory-lock, count, decision, and write ordering.
2. Add the Ecto-free `Administration.AdmissionPolicy`.
3. Make `AdmissionQuotas.locked_policy/1` return that policy only after the
   existing transaction-scoped tenant lock is acquired.
4. Move active Conversation and Membership counting into Conversations.
5. Keep quota decisions pure by passing only scalar owner observations to
   AdmissionQuotas.
6. Add the Ecto-free `Conversations.AdmissionUsage` owner projection.
7. Remove the cross-owner aggregate SQL and compose the existing response in
   Operations through exact owner queries.
8. Keep the AdminTenantController HTTP response unchanged while moving usage
   composition outside TenantAdministration.
9. Add behavior and architecture regressions, regenerate the baseline, and
   verify the exact graph delta.

## Implementation by file

### Owner contracts and behavior

- `apps/comms_core/lib/comms_core/administration/admission_policy.ex` defines
  the TenantAdministration policy DTO.
- `apps/comms_core/lib/comms_core/admission_quotas.ex` retains the shared lock,
  tenant policy, active-identity debt, and pure scalar decisions. It has no
  Conversation or Membership reference.
- `apps/comms_core/lib/comms_core/conversations/admission_usage.ex` defines the
  Conversations-owned usage DTO.
- `apps/comms_core/lib/comms_core/conversations.ex` owns conversation/member
  counts and preserves lock-before-count transaction ordering.

### Read-model and adapter composition

- `apps/comms_core/lib/comms_core/operations.ex` composes the stable tenant
  usage projection from exact owner queries.
- `apps/comms_core/lib/comms_core/operations/tenant_quota_usage.ex` defines the
  Ecto-free adapter-facing read-model contract.
- `apps/comms_core/lib/comms_core/administration.ex` returns only its tenant
  and settings results.
- `apps/comms_web/lib/comms_web/controllers/admin_tenant_controller.ex`
  combines the owner result with the authorized Operations projection.

### Tests and control plane

- `apps/comms_core/test/admission_quotas_test.exs` protects concurrent
  admission, archive release, join/rejoin/add behavior, scalar policy
  decisions, and usage output.
- `apps/comms_web/test/administration_controller_test.exs` protects the
  existing HTTP shape and error codes.
- `scripts/test_validate_architecture.py` enforces owner-local queries, exact
  read-model contracts, the absence of the reverse edge, and the prohibition
  on business contexts depending on Operations.
- `docs/02-architecture/context-boundaries.yaml` declares both contracts and
  the exact Operations queries without granting new source tables.
- The baseline and generated violation report record the verified graph.

## Verified architecture delta

| Measure | Before | After |
|---|---:|---:|
| Tracked boundary findings | 102 | 99 |
| Foreign-schema findings | 83 | 81 |
| Undeclared-edge fingerprints | 11 | 10 |
| Principal SCC members | 4 | 4 |
| Principal SCC internal relationships | 12 | 11 |

Removed fingerprints:

- `4db8a73cb32f6c26` — TenantAdministration -> Conversations;
- `9b52042529f538d5` — foreign Conversation schema; and
- `c5d9102ad275959c` — foreign Membership schema.

The old SCC fingerprint `d900c7783f86b39a` is replaced by
`127209a1d6c0c922`.

## Verification evidence

- [x] Focused admission-quota tests pass.
- [x] Focused administration-controller tests pass.
- [x] The architecture analyzer reports the exact expected baseline delta.
- [x] A fresh disposable database migrates through every current migration.
- [x] The full umbrella ExUnit suite passes: 306 tests.
- [x] Full warnings-as-errors compilation passes.
- [x] `mix format --check-formatted` and `git diff --check` pass.
- [x] Architecture validator tests pass: 74 tests.
- [x] Architecture validation passes against exactly 99 tracked findings.
- [x] Mix xref confirms AdmissionQuotas has no Conversations dependency; four
      unrelated pre-existing file cycles remain.
- [x] Documentation validation passes: 189 Markdown files.

## Residual risks and temporary debt

- TenantAdministration still imports the canonical User schema to count active
  identities. The invitation workflow also intentionally calls IdentityAccess;
  that aggregate direction remains tracked.
- NotificationDelivery's pre-existing IdentityAccess eligibility reads remain
  unchanged and unlegitimized by this proof point.
- Every Calls incident edge and the deferred audio adapter schema leak remain
  unchanged.
- The usage endpoint is an observational multi-owner read. Admission
  enforcement remains transactionally serialized, but the report does not
  promise a cross-owner repeatable-read snapshot during concurrent changes.
- Tenant settings commit before the controller reads the Operations
  projection. A database failure in that post-commit read cannot roll back the
  accepted command; clients should refetch after an uncertain response. Keeping
  the command independent avoids a forbidden business-to-read-model dependency.
- The SCC remains dense. Future proof points should continue cutting one
  aggregate relationship at a time rather than broadening this change.
