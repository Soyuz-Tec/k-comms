# Performance Budgets

| Path | Proposed budget | Measurement boundary |
|---|---:|---|
| HTTP authentication | p95 150 ms | Edge receipt to response |
| Message acceptance | p95 250 ms; p99 750 ms | Command receipt to durable acknowledgment |
| Commit-to-live event | p95 500 ms | Commit timestamp to client receipt in-region |
| Cursor replay page | p95 500 ms | Request to page response under nominal load |
| Conversation join | p95 750 ms | Join request through authorization and initial sync |
| Background notification | 95% within 30 seconds | Commit to provider acceptance |

These are proposed product budgets and still require product approval,
representative network assumptions, and production-like benchmark evidence.
The executable local staging profile uses an intentionally separate p95
message-acceptance regression gate of 750 ms with zero acknowledged-message
loss. Passing that local gate is package qualification evidence only; it does
not approve or prove the 250 ms product target.
