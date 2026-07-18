# ADR-0042: Complete non-audio modularization and activate the strict gate

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0001, ADR-0035 through ADR-0041

## Context

After canonical Tenant ownership, the truthful boundary baseline contained 32
findings. Twenty-nine were exact Calls/audio findings. The remaining three were
non-audio implementation leaks: `AdmissionQuotas` read `TenantSettings`,
`Outbox` owned `OutboxEvent` persistence through its public facade, and
`WebhookDelivery` associated directly with `OutboxEvent`.

The source graph also retained four low-value file cycles. Adapter policy
rejected Ecto schemas but did not reject owner-internal projectors, and the
released ValidationError, release-recovery, and notification-availability
interfaces were not expressed as generically validated control-plane entries.
The manifest's strict mode was therefore not ready to activate.

## Decision

Complete the non-audio endgame without changing database tables or media
behavior:

- `Administration.AdmissionPolicyReader` exclusively projects
  `TenantSettings` into `AdmissionPolicy`; `AdmissionQuotas` remains the public
  quota facade.
- `Administration.AuthorizationPolicy` is the one owner-internal orchestrator
  for identity grant resolution, tenant policy evaluation, denial attribution,
  and denial audit recording.
- `Events.OutboxStore` owns `OutboxEvent`, Repo, and Oban persistence. Public
  `Outbox` returns only `Outbox.Event` or existing scalar results, and event/job
  insertion fails closed unless the caller already owns an active Repo
  transaction.
- `WebhookDelivery` retains its database foreign key as a scalar
  `outbox_event_id`.
- Independent policy modules and scalar inverse identifiers remove the
  Administration/Invitations, Authorization/DenyAll, Webhook schema, and
  PlatformRoleGrant/User file cycles.
- `technical_interfaces` declares and validates the exact module, caller,
  operation, contract, implementation, configuration binding, and transaction
  policy for ValidationError rendering, attachment-restore release work,
  Outbox publication, and notification availability.
- `adapter_internal_module_import` rejects production web, worker, and
  integration access to any non-public core implementation module, including
  hidden projectors. Schema references remain the distinct
  `adapter_schema_import` rule.
- `strict_with_explicit_deferrals` is active. Every retained fingerprint maps
  exactly once to a reviewed declaration. Residual-cycle validation prevents a
  Calls finding from masking an independent non-audio cycle. Paired immutable-
  base baseline/manifest comparison rejects every strict-mode addition before
  reviewed-transition adoption and rejects removal or downgrade of active
  strict enforcement.
- Notification outbox retries re-emit the same content-free availability
  projection for an idempotent intent, repairing a post-insert signaling
  failure without creating a second notification.
- Both compile-connected and all-file `comms_core` xref graphs must contain no
  cycles.

## Consequences

- The reviewed baseline changes from 32 to 29 findings with exactly three
  removals and no additions.
- Non-audio foreign-schema imports, internal-schema access, adapter schema or
  internal-module leakage, undeclared context edges, and business cycles are
  zero.
- The combined diagnostic graph may still contain SCCs created by exact,
  validated dependency inversions whose runtime control-flow direction opposes
  the compile-time implementation direction. Those accepted topology edges are
  not retained violation fingerprints; the only retained violation SCC is the
  Calls-driven compiled SCC.
- Outbox transactionality is enforced: the event and Oban publication job use
  the caller's Repo transaction, and owner tests prove rollback atomicity.
- A failed availability signal remains retryable while durable intent creation
  stays idempotent.
- Existing database foreign keys and public HTTP/WebSocket shapes are
  unchanged.
- K-Comms is a strict modular monolith for the completed non-audio scope, but
  the repository is not globally a best-practice modular monolith until the
  separately authorized Calls tranche removes all 29 retained findings.

## Explicit deferral

Only Calls/audio remains: Calls persistence associations and owner reach-through,
incoming Calls edges, the Calls-driven business SCC, the audio presenter schema
input, and Calls-specific clauses in `Authorization.Database`. No non-audio
fingerprint may be added to this deferral.

## Validation

- Exact 32-to-29 reviewed baseline transition from canonical SHA-256
  `9190df9731fc781d1154e9e9d6ec1b27f7557a60cac6afc582b8d7d6f0ceb4d6`.
- Mutation tests for technical-interface caller, exact operation use,
  undeclared operations, non-empty contracts, behavior, implementation,
  binding, and transaction drift.
- Mutation tests for hidden adapter projectors, mixed Calls/non-audio cycles,
  and protected-rule additions disguised as reviewed baseline transitions.
- Deterministic baseline/report parity and paired immutable-base baseline and
  manifest comparison.
- Formatter, warnings-as-errors compilation, focused and full tests, and both
  xref cycle gates.
