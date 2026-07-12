# Data Retention and Deletion

## Required policy dimensions

- Tenant-default retention period
- Conversation-specific override
- Legal hold
- User account deletion
- Tenant termination
- Attachment and generated-variant retention
- Audit-record retention
- Backup expiration and deletion lag
- Search-index and cache removal

## Deletion workflow

1. Validate authority and legal-hold state.
2. Record an auditable deletion request.
3. Remove or tombstone authoritative rows according to policy.
4. Enqueue deletion for object storage and derived projections.
5. Reconcile completion across systems.
6. Produce evidence without retaining deleted content.

Deletion semantics must be defined before selecting partitioning and archival strategies.
