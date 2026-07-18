# Proof Point 11: IdentityAccess notification lifecycle port

Status: complete and verified on 2026-07-17.

This is the repository-effective eleventh proof point. It implements the
request-numbered Proof Point 9 without renaming or overwriting the existing
Proof Point 9 and 10 records.

## Executive outcome

The selected dependency is:

```text
IdentityAccess -> NotificationDelivery
```

The edge is security-sensitive workflow orchestration rather than foreign
schema access. Accounts and PasswordRecovery call the Notifications facade
inside IdentityAccess transactions to create recovery delivery work and revoke
push capability.

The narrow boundary cut is an IdentityAccess-owned, Ecto-free notification
command port implemented by NotificationDelivery. The expected dependency
direction after the cut is:

```text
NotificationDelivery -> IdentityAccess
```

The configuration layer is the only composition point that selects
`CommsCore.Notifications` as the implementation. This preserves the existing
same-process, same-transaction behavior without declaring a bidirectional
business dependency or adding asynchronous delivery semantics.

## Coupling inventory

| Location | Current interaction | Classification | Required invariant |
|---|---|---|---|
| `apps/comms_core/lib/comms_core/accounts.ex` | Calls `Notifications.disable_push_for_device/3` from `revoke_device/2` | Synchronous lifecycle command | Device, sessions, audit, and push revocation commit or roll back together. |
| `apps/comms_core/lib/comms_core/accounts.ex` | Calls `Notifications.disable_push_for_user/3` from governed user lifecycle changes | Synchronous lifecycle command | User access and push revocation remain immediately consistent. |
| `apps/comms_core/lib/comms_core/password_recovery.ex` | Calls `Notifications.create_intent/1` while creating a recovery request | Synchronous recovery command | Request, intent, Oban job, and correlated audit write remain atomic. |
| `apps/comms_core/lib/comms_core/password_recovery.ex` | Calls `Notifications.disable_push_for_user/3` during recovery access revocation | Synchronous lifecycle command | Password reset cannot commit while old push capability stays active. |
| `config/config.exs` | Binds the IdentityAccess-owned port to `CommsCore.Notifications` | Composition root | Runtime indirection remains explicit and validator-enforced. |

NotificationDelivery's existing dependency on IdentityAccess state is the
retained direction. Its pre-existing direct identity-schema reads remain honest
baseline debt outside this cut; the new lifecycle contribution itself depends
only on the Ecto-free IdentityAccess contracts. No notification schema,
changeset, decrypted destination, or persistence command becomes an
IdentityAccess public contract.

## Boundary decision

IdentityAccess publishes three stable contracts:

- `CommsCore.Accounts.NotificationCommand`;
- `CommsCore.Accounts.NotificationReceipt`; and
- `CommsCore.Accounts.NotificationPort`.

The command represents only three lifecycle intentions: create a password
recovery notification, revoke push for one device, or revoke push for one user.
They are constructed through `password_recovery/4`, `device_revoked/3-4`, and
`user_access_revoked/2-3`. Sensitive destinations are inspect-redacted. Recovery
returns `{:ok, %NotificationReceipt{id: intent_id}}`; revocation returns `:ok`.
The receipt carries only the notification identifier needed for the existing
audit correlation.

`CommsCore.Notifications` implements `NotificationPort` and maps those commands
to its existing internal operations. The implementation rejects calls outside a
repository transaction with `{:error, :transaction_required}` and rejects an
unknown operation with
`{:error, :unsupported_identity_notification_command}`. Accounts and
PasswordRecovery roll back their transactions on an adapter error.

This port is not a general-purpose service locator. Only the composition-root
configuration may bind it, and only the narrow IdentityAccess lifecycle flows
may call it.

## Exact refactor sequence

1. Capture the four direct IdentityAccess-to-Notifications call sites and their
   transaction and audit invariants.
2. Add the Ecto-free IdentityAccess command, receipt, and port contracts.
3. Bind `CommsCore.Notifications` in the application configuration.
4. Implement the port in Notifications by delegating to the existing
   transaction-aware owner-internal operations.
5. Replace the Accounts and PasswordRecovery aliases and direct calls with
   commands sent through the port.
6. Add rollback and immediate-consistency tests, including adapter failure and
   out-of-transaction rejection.
7. Extend the repository architecture regression to enforce the contract,
   composition binding, and absence of the reverse edge.
8. Update the manifest public contracts, regenerate the baseline and violation
   report, and verify the exact graph delta.

## Implementation by file

### IdentityAccess contracts

`apps/comms_core/lib/comms_core/accounts/notification_command.ex` defines the
inspect-redacted, Ecto-free lifecycle command.

`apps/comms_core/lib/comms_core/accounts/notification_receipt.ex` defines the
minimal recovery correlation result.

