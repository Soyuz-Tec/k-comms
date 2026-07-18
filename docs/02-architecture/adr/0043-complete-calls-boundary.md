# ADR-0043: Complete the Calls boundary and retire the authorization kernel

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0001, ADR-0025, ADR-0035, ADR-0042

## Context

ADR-0042 left one explicitly bounded tranche: 29 Calls findings comprising one
released-adapter schema leak, one business-context cycle, nineteen foreign
schema imports, and eight undeclared context edges. Calls persistence contained
Ecto associations to IdentityAccess, TenantAdministration, and Conversations.
Those contexts also invoked `CommsCore.AudioCalls` directly for synchronous
revocation. The temporary `CommsCore.Authorization` kernel queried persistence
owned by four contexts and kept the compiled business graph cyclic.

The behavior is intentionally synchronous. Session, device, user, tenant-media,
membership, and conversation revocation must contribute Calls admission
revocation and durable participant-eviction work to the transaction already
owned by the initiating context. Replacing those operations with eventual
events would weaken the existing security and rollback invariant.

## Decision

Calls is the sole owner of `audio_calls` and `audio_call_participants`.
`CommsCore.AudioCalls.AudioCall` and
`CommsCore.AudioCalls.AudioCallParticipant` are internal persistence schemas.
Their references to foreign business objects are scalar identifiers; the
intra-owner participant-to-call association may remain internal.

`CommsCore.AudioCalls` is the Calls facade. Released adapters receive only these
Ecto-free Calls contracts:

- `CommsCore.AudioCalls.CallView`
- `CommsCore.AudioCalls.CredentialRequest`
- `CommsCore.AudioCalls.EvictionClaim`
- `CommsCore.AudioCalls.EvictionProgress`
- `CommsCore.AudioCalls.ProviderCall`

Calls authorization is implemented by the owner-internal
`CommsCore.AudioCalls.AuthorizationPolicy`. It consumes stable projections from
IdentityAccess, TenantAdministration, and Conversations:
`AccessGrant`, `CallPolicy`, `CallConversation`, and `CallMembership`. The
central `CommsCore.Authorization` namespace and its
`:authorization_adapter` runtime binding are retired tombstones and may not be
restored.

Inbound lifecycle work uses three consumer-owned, transaction-required ports:

| Consumer | Port operation | Calls implementation |
|---|---|---|
| IdentityAccess | `Accounts.CallLifecyclePort.revoke_identity_access/1` | `AudioCalls` |
| TenantAdministration | `Administration.CallLifecyclePort.revoke_tenant_media/1` | `AudioCalls` |
| Conversations | `Conversations.CallLifecyclePort.revoke_conversation_access/1` | `AudioCalls` |

Each consumer owns its command and receipt contracts. The port validates the
command, exact configured adapter, typed result, and active Repo transaction.
Calls implements the behavior and contributes its writes, eviction jobs, and
outbox effects to that same transaction.

The boundary gate is promoted one way from
`strict_with_explicit_deferrals` to `strict`. Strict mode requires a zero
analyzer result, an empty baseline, no temporary violations, no baseline
adoption, and no deferral policy. The final reviewed transition removes exactly
the 29 ADR-0042 fingerprints from canonical baseline SHA-256
`90a52be007eecd64627b35212ec3da314e742f232373a6e954523116f4fa1da6`.

## Consequences

- Calls persistence is private to Calls; web, worker, and integration adapters
  pattern-match only stable Calls contracts.
- IdentityAccess, TenantAdministration, and Conversations no longer compile
  against Calls. Their runtime control flow reaches Calls only through exact
  consumer-owned ports.
- Compiled and runtime business-context graphs are acyclic. Their diagnostic
  union can contain an SCC where a consumer-to-provider runtime edge opposes
  the provider-to-consumer compile edge required to implement a
  consumer-owned port. That exact validated inversion is accepted topology,
  not boundary debt.
- The database schema, REST and WebSocket payloads, LiveKit provider boundary,
  transactional outbox, expiry behavior, and revocation atomicity are
  unchanged. Calls continues publishing canonical `call.started.v1` and
  `call.ended.v1` plus the existing `audio_call.started.v1` and
  `audio_call.ended.v1` compatibility aliases.
- Retired module namespaces and runtime bindings are monotonic control-plane
  tombstones.

## Alternatives rejected

- Keep a shared authorization kernel: it centralizes policy while importing
  four owners' persistence and recreates the cycle.
- Permit direct reverse Calls facade calls: this restores compiled coupling and
  bypasses consumer transaction contracts.
- Pass callbacks or untyped maps: these make caller, operation, and result
  surfaces difficult to validate.
- Replace revocation with eventual events: this permits the initiating state
  change to commit before Calls capability is revoked.
- Extract a Calls service: there is no independent-deployment requirement, and
  a distributed transaction would weaken the current invariant.

## Validation

- Architecture analysis returns zero violations before baseline regeneration.
- The final baseline is empty and the generated report matches the repository.
- Manifest comparison permits the one-way strict promotion and rejects later
  downgrade or removal of retired tombstones.
- Regression tests cover exact port callers, operations, bindings, contracts,
  transaction guards, adapter surfaces, schema containment, and retired
  namespace/binding resurrection.
- Formatter, warnings-as-errors compilation, focused Calls tests, full umbrella
  tests, and both `comms_core` xref cycle gates must pass before merge.
