# Glossary

- **Acknowledged message:** A message for which the server has returned a successful durable acceptance response.
- **Canonical sequence:** Server-assigned monotonically increasing order within a conversation.
- **Derived projection:** Rebuildable representation such as search, unread counts, or analytics.
- **Edge/API node:** Runtime role handling HTTP and WebSocket connections.
- **Ephemeral event:** Event safe to lose, duplicate, or reorder, such as typing state.
- **Idempotency key:** Client-stable key used to make retries return one canonical result.
- **RPO:** Maximum acceptable data loss measured in time or transactions.
- **RTO:** Target time to restore the capability after a qualifying failure.
- **SLI/SLO:** Measured service indicator and its reliability objective.
- **Tenant context:** Authenticated organization boundary attached to every protected operation.
