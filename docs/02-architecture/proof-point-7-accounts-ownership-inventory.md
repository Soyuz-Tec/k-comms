# Proof Point 7: Accounts ownership inventory

Status: implemented  
Scope: tenant bootstrap and invitation lifecycle persistence formerly implemented in `CommsCore.Accounts`

Historical note: this inventory records the state at Proof Point 7 completion.
Its graph counts predate the Proof Point 9 validator hardening and are not a
statement of the current business SCC.

## Ownership decision

- TenantAdministration owns `tenants` and `invitations`.
- IdentityAccess owns `users`, `devices`, and `sessions`.
- Conversations owns `conversations` and `conversation_memberships`.
- Audit owns `audit_events`.
- `CommsCore.Accounts` remains the narrow bootstrap transaction coordinator in
  this proof point, but it constructs only IdentityAccess schemas. Tenant and
  conversation writes are owner-contributed operations returning views.

This is deliberately smaller than introducing another umbrella application or
rewriting the complete business-context cycle.

## Pre-refactor persistence inventory

Line references identify the pre-refactor snapshot documented at the start of
Proof Point 7.

| File/function | Foreign schema/table | Access | Owner | Pre-refactor evidence | Implemented owner API |
|---|---|---|---|---|---|
| `accounts.ex:142-149`, `bootstrap_tenant/1` | `Accounts.Tenant` / `tenants` | Write | TenantAdministration | Accounts constructed and inserted `Tenant` in its Multi. | `Administration.append_bootstrap_tenant/3` |
| `accounts.ex:173-183`, `bootstrap_tenant/1` | `Conversations.Conversation` / `conversations` | Write | Conversations | Accounts constructed the General channel. | `Conversations.append_initial_tenant_channel/3` |
| `accounts.ex:184-194`, `bootstrap_tenant/1` | `Conversations.Membership` / `conversation_memberships` | Write | Conversations | Accounts constructed the initial owner membership. | The same `append_initial_tenant_channel/3` operation owns both rows. |
| `accounts.ex:216-226`, bootstrap result | Tenant and Conversation structs | Contract leak | TenantAdministration / Conversations | Foreign Ecto structs left the owner boundaries. | `TenantView` and `ConversationView` |
| `accounts.ex:255-260`, `bootstrap_tenant_once/1` | `Accounts.Tenant` / `tenants` | Read | TenantAdministration | Accounts queried/pattern-matched the historical tenant schema. | `Administration.get_bootstrap_tenant_by_slug/1` and `any_tenant?/0` |
| `accounts.ex:1292-1299`, `create_one_time_bootstrap/3` | `Accounts.Tenant` / `tenants` | Write | TenantAdministration | Accounts directly inserted a release-bootstrap tenant. | `Administration.create_bootstrap_tenant/1`, transaction-required |
| `accounts.ex:1315-1337`, `create_one_time_bootstrap/3` | Conversation and Membership tables | Write | Conversations | Accounts directly inserted both rows. | `Conversations.create_initial_tenant_channel/1`, transaction-required |
| `accounts.ex:1369-1382`, `existing_bootstrap/2` | `conversations` | Read | Conversations | Accounts queried and returned the General-channel schema. | `Conversations.get_initial_tenant_channel/2` |
| `accounts.ex:852-907`, `create_invitation/2` | `Administration.Invitation` / `invitations` | Read/write | TenantAdministration | Accounts expired, queried, constructed, inserted, and returned invitations. | `Administration.create_invitation/2` through internal `Administration.Invitations` |
| `accounts.ex:909-921`, `list_invitations/2` | `invitations` | Read/write | TenantAdministration | Accounts materialized expiry and returned raw schemas. | `Administration.list_invitations/2`, returning `InvitationView` |
| `accounts.ex:923-957`, `revoke_invitation/3` | `invitations` | Read/write | TenantAdministration | Accounts locked and updated the invitation. | `Administration.revoke_invitation/3`, returning `InvitationView` |
| `accounts.ex:959-973,1877-1924`, acceptance | `invitations` | Read/write | TenantAdministration | Accounts owned token verification, expiry, and accepted-state persistence. | `Administration.accept_invitation/1` |
| `accounts.ex:1926-1939`, invited user creation | `Accounts.User` / `users` | Write | IdentityAccess | Correct table owner, but coupled to the foreign Invitation schema. | `Accounts.enroll_invited_user/1` consumes `InvitedUserCommand` and returns `UserView`. |
| `accounts.ex:1941-1953`, invitation expiry | `invitations` | Write | TenantAdministration | Accounts executed the bulk update. | Owner-private `Administration.Invitations.expire_pending/2` |

