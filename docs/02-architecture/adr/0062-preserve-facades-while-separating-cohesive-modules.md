# ADR-0062: Preserve public facades while separating cohesive implementation modules

- **Status:** Accepted
- **Date:** 2026-07-30
- **Owners:** Architecture and application engineering
- **Related requirements:** ADR-0001, ADR-0013, ADR-0025, ADR-0028,
  ADR-0042, ADR-0043, ADR-0049, ADR-0052

## Context

Several K-Comms source files remained large after the modular-monolith boundary
work. Their size alone was not a reason to split them. The relevant problem was
that some files combined independently testable responsibilities:

- browser call presentation, REST control, and LiveKit media ownership;
- guest session lifecycle, conversion, and input validation;
- push registration, delivery materialization, revocation, encryption, and
  validation;
- tenant lifecycle commands, settings commands, policy queries, and audit
  queries;
- service-account management and request authentication;
- browser session transport and domain API methods;
- chat navigation, composer state, thread identity resolution, attachment
  lifecycle, and guest viewport behavior.

Changing public context APIs or OTP ownership at the same time would widen the
refactor and risk transaction boundaries, message ordering, process ownership,
and caller compatibility.

## Decision

Keep the established public modules and hooks as compatibility facades. Move
cohesive implementation responsibilities behind them as follows:

| Stable facade or orchestrator | Extracted responsibility modules |
|---|---|
| `CommsCore.Accounts.GuestIdentities` | `SessionLifecycle`, `Conversion`, `Validation` |
| `CommsCore.Notifications.PushSubscriptions` | `Registration`, `DeliveryMaterializer`, `Lifecycle`, `Validation`, `Ciphertext` |
| `CommsCore.Administration` | `TenantLifecycle`, `SettingsCommands`, `PolicyQueries`, `AuditQueries` |
| `CommsCore.ServiceAccounts` | `ServiceAccounts.Authentication` |
| `ApiClient` | `MemberSessionTransport` |
| `useCallSession` | `useCallPresentationState`, `useCallControlPlane`, `useCallMediaSession` |
| `ChatPage` | `useChatNavigation`, `useChatComposer`, `ConversationPane` |
| `ThreadDrawer` | `useThreadSenderIdentities`, `useThreadAttachments`, `useThreadComposer` |
| `GuestShell` | `GuestRoomMenu`, `GuestMessageViewport`, `useGuestConversion`, `useGuestMessageViewport`, `useMobileRoomLayout` |

The facade APIs remain unchanged. The extraction does not add a process,
supervisor, DynamicSupervisor, registry, mailbox, or state owner. Existing
database transactions stay in the modules that own the complete atomic
operation; helper modules do not introduce nested transactions.

`CommsCore.AudioCalls.Lifecycle` remains intact. Its lifecycle functions are
large, but they form one transaction and ordering boundary for provider room
coordination, participant authorization, audit/outbox writes, expiry work, and
revocation. Splitting start, join, end, and expiry into independently callable
modules would reduce file size while weakening the visible invariant boundary.
Further change there requires evidence of a new process, transaction, or fault
isolation boundary.

Large tests are split only where setup and assertions cover distinct behavior.
Guest admission, security, conversion, messaging, calls, and identity coverage
remain separate ExUnit modules. Thread tests separate composer/attachment/race
behavior from sender-identity/feed isolation. Mobile browser tests separate
navigation/onboarding from call layout while sharing deterministic fixtures.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Rename or replace public contexts | Cleaner new API names | Breaks callers and widens migration | Compatibility has greater value than cosmetic purity |
| Introduce new GenServers for each responsibility | Runtime isolation | Adds state, mailboxes, ordering, and restart semantics | No independent state ownership or failure boundary was demonstrated |
| Split every large file | Smaller line counts | Fragmentation and hidden coupling | Size is a signal, not a design boundary |
| Leave all files unchanged | No short-term migration risk | Preserves difficult test and ownership seams | Targeted extractions have clear cohesion and testability benefits |

## Consequences

### Positive

- Domain and browser responsibilities can be tested independently.
- Public APIs and caller behavior remain stable.
- Side-effectful session/media/transport ownership is explicit.
- Future changes have smaller review surfaces without altering runtime
  topology.

### Negative and accepted trade-offs

- Facades add a small delegation layer.
- Some state remains deliberately orchestrated by one hook because splitting
  it into processes would change ordering guarantees.
- Shared test-support modules become internal test dependencies and must stay
  behavior-free.

### Operational consequences

There is no supervision-tree or deployment-topology change. The release must
still pass compilation, static architecture checks, unit/integration/
concurrency tests, web build and browser E2E, immutable image qualification,
and same-digest staging-to-production promotion.

### Security and privacy consequences

Credential parsing and constant-time secret comparison remain private to the
service-account authentication boundary. Guest scope checks, encrypted push
subscription material, tenant authorization, and media-generation fencing are
preserved. No new public data projection is introduced.

## Validation

- Compile Elixir with warnings as errors and run formatting and architecture
  validation.
- Run focused tests for every extracted facade and both new test suites.
- Run the complete umbrella and web test suites, including concurrency and
  failure/recovery coverage.
- Run browser E2E for both mobile suites.
- Build and qualify one immutable image, then promote the exact digest through
  the protected staging and production workflow.

## Revisit triggers

- A responsibility obtains independent durable state or scaling needs.
- A new GenServer mailbox or supervision boundary is required for fault
  isolation.
- Call lifecycle operations can no longer share one atomic transaction and
  ordering boundary.
- A compatibility facade becomes unused by all supported callers.
