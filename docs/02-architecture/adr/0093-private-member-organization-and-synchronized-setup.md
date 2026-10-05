# ADR-0093: Private member organization and synchronized setup

Status: Proposed implementation, qualification pending  
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
