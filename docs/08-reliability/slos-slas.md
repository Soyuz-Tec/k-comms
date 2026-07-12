# Service-Level Objectives

**Status:** Proposed targets requiring business and benchmark approval

| Service capability | SLI | Proposed objective | Exclusions must be explicit |
|---|---|---:|---|
| Core message acceptance availability | Successful authorized message commands / valid attempts | 99.95% monthly | Planned windows only if contract permits |
| Message acceptance latency | Time from edge receipt to durable acknowledgment | 95% under 250 ms; 99% under 750 ms | Clearly defined oversized/abusive requests |
| Live delivery latency | Commit to connected in-region client receipt | 95% under 500 ms | Client/network unavailable |
| History synchronization | Successful sync pages / valid requests | 99.95% monthly | Client cancellation |
| Attachment readiness | Eligible uploads scanned and ready | 95% within target by size tier | Quarantined/malicious files |
| Notification timeliness | Notification intents accepted by provider | 95% within 30 seconds | Provider outage treated separately or included by contract |

## Durability objective

A message for which the server returned a successful durable acknowledgment must remain recoverable after loss of an application node. The database replication and regional-failure guarantees require a separate approved RPO statement.

## SLI implementation

Each SLI must define numerator, denominator, data source, aggregation window, late data behavior, tenant segmentation, and alert thresholds.
