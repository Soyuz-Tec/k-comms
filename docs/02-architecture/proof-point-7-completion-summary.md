# Proof Point 7 completion summary

Status: complete

Historical note: all counts and attribution statements in this summary describe
the Proof Point 7 completion snapshot. Proof Point 9 later hardened grouped
alias parsing and canonical-schema edge attribution, so the current baseline is
not directly comparable.

## Outcome

Proof Point 7 delivered both required parts without migrations, audio/video
changes, Governance erasure, or umbrella restructuring.

| Measure | PP6 baseline | After PP7 Part A | PP7 final |
|---|---:|---:|---:|
| Total tracked boundary findings | 29 | 14 | 12 |
| `direct_foreign_write` | 20 candidates | 5 genuine groups | 3 genuine groups |
| `undeclared_context_edge` | 7 | 7 | 7 |
| `adapter_schema_import` | 1 | 1 | 1 |
| `business_context_cycle` | 1 | 1 | 1 |

Part A removed 15 false-positive direct-write fingerprints while retaining all
confirmed writes. Part B removed both Accounts direct-write groups. The three
remaining direct-write groups are all in `CommsCore.Governance`:

1. Governance writes IdentityAccess-owned User, Device, and Session schemas.
2. Governance writes ConversationContent-owned Message, Revision, Reaction,
   and Attachment schemas.
3. Governance writes Conversations-owned Conversation and Membership schemas.

## Part A

`scripts/validate_architecture.py` now:

- derives canonical persistence ownership from
  `tables.<table>.canonical_schema -> owner`;
- used that map for write targets only at this historical stage; Proof Point 9
  supersedes this with canonical-schema dependency attribution;
- resolves Repo, Ecto.Multi, pipeline, bulk-query, changeset-variable, and
  local-wrapper write targets;
- ignores read-only foreign joins and foreign reads adjacent to owner writes;
  and
- keeps PP6 Messaging reach-through regressions active.

The validator suite contains positive and negative attribution fixtures plus a
repository-level exact-inventory assertion.

## Part B

- `Administration.append_bootstrap_tenant/3` and
  `create_bootstrap_tenant/1` own Tenant construction and return `TenantView`.
- `Conversations.append_initial_tenant_channel/3` and
  `create_initial_tenant_channel/1` own Conversation/Membership construction
  and return `ConversationView`.
- `Administration.Invitations` owns all Invitation reads, token behavior,
  expiry, locking, construction, and writes.
- `Accounts.enroll_invited_user/1` consumes `InvitedUserCommand`, owns User
  persistence, and returns `UserView`.
- `CommsWeb.InvitationController` calls the Administration facade.
- Foreign Ecto associations were removed from the Invitation schema in favor
  of scalar UUID fields; existing database foreign keys remain.

Normal bootstrap remains one `Ecto.Multi` transaction. One-time release
bootstrap retains its PostgreSQL advisory lock and outer transaction.
Invitation acceptance retains committed expiry semantics and atomic
user/invitation/audit success.

## Verification

All verification used an isolated `k_comms_pp7_test` database because the
container's configured development database already contained committed
tenants.

- `python scripts/test_validate_architecture.py`: 38 passed.
- `python scripts/validate_architecture.py`: passed with 12 tracked findings.
- `mix format --check-formatted`: passed.
- `MIX_ENV=test mix compile --warnings-as-errors`: passed.
- Targeted ownership/web suite: 42 passed.
- Full umbrella suite: 281 passed:
  - comms_observability: 1
  - comms_core: 163
  - comms_test_support: 1
  - comms_integrations: 38
  - comms_workers: 25
  - comms_web: 53

## Honest residual architecture

The business SCC is unchanged and still contains seven contexts:

`calls -> conversation_content -> conversations -> identity_access ->
notification_delivery -> tenant_administration -> trust_governance -> calls`

Accounts still has an undeclared compiled edge to Conversations, but it now
references only the public facade, not Conversation or Membership schemas.
ServiceAccounts retains a separate IdentityAccess-to-Conversations edge. These
remain visible in the baseline and were not allowlisted.

The next proof point should be Governance erasure through owner-contributed
transaction APIs.
