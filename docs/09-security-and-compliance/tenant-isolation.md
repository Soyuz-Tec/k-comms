# Tenant Isolation

## Layers

1. Authenticated tenant context.
2. Application policy checks.
3. Tenant-scoped repository/query functions.
4. Composite database keys and constraints.
5. Optional PostgreSQL row-level security as defense in depth.
6. Tenant-scoped storage prefixes and signed-object policy.
7. Per-tenant quotas, metrics, and audit.

## Verification

- Property-based cross-tenant ID substitution tests.
- API and socket negative tests for every resource type.
- Background-job tenant-context tests.
- Search permission-change reconciliation tests.
- Administrative access audit review.
