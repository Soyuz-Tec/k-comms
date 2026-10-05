# ADR-0097: Verify opt-in workspace domain discovery

Status: Accepted
Date: 2026-10-05
Owners: TenantAdministration, IdentityAccess, TrustGovernance

Release qualification: pending

## Context

The sign-in gateway accepts a manually entered workspace slug. A domain hint
must not create accounts, assert email ownership, select trusted SSO, or disclose
whether a particular person has an account. Domain ownership and identity
authorization are separate facts.

## Decision

TenantAdministration owns `workspace_domain_claims`, exact domain comparison,
the administrative CAS workflow, and the public sign-in hint. One active tenant
may retain at most eight claims. DELETE revocation removes the claim and records
a normal Audit event, so revoked records do not accumulate in this table.
Claims never authorize invitations, enrollment, account linking, role assignment,
or enterprise identity selection.

Input is an exact canonical ASCII FQDN, including an explicitly supplied
punycode domain. Case and one terminal root dot are normalized. URLs, ports,
addresses, email, wildcard labels, whitespace, malformed labels, and reserved
local/test names are rejected. There is no suffix or wildcard matching.

An administrative create or challenge rotation generates 32 random bytes and
provides the exact TXT record `_k-comms.<domain>.` with value
`k-comms-workspace-verification=<base64url token>`. Each challenge expires after
30 minutes. The DNS-only technical resolver has a five-second wall-clock budget,
bounded answer count/size, and compares the complete TXT value. The system
resolver accepts TXT answers only for the exact requested record name. Lookup
failure, timeout, or an uncertain answer cannot prove ownership or extend a
lease. DNSSEC validation is not claimed by this application; deployment DNS
resolver trust remains an infrastructure property.

A matching current challenge issues a seven-day proof lease and consumes its
token. An owner may explicitly enable public discovery, renew a challenge,
disable disclosure, or revoke the claim. Opt-out retains domain ownership until
lease expiry or revocation. A global domain advisory fence and a unique partial
index permit only one verified tenant claim for a domain. Under that fence,
verification mechanically expires only a previously expired canonical claim's
status; it does not lock or mutate the foreign tenant/user or expose its data.

Public POST `/api/v1/workspaces/discover` accepts only `domain`. Unknown,
malformed, unverified, expired, opted-out, and inactive-tenant inputs return the
same HTTP 200 unavailable DTO. An active verified opt-in returns only
`/sign-in?tenant_slug=<validated stored slug>`, a relative same-origin route.
There is no user, email, tenant ID, or provider identifier in the public DTO.
Same-origin JSON and an IP request bound protect the public gateway.

All administrative reads and mutations require a current workspace human
owner/admin and recent identity proof. Domain changes retain the exact tenant,
user, device, and session authority and recheck clock-sensitive proof after DNS
and resource effects before commit. Each mutation requires the current positive
version; creation explicitly requires version zero.

The lock order is TrustGovernance tenant fence, admission quota, active Tenant
SHARE, exact actor User NO KEY UPDATE, Device/Session SHARE, canonical domain
advisory fence, and the matching domain claim row. SQL timeouts are set before
each wait under one absolute 15-second command budget; the outer transaction is
bounded to 20 seconds. No locks or provider effects follow commit.

TenantAdministration owns `WorkspaceDomainIdentityPort` and its typed command,
with Accounts as the configured provider. This transaction-required inversion
uses retained `ContentWriteGrant` facts without importing Accounts schemas.
`WorkspaceDomainGovernancePort` similarly asks Governance for a typed tenant
fence before identity locks. Its exact provider is the Governance facade; the
provider's implementation alone touches TrustGovernance locks. Missing or
invalid providers fail closed. Architecture declarations list exact callers,
operations, DTOs, binding keys, and transaction semantics; broad facade or
namespace exemptions are forbidden.

## Governance and retained state

