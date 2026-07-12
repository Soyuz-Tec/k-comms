# C4 Level 2 — Container View

```mermaid
flowchart TB
    Client[Web Product\nUser + Tenant Admin + Operations]
    Edge[Elixir Edge/API Runtime\nPhoenix HTTP + Channels]
    Worker[Elixir Worker Runtime\nOban + Domain Workers]
    Admin[Administrative Runtime\nMigrations + Scheduled Work]
    DB[(PostgreSQL)]
    Obj[(Object Storage)]
    Search[(Search Projection)]
    Obs[Observability Platform]
    Providers[Push / Email / Webhook Providers]

    Client <-->|HTTPS / WebSocket| Edge
    Edge --> DB
    Edge --> Obj
    Edge --> Obs
    Edge <-->|PubSub| Edge
    Worker --> DB
    Worker --> Obj
    Worker --> Search
    Worker --> Providers
    Worker --> Obs
    Admin --> DB
    Admin --> Obs
```

## Container responsibilities

| Container | Owns | Must not own |
|---|---|---|
| Edge/API | Authentication adapters, request validation, socket lifecycle, command dispatch | Durable state only in process memory |
| Worker | Retryable side effects and derived projections | User-facing synchronous acceptance path |
| Administrative | Controlled migrations and scheduled maintenance | Bypassing domain authorization for business changes |
| PostgreSQL | Authoritative transactional state | Large binary attachments |
| Object storage | Binary objects and variants | Membership or authorization truth |
| Search | Query-optimized derived content | Canonical message state |

The web product is one build with separate `/app`, `/admin`, and `/ops` route
and authorization boundaries. Operations APIs expose health and control state,
not routine tenant message content. Native desktop or mobile clients may reuse
the same public REST and realtime contracts later.
