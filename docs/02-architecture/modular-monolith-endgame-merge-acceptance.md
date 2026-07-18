# Modular-monolith endgame merge acceptance record

**Date:** 2026-07-18

**Decision:** ADR-0044

**Merge:** PR #16, `f304ebd881429d8853c894aee045dff4a196f62a`
**Compared range:** `edb0b20b8f5b49caa237a11ada2e8168dbe6660b` to
`6e60a54f002c3e9b2725ed4a68628c6eba4c30e0`

## Acceptance result

The complete PR #16 delta is retrospectively accepted as the integrated
modular-monolith endgame. It is not accepted under the narrower label
"Calls-only." The Calls-only claim applies to `ecf77da`, whose 70-file diff
contains no migration.

This acceptance is based on the Git merge graph, full diff statistics, commit
and directory distribution, inspection of every introduced migration, the
strict architecture result, and the successful PR checks. It does not replace
the production migration preflight or authorize future broad merge units.

## Scope evidence

| Evidence | Observed result |
|---|---|
| Merge parents | `edb0b20` and reviewed head `6e60a54` |
| Reviewed commits | 25 |
| Full reviewed delta | 707 files; +109,896 / -2,843 |
| Change kinds | 512 added, 190 modified, 4 deleted, 1 renamed |
| Largest areas | 385 `apps/`, 123 `docs/`, 97 `clients/`, 41 `deploy/`, 31 `scripts/` |
| Umbrella-app distribution | 251 `comms_core`, 81 `comms_web`, 30 `comms_integrations`, 19 `comms_workers`, 4 other app files |
| Migrations | 20 added files; 1,904 inserted lines |
| Calls tranche `ecf77da` | 70 files; +3,945 / -1,089; no migration |

The 25 commits comprise twelve staging, release, security, and product-
hardening commits from July 12-14; one pre-endgame checkpoint; ten boundary
control and modularization commits culminating in `ecf77da`; and two final
mainline/container-alignment commits. The reviewed unit therefore includes
substantially more than the final Calls proof point.

## Migration inspection

All paths below are under
`apps/comms_core/priv/repo/migrations/`. Owners are the current manifest
owners. Referencing another owner's key is not a write to that owner's table.

| Migration | Tables changed and owner classification | Promotion and rollback observation |
|---|---|---|
| `20260712000300_add_administration_and_governance.exs` | Alters IdentityAccess and Conversations tables; creates TenantAdministration and TrustGovernance tables. Historical mixed-owner migration. | Adds lock columns, policies, invitations, cases, holds, and deletion state. `down/0` drops the new business records and is destructive after use. |
| `20260712000310_add_integrations_safety_operations.exs` | Changes ConversationContent and creates NotificationDelivery and WebhookManagement tables. Historical mixed-owner migration. | Backfills attachment scan state and creates delivery/secret/attempt state. `down/0` drops durable delivery and scan history. |
| `20260712000320_harden_administration_and_governance.exs` | Changes IdentityAccess, TrustGovernance, and an Audit index. Historical mixed-owner migration. | Adds socket tickets, execution state, and indexes. A rollback drops tickets and newly recorded execution fields. |
| `20260712000330_harden_integrations_and_attachment_identity.exs` | Changes ConversationContent, NotificationDelivery, and WebhookManagement. Historical mixed-owner migration. | Adds version, claim, checksum, and key constraints with backfills. Removing these columns loses claim/version evidence. |
| `20260712000340_add_platform_operator_identity.exs` | `users`; IdentityAccess only. | Adds the legacy platform-role field and constraint; later migration 00140 deliberately deprecates its stored value. |
| `20260712000350_add_password_recovery_requests.exs` | `password_recovery_requests`; IdentityAccess only. | Creates recovery state. `down/0` destroys outstanding recovery requests. |
| `20260712000360_index_password_recovery_cleanup.exs` | Password-recovery cleanup index; IdentityAccess only. | Index-only, with no business-data transformation. |
| `20260712000370_add_service_accounts.exs` | `users` and `service_accounts`; IdentityAccess only. | Adds account type and service-account credentials. `down/0` destroys service-account records. |
| `20260712000380_add_push_subscriptions.exs` | `push_subscriptions` and `notification_intents`; NotificationDelivery only. | Creates encrypted subscription state and intent references. It is single-owner, so its stale mixed-owner exception is removed. `down/0` destroys subscriptions. |
| `20260712000390_add_mentions_threads_and_notification_state.exs` | ConversationContent and NotificationDelivery tables. Historical mixed-owner migration. | Adds canonical threads, mentions, and read/dismiss state. `down/0` discards those records and state. |
| `20260712000400_add_tenant_admission_quotas.exs` | `tenant_settings`; TenantAdministration only. | Adds bounded quota fields with defaults and constraints. |
| `20260713000100_allow_orphaned_push_intent_versions.exs` | `notification_intents`; NotificationDelivery only. | Relaxes a subscription-shape constraint; `down/0` clears orphan version metadata before restoring the old constraint. |
| `20260713000110_require_context_bound_webhook_secrets.exs` | Webhook secret, endpoint, and delivery tables; WebhookManagement only. | Locks and preflights unsafe states, fails eligible deliveries, then deletes legacy secrets. The deleted secret material is intentionally not restored by `down/0`. |
| `20260713000120_add_session_absolute_expiry.exs` | `sessions`; IdentityAccess only. | Backfills a 30-day absolute expiry, makes it required and immutable, and provides a one-release writer default. |
| `20260713000130_preserve_session_rollback_compatibility.exs` | `sessions`; IdentityAccess only. | Reasserts the one-release compatibility default in both directions; it is not a general database rollback mechanism. |
| `20260713000140_add_expiring_platform_role_grants.exs` | `platform_role_grants` and `users`; IdentityAccess only. | Copies legacy roles into eight-hour grants, clears legacy roles, and fails closed. `down/0` does not recreate non-expiring privileges. |
| `20260715000100_add_audio_calls.exs` | `audio_calls` and `tenant_settings`; Calls and TenantAdministration. Historical mixed-owner migration. | Creates call state and tenant enablement. `down/0` destroys call history. |
| `20260715000200_add_audio_call_ending_state.exs` | `audio_calls`; Calls only. | Adds the transitional `ending` state. `down/0` converts any remaining `ending` records back to `active`. |
| `20260715000300_add_audio_call_participants.exs` | `audio_call_participants`; Calls only. | Creates admission, credential, revocation, and eviction state. `down/0` destroys participant history. |
| `20260715000400_add_video_calls.exs` | `audio_calls` and `tenant_settings`; Calls and TenantAdministration. Historical mixed-owner migration. | Adds media kind and tenant video enablement. `down/0` removes video classification and policy fields. |

