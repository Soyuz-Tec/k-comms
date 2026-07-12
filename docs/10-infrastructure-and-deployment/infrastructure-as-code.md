# Infrastructure-as-Code Design

## Proposed module boundaries

```text
infra/
  modules/
    network/
    edge-ingress/
    runtime-cluster/
    postgres/
    object-storage/
    search/
    observability/
    secrets-and-keys/
    disaster-recovery/
  environments/
    development/
    staging/
    production/
    disaster-recovery/
  policy/
  tests/
```

## Requirements

- Remote state with locking and restricted access.
- Versioned modules and provider constraints.
- Policy-as-code for public exposure, encryption, backups, and tagging.
- Plan review before apply.
- Drift detection.
- Separate deploy identities by environment.
- Automated checks that staging and production use equivalent module paths.
