# Disaster Recovery

## Decisions required

- Approved recovery point objective (RPO)
- Approved recovery time objective (RTO)
- Regional failure scope
- Manual versus automated failover authority
- DNS/traffic switching mechanism
- Database promotion and split-brain prevention
- Object-storage replication and key availability

## Recovery sequence

1. Declare incident and freeze conflicting writes.
2. Establish the most recent safe database recovery point.
3. Promote or restore the recovery database.
4. Validate schema, key services, object access, and tenant isolation.
5. Start application roles in controlled order.
6. Run synthetic send/read/sync workflows.
7. Shift traffic gradually.
8. Reconcile jobs, webhooks, notifications, and search projections.
9. Record achieved RPO/RTO and follow-up actions.

Conduct scheduled exercises and one unannounced game day before launch approval.
