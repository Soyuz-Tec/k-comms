# Performance Budgets

| Path | Proposed budget | Measurement boundary |
|---|---:|---|
| HTTP authentication | p95 150 ms | Edge receipt to response |
| Message acceptance | p95 250 ms; p99 750 ms | Command receipt to durable acknowledgment |
| Commit-to-live event | p95 500 ms | Commit timestamp to client receipt in-region |
| Cursor replay page | p95 500 ms | Request to page response under nominal load |
| Conversation join | p95 750 ms | Join request through authorization and initial sync |
| Background notification | 95% within 30 seconds | Commit to provider acceptance |

These values are placeholders and require product approval, network assumptions, and benchmark evidence.
