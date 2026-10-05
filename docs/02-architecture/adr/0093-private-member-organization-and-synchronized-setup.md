# ADR-0093: Private member organization and synchronized setup

Status: Accepted
Qualification: source boundary decision accepted; execution and protected delivery pending.
Date: 2026-10-05  
Owners: IdentityAccess; Web

## Context

The member directory already starts actual conversations and calls. Members
still lack private contacts and groups, and the welcome checklist is dismissed
only in the current browser. A private organization feature must preserve
current tenant/session authority and governed erasure; it cannot grant access.

## Decision

IdentityAccess owns one versioned private member workspace per active human
with workspace access. It contains at most 500 current same-tenant human
contacts and 20 private groups, each with at most 50 contact members. Group
names are at most 80 characters; IDs are server-validated UUIDs. Groups confer
no conversation membership, role, invitation or permission. Existing
Conversations APIs remain the authority for actual message/call handoff.

The authenticated GET projects current eligible identities, never stored
display names or email. Ineligible references are absent from contacts and
groups. PUT requires the exact aggregate version (zero for a missing record),
validates all submitted identities, and fails atomically on conflict. Clients
retain pending inputs and reload the latest authorized version before retry.

The same aggregate synchronizes checklist dismissal/resume/reset. Profile
review records only an actual successful IdentityAccess profile update. Device
and teammate status come from current owner data. Camera/microphone consent
remains device-local; checklist state cannot authorize capture or activate a
device. Notification preferences remain owned by Notifications and are linked
to their actual settings flow rather than invented checklist proof.

Writers retain the tenant quota admission prefix, active Tenant SHARE and
sorted actor/target User NO KEY UPDATE rows before current Device/Session and
their private aggregate. They use an absolute 15-second SQL wait budget and a
20-second transaction budget, and revalidate current authority/expiry before
commit. No target schema crosses the IdentityAccess facade.

Governed erasure removes the user's private aggregate and its references from
all other member aggregates while the existing canonical User fence is held.
It increments affected versions so a stale client cannot restore erased
references. The `member_workspace_v1` immutable binary capability is required
while any retained member workspace exists. Migration down refuses retained
private state; production rollback cannot discard it to admit an old binary.

## Accepted boundary registry

This decision composes the accepted boundaries in ADR-0093 through ADR-0096
against qualified immutable first parent
`e7d85225b875a83d071f10c27a5e3e7f2675540e`. The manifest transition is bound to
that parent's exact manifest hash and the resulting frozen facade inventory.
Its 26 sorted semantic tokens add only the named Member, Role, Usage and History
DTOs, two canonical owner-only tables, and the updated operation inventory.
The first parent's ownership, namespace rules, dependencies, ports, operations,
strict enforcement and empty violation baseline remain in force. This review
adds no persistence exception or repository interface.

IdentityAccess publishes `MemberContactView` with only current `id` and
`display_name`, and the private aggregate `MemberWorkspaceView`.
`CommsWeb.MemberWorkspaceController` consumes exactly
`Accounts.member_workspace_view/1`, `replace_member_workspace/2`, and
`update_member_onboarding/2`; it imports neither the `MemberWorkspace` schema
nor its implementation. The `member_workspaces` canonical table belongs to
`CommsCore.Accounts.MemberWorkspace`, with persistence access restricted to the
Accounts namespace. Governed finalization calls the private owner erasure helper
after drain validation and before strong identity-key anonymization under the
existing complete canonical User fence.

Release consumes only `Accounts.rollback_member_workspace_hazard_count/0` and
the existing owner fingerprint fragment. Every persisted aggregate remains a
hazard, including empty state and state retained for inactive or limited
identities. The public fragment includes aggregate IDs for fingerprint hashing;
formatted release receipts expose counts and a hash. No runtime flag grants
`member_workspace_v1` to an older binary.

ADR-0094 defines Audit/Governance history ownership and purge delivery,
ADR-0095 defines the IdentityAccess role DTOs and advisory operations, and
ADR-0096 defines the six independent owner projections and Web composition.
Acceptance here concerns these exact architectural contracts. Database,
application, browser, provider and protected delivery evidence remains a
separate qualification requirement.

## Scope and qualification

Domain discovery is separate tenant-owned verified DNS state and needs its own
trust contract; email alone never links an account or creates membership.
Contacts do not support external address imports. Native clients, co-editing,
calendar synchronization, contact-center software and E2EE remain separate
full-UC roadmap work.

Acceptance requires real cross-device synchronized reads, version conflicts,
active/foreign/guest denial, profile success/failure attribution, actual group
conversation handoff, and retained-reference erasure under an overlapping
writer. API, browser, migration, rollback, strict architecture and protected
release receipts are pending; this ADR is not an acceptance receipt.
