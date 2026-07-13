# Application Repository Layout

```text
communication-platform/
  apps/
    comms_core/           # Domain rules and application commands
    comms_web/            # Phoenix HTTP, sockets, channels, admin UI
    comms_workers/        # Jobs, projections, notifications, retention
    comms_integrations/   # IdP, push, email, webhooks, storage adapters
    comms_observability/  # Telemetry conventions and exporters
    comms_test_support/   # Factories, simulators, failure tools
  config/
  priv/
    repo/migrations/
    repo/seeds/
  test/
  contracts/
    openapi/
    asyncapi/
    json-schema/
  ops/
    containers/
    kubernetes-or-runtime/
    dashboards/
    alerts/
  scripts/
  mix.exs
  mix.lock
```

## Dependency direction

The exact allowed application edges and persistence exceptions are defined in
the [architecture overview](../02-architecture/architecture-overview.md#application-module-boundaries).
In summary, web and worker adapters call inward to `comms_core`; integrations
implement external provider concerns; observability remains a leaf shared
primitive. `comms_core` must not import or name web, worker, integration, or
observability adapters.

Domain code must not import Phoenix controllers, socket structs, provider SDK
models, or infrastructure-specific configuration. Released adapter code must
not access `CommsCore.Repo`; health, metrics, and other operational reads use
narrowly named core APIs. Run `python scripts/validate_architecture.py` locally;
CI runs the validator and its regression suite for every pull request.
