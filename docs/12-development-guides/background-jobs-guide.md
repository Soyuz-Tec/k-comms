# Background Jobs Guide

- Insert required jobs in the same transaction as the business change where possible.
- Include stable idempotency/deduplication keys.
- Categorize queues by criticality and resource profile.
- Bound attempts, timeouts, concurrency, and backoff.
- Make jobs safe to retry after partial provider interaction.
- Store delivery state for externally visible effects.
- Define terminal failure, alerting, and replay procedures.