## Implemented transaction shape

### Interactive bootstrap

`Accounts.bootstrap_tenant/1` generates workflow IDs and composes one
`Ecto.Multi`:

1. `Administration.append_bootstrap_tenant/3` inserts `tenants` and contributes
   `TenantView`.
2. Accounts inserts the IdentityAccess-owned user and device.
3. `Conversations.append_initial_tenant_channel/3` inserts the General channel
   and owner membership in one `Multi.run` and contributes `ConversationView`.
4. Accounts inserts the IdentityAccess-owned session.
5. `Audit.append/2` contributes the audit event.
6. `Repo.transaction/1` commits once.

A regression test forces a failure after every owner contribution and proves
the tenant, user, conversation, membership, and audit transaction is rolled
back.

### One-time release bootstrap

The existing outer `Repo.transaction/1` and PostgreSQL advisory lock remain.
Inside that transaction:

- Administration resolves or creates the tenant through transaction-aware
  owner functions.
- Accounts resolves or creates the owner identity.
- Conversations resolves or creates the General channel and membership through
  transaction-aware owner functions.
- Audit and optional platform-role behavior remain transaction-safe.

No database migration or database rewrite was required.

### Invitations

`CommsCore.Administration.Invitations` now owns token generation, expiry,
idempotency, listing, locking, optimistic updates, and all Invitation schema
construction.

Acceptance preserves the previous ordering and atomicity:

1. Accounts validates password strength.
2. Administration parses, locks, and validates the invitation.
3. Expired invitations are committed as expired while the public result remains
   `{:error, :invalid_invitation}`.
4. Tenant admission and IdentityAccess availability checks run under lock.
5. Accounts consumes an `InvitedUserCommand`, inserts `users`, and returns
   `UserView`.
6. Administration marks the invitation accepted.
7. Audit records acceptance in the same transaction.

The Invitation schema now uses scalar UUID fields instead of associations to
Tenant/User persistence structs. Existing database foreign keys remain; no
migration was needed.

## Caller migration

- `CommsWeb.InvitationController` calls `CommsCore.Administration`.
- Administration, admission-quota, and service-account tests call the owner
  facade.
- `CommsTestSupport.Fixtures` rehydrates tenant/conversation schemas by returned
  IDs only for legacy test callers that still require persistence fields.
- Production bootstrap results carry `TenantView` and `ConversationView`.

## Validator and cycle implications

After implementation:

- Accounts has no `direct_foreign_write` finding.
- Accounts no longer imports `Administration.Invitation`,
  `Conversations.Conversation`, or `Conversations.Membership`.
- The direct-write total falls from five after Part A to three; all three
  remaining groups are Governance debt reserved for Proof Point 8.
- The Accounts compiled edge is now `identity_access -> conversations` through
  the public `CommsCore.Conversations` facade only. It remains undeclared debt;
  this proof point does not hide or allowlist it.
- ServiceAccounts retains a separate IdentityAccess-to-Conversations edge.
- The seven-context business SCC therefore remains. Proof Point 7 does not
  claim a cycle break.

## Acceptance outcome

- TenantAdministration is the only production owner constructing Tenant and
  Invitation records in these workflows.
- Conversations is the only production owner constructing the initial channel
  and membership.
- IdentityAccess is the only owner constructing bootstrap and invited users.
- Foreign owner operations return DTOs/views, never Ecto schemas.
- Normal and one-time bootstrap remain transactional.
- Invitation create/list/revoke/accept behavior remains behind the
  Administration facade and acceptance remains atomic.
- The architecture baseline can remove both Accounts direct-write groups
  without changing unrelated audio/video or Governance debt.