`apps/comms_core/lib/comms_core/accounts/notification_port.ex` defines the
implementation callback and dispatches through the single configured adapter.
Missing, invalid, or failed adapters return an error that the owning
transaction must treat as fatal.

### IdentityAccess callers

`apps/comms_core/lib/comms_core/accounts.ex` replaces both direct
Notifications calls with port commands. Device revocation and governed user
lifecycle changes remain transaction owners.

`apps/comms_core/lib/comms_core/password_recovery.ex` sends the recovery and
push-revocation commands through the port. It continues to put the returned
receipt identifier in audit metadata and retains the existing generic
user-facing recovery response.

### NotificationDelivery implementation

`apps/comms_core/lib/comms_core/notifications.ex` implements the
IdentityAccess-owned port. It requires `Repo.in_transaction?/0`, translates
commands inside the owner facade, and reuses the existing intent/job and
push-subscription code. Notification Ecto schemas remain internal.

### Composition and control plane

`config/config.exs` binds the port to `CommsCore.Notifications`.

`docs/02-architecture/context-boundaries.yaml` publishes the three
IdentityAccess contracts. It does not add NotificationDelivery as an allowed
IdentityAccess dependency.

`scripts/test_validate_architecture.py` must assert the manifest contracts,
composition binding, Notifications implementation, absence of direct
Notifications references in the two IdentityAccess callers, and absence of an
analyzed `identity_access -> notification_delivery` edge.

`docs/02-architecture/context-boundary-baseline.yaml` and
`docs/02-architecture/context-boundary-violations.md` are regenerated only
after production and regression tests pass.

### Behavioral tests

`apps/comms_core/test/identity_notification_port_test.exs` covers transaction
requirements and failure rollback with a controlled failing adapter.

Existing recovery and push-subscription tests remain the primary compatibility
proof. They now make immediate password reset and governed user-lifecycle push
revocation explicit.

## Verified architecture delta

| Measure | Before | Verified after |
|---|---:|---:|
| Tracked boundary findings | 104 | 102 |
| Undeclared edge fingerprints | 13 | 11 |
| Business SCC size | 5 contexts | 4 contexts |
| Internal edges in the principal SCC | 16 | 12 |
| Foreign-schema findings | 83 | 83 |
| Internal-schema findings | 6 | 6 |
| Adapter-schema findings | 1 | 1 |

The two edge fingerprints removed are:

- `bd874a3adc50af6f` from `accounts.ex`; and
- `9c36cadd3be064b3` from `password_recovery.ex`.

The five-context SCC fingerprint `ed93d60bb448290c` was replaced by
`d900c7783f86b39a`, whose members are Calls, Conversations, IdentityAccess, and
TenantAdministration and whose fingerprint includes exactly 12 internal edges.

No other baseline category changed in this proof point.

## Verification evidence

- [x] Focused Accounts, PasswordRecovery, push-subscription, and port tests pass.
- [x] A write-then-fail adapter proves each IdentityAccess transaction rolls
      back completely.
- [x] Port execution outside a transaction fails closed before adapter dispatch.
- [x] The full umbrella ExUnit suite passes: 304 tests.
- [x] `mix format --check-formatted` passes.
- [x] Full warnings-as-errors compilation passes.
- [x] Architecture validator tests pass: 73 tests.
- [x] Architecture validation passes against exactly 102 tracked findings.
- [x] The violation report contains no
      `identity_access -> notification_delivery` edge.
- [x] Mix xref and targeted source searches find no reverse production
      dependency.
- [x] Documentation validation and `git diff --check` pass.

## Residual risks and constraints

- A configured runtime port can conceal an architectural dependency unless the
  configuration key, implementation behavior, and caller restrictions remain
  validator-enforced.
- Synchronous cross-owner persistence remains coupled at runtime by design so
  the existing security and recovery atomicity is not weakened. The port makes
  the compile-time business direction explicit; it does not pretend the
  lifecycle operation is eventually consistent.
- The configured adapter is process-global. Tests that replace it must be
  non-async and restore the previous value.
- Calls, Conversations, IdentityAccess, and TenantAdministration are expected
  to remain cyclic after this cut. Their separate debt is outside this proof
  point.
- NotificationDelivery still has separately tracked foreign-schema reads of
  IdentityAccess state. This proof point does not recast them as approved
  projections or exceptions; replacing them with exact owner queries is a
  later, independently scoped cut.
- The transactional outbox remains unchanged platform infrastructure and is
  not treated as the Audit or IdentityAccess business API.
- No audio/video code, database migration, notification schema, worker
  protocol, or deployment topology belongs in this change.

The remaining four-context SCC and four file-level xref cycles are explicit
residual debt outside this proof point; none contains a reverse
IdentityAccess-to-NotificationDelivery edge.
