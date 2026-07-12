# Database Schema Draft

**Status:** Conceptual

## Core tables

```text
tenants
users
identities
devices
sessions

conversations
conversation_members
conversation_roles
conversation_sequences

messages
message_revisions
message_reactions
message_mentions
read_cursors

attachments
attachment_variants

notification_preferences
webhook_endpoints
webhook_deliveries

outbox_events
background_jobs
audit_events
retention_policies
```

## Required key patterns

```sql
-- Idempotent sender retry
UNIQUE (tenant_id, sender_device_id, client_message_id)

-- Canonical order within a conversation
UNIQUE (conversation_id, conversation_sequence)

-- One membership per user per conversation
UNIQUE (conversation_id, user_id)
```

## Indexing principles

- Lead tenant-scoped queries with `tenant_id` where useful for isolation and locality.
- Index synchronization by `(conversation_id, conversation_sequence)`.
- Index user inbox queries by membership/user and last activity.
- Keep partial indexes for active sessions, pending jobs, and live webhook deliveries.
- Avoid indexing large message bodies unless required by the selected search approach.

## Partitioning triggers

Evaluate message-table partitioning when one or more are true:

- Vacuum or maintenance windows threaten SLOs.
- Index working sets no longer fit expected memory budgets.
- Retention deletion requires large, frequent row-by-row operations.
- A tenant or time range must be isolated for residency or lifecycle reasons.

## Migration requirements

- Use expand-and-contract changes.
- Set lock-time and statement-time budgets.
- Backfill in bounded batches with resumable progress.
- Rehearse against production-scale staging data.
- Do not make a release depend on a long blocking migration.