The nullable challenge actor belongs to the same tenant. On governed user
erasure, the workflow invokes the typed TenantAdministration contribution before
the final strong identity key change, under its retained tenant/all-user fences.
Pending or expired challenges issued by that user are removed. A renewable
challenge attached to a current tenant-owned verified lease is cleared and its
actor detached, with a counts-only receipt. The verified lease may remain until
its existing expiry; it no longer contains a personal challenge or actor
reference. Physical tenant deletion cascades through the canonical tenant FK.
This ADR does not invent a tenant-erasure workflow.

Retained claim state requires `workspace_domain_discovery_v1` in rollback
compatibility declarations. A target lacking that capability must be stopped
behind the normal database-quiescence check and fail if any claim remains.
Migration down refuses retained claims rather than deleting them. Fresh empty
database down/up qualification is a disposable synthetic drill, not a production
rollback receipt.

## Qualification and delivery

Meaningful owner/HTTP tests cover exact proof, neutral disclosure, opt-out,
revocation, cross-tenant uniqueness, lease retirement, hard bounds, CAS,
clock/current-session denial after real PostgreSQL waits and DNS work, and
personal challenge erasure. These tests are authored but not yet executed in
this isolated worktree. Current-parent rebase, strict architecture qualification,
final compile, migrations, backend/browser gates, immutable artifact publication,
protected staging, and independent production approval remain required.

Real DNS ownership acceptance requires an authorized test domain and deployment
resolver. No domain has been registered, DNS record published, or real tenant
disclosure enabled during implementation. The implementation remains opt-in.

## Accepted exact registry and erasure integration

This source decision registers the ten TenantAdministration-owned Discovery
DTO/port contracts, owner-only WorkspaceDomainClaim table and seven public
administrative/discovery operations. Governance consumes only the typed user
erasure command/receipt; Accounts implements the Administration-owned retained
identity port, and Governance implements its tenant-fence port. The two runtime
bindings list only WorkspaceDomains as caller, exact operations and transaction
semantics. No foreign persistence, new Repo exception or baseline waiver is
permitted. The retained-identity result is the existing IdentityGrant DTO.

The exact reviewed transition is bound to committed
610b6acd6bd2cd20a8607481cedc1e35fc1cd956 and lists only the fifteen Discovery
semantic additions: ten named DTO/port contracts, the narrow owner-command
facade, two runtime collaborations, the owner-only claim table and the public
operation snapshot hash. Member, Role, Usage and History declarations are
inherited intact from accepted ADR0093-0096. Every preceding owner, operation,
table, dependency and named contract remains in force. Later widening requires
a new exact accepted transition; this declaration grants no broader authority.

Actual user erasure invokes Administration after the canonical retained User
fence, session/device drain and lower membership contributions, before strong
Identity key anonymization. Completion records only removed/detached counts and
domain_challenge_erasure_version=1 for user targets. Historical reconciliation
selects user completions missing that marker even when all older proofs are
current; non-user completions require no domain marker. The actual registered
DeletionWorker and ErasureReconcilerWorker regression sources cover scope,
lease preservation, raw challenge removal and idempotent completion.

workspace_domain_discovery_v1 requires the ALL-retained-row owner hazard and
workspace_domain_claims fingerprint inventory. Known twelve-capability M1 and
fourteen-capability Member/History receipts retain only their original scope;
current images declare all fifteen. No Discovery job is invented. Source-only
parsing and Python checks do not qualify DNS, migrations, application runtime or
protected delivery. Those receipts remain pending.

Governance calls the narrow published Administration.WorkspaceDomainErasure
facade's sole erase_user_challenges/1 core collaboration. Administration's root
erase_workspace_domain_user_challenges/1 delegate remains compatible. Exact
individual DTO aliases and this owner-command facade preserve the existing
Governance RetentionDefaultsReader read-only scope without a broad facade
exception or baseline change. The validator now derives resources reserved
outside a scoped reader from the exact query facades and source schemas declared
by that reader, rather than every facade owned by those contexts. Its within-reader
owner-facade checks and dynamic-call, query, write and schema enforcement remain
unchanged. Regression sources retain direct and dynamic root-query denial, foreign
schema/table and reader-write denial, while permitting only a separately published
owner-command facade through the normal typed operation and graph checks.
