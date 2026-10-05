# ADR-0095: Guided fixed-role delegation

Status: Accepted
Qualification: source boundary decision accepted; execution and protected delivery pending.
Date: 2026-10-05  
Owners: IdentityAccess; Governance; TenantAdministration; Web

## Context

The governed user lifecycle command already supports six fixed tenant roles.
An administrator currently selects a role without a server-derived explanation
of its effect. A preview must describe the existing owner policies, preserve
their current identity and recent authentication requirements, and remain
advisory until the governed command validates the actual change.

ADR-0050 explicitly restricts converted conversation-only humans to admitted
conversations and requires a separate authenticated enrollment workflow to
widen their account scope. A role change must not imply workspace enrollment.
The previous role-only TenantAdministration projection and Governance gate
could admit a conversation-only human carrying an elevated role. The new
guided workflow must preserve the documented boundary rather than describe
that mismatch as an available tenant permission.

## Decision

IdentityAccess owns `RolePermissions`, the shared fixed-role assignment policy
used by the existing user lifecycle mutation and the new advisory preview.
The roles remain `member`, `moderator`, `admin`, `compliance_admin`,
`security_admin`, and `owner`. Owners retain the existing assignment authority;
administrators may change only non-privileged targets between member and
moderator. Conversation-only human targets cannot be assigned owner, admin,
compliance-admin, or security-admin roles. Scoped member/moderator changes,
demotion to a safe role, and status-only cleanup remain available under the
existing actor policy. No role mutation changes `access_scope`.

`Accounts.resolve_access/1` produces the TenantAdministration-owned
`IdentityGrant` only for a current workspace human. Governance independently
requires the same account type and scope before role and recent-step-up checks.
These corrections leave `Accounts.access_grant/1` and
`Accounts.lock_access_grant/1` unchanged; supported Guest and converted scoped
conversation messaging and calling continue through their existing policies.

The read-only role catalog exposes seven bounded tenant eligibility facts:
user administration, user lifecycle management, session management, settings,
invitations, auditing, and governance. Each fact states current tenant,
identity, session, workspace access, and applicable recent-step-up conditions.
Actual owner-facade tests cover every fact across all six workspace roles and
deny every tenant capability across all six conversation-only roles. These are
role eligibility descriptions; they grant no resource access, platform role,
custom permission, team scope, expiry, or future assignment guarantee.

`GET /api/v1/admin/role-permissions` requires a current workspace-human owner
or administrator. `POST /api/v1/admin/users/:id/role-preview` additionally
requires recent step-up and the exact current target version. IdentityAccess
owns the response DTOs `RoleCapabilityView`, `FixedRolePermissionView`, and
`UserRoleChangePreviewView`; the only direct consumers are the Web role
permission controller through `Accounts.list_fixed_role_permissions/1` and
`Accounts.preview_user_role_change/3`.

The preview includes target role, version, status and scope, the shared policy
decision, added/removed facts, and advisory blockers. The actual lifecycle
guard and preview count only active workspace-human owners as eligible
remaining owners. A legacy limited owner cannot permit demotion of the last
eligible workspace owner. The preview explicitly states `advisory` and
`governance_review_required`. It does not reserve ownership or bypass legal
holds, lifecycle exclusions, last-owner protection, quotas, reason, version, or
authentication checks. The existing governed lifecycle command remains the
sole mutator and repeats all of those applicable checks when submitted.

The catalog and preview retain the admission advisory prefix, active Tenant
SHARE, complete sorted actor/target User NO KEY UPDATE parents, and exact
current Device/Session authority in that order. An absolute 15-second SQL wait
budget and 20-second repository transaction cap bound all waits. Current actor
authority and proof are rechecked before disclosure. A pending preview whose
actor is revoked before admission returns no role facts. No preview state is
stored, so this feature adds no retained erasure state or binary capability.

## Accepted boundary registry

The exact ADR-0093 composition transition publishes only IdentityAccess's
`RoleCapabilityView`, `FixedRolePermissionView`, and
`UserRoleChangePreviewView`, with public operations
`Accounts.list_fixed_role_permissions/1` and `preview_user_role_change/3`.
`CommsWeb.RolePermissionController` is their direct delivery consumer.
`RolePermissions`, `RolePreviews`, the shared lifecycle policy, and their
persistence remain owner-internal. This contract introduces no custom grants,
new table, repository exception, foreign schema access, or additional runtime
collaboration. SCIM and governed erasure use the same active human workspace
owner eligibility for target protection and remaining-owner counts; unusable
legacy limited owners cannot justify removal of the last eligible owner and
cannot block safe cleanup of their own identity.

## Qualification

Owner, controller, and actual PostgreSQL blocker regressions cover preview
versus real governed changes, protected roles, sole-owner demotion, stale
versions, step-up, revoked actors, limited targets, and retained Guest/converted
room messaging. Source formatting and parse checks are separate from runtime
qualification. Strict architecture, backend, browser, full coverage, build,
release and provider acceptance receipts remain pending; this ADR does not
claim completion of those gates.
