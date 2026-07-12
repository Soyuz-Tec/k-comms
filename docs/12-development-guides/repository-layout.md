# Proposed Application Repository Layout

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

`web/workers/integrations -> application/domain -> shared primitives`

Domain code must not import Phoenix controllers, socket structs, provider SDK models, or infrastructure-specific configuration.
