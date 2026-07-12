# Runbook: WebSocket Saturation

**Trigger:** Connection, mailbox, scheduler, or network saturation on edge nodes.

## Immediate checks

- Confirm alert validity and affected regions/tenants/capabilities.
- Check recent deploys and configuration changes.
- Inspect SLI burn rate, saturation, and dependency health.
- Assign incident commander and communications owner.

## Stabilization actions

1. Preserve message durability and authorization.
2. Apply the documented safe degradation control.
3. Reduce load or concurrency without dropping durable work.
4. Verify recovery with synthetic workflows.

## Escalation

Escalate to the owning team, SRE, security if data exposure is possible, and database/provider support when applicable.

## Recovery validation

- Message send, acknowledgment, live delivery, and replay work.
- Queue age trends downward.
- No unexplained data or authorization gap exists.
- Temporary controls are tracked for removal.

## After action

Record timeline, customer impact, SLO consumption, root/contributing causes, and corrective actions. Update this runbook after use.