Thirteen migrations are single-owner IdentityAccess, NotificationDelivery,
WebhookManagement, TenantAdministration, or Calls changes. Seven are
historical mixed-owner migrations and remain explicitly listed in the
manifest. The broader historical exception list also contains earlier mixed
migrations outside PR #16.

## Architecture reconciliation

The current control plane discovers 173 production `CommsCore` modules and
requires exactly one manifest owner for each. The manifest has 38 table
ownership entries: 35 locally discovered schema-table mappings and three
external technical declarations (`oban_jobs`, `oban_peers`, and
`schema_migrations`). Each entry has exactly one owner and a canonical schema
or, for `oban_peers`, a canonical accessor.

The violation baseline remains empty. Removing the push-subscription migration
exception narrows historical permission; it does not change table ownership,
allowed context edges, or accepted findings.

## Production promotion and rollback posture

Before applying the migration set to production:

1. Verify a restorable database backup and rehearse the restore procedure.
2. Run migrations against a production-shaped copy and capture duration and
   lock impact.
3. Confirm current legacy webhook secrets are rotated and no matching delivery
   is in `delivering`; migration 00110 intentionally aborts otherwise.
4. Verify the immediately previous release can write sessions through the
   documented absolute-expiry compatibility window.
5. Apply migrations forward, deploy the matching application, then run identity,
   webhook, notification, conversation-content, and Calls smoke tests.
6. If promotion fails after destructive data changes, restore the verified
   backup or apply an explicitly reviewed forward repair. Do not assume
   `mix ecto.rollback` reconstructs deleted or transformed business data.

## Validation evidence

The following evidence is reproducible from the repository:

```text
git rev-list --count edb0b20..6e60a54
git diff --shortstat edb0b20 6e60a54
git diff --name-status edb0b20 6e60a54
git diff --name-only edb0b20 6e60a54 -- apps/*/priv/repo/migrations/*
git diff --shortstat ecf77da^ ecf77da
git diff --name-only ecf77da^ ecf77da -- apps/*/priv/repo/migrations/*
```

PR #16 recorded successful backend, web, validation, qualification-script,
manifest, security, CodeQL, dependency-review, and pull-request-smoke checks.
The repository's documentation and strict architecture validators are rerun
after this record and the exception correction.
