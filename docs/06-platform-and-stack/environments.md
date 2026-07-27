# Environment Model

| Environment | Purpose | Data | Availability expectation |
|---|---|---|---|
| Development (local Windows workspace) | Developer feedback and component integration | Synthetic | Best effort |
| CI | Automated tests, linting, contract/schema validation | Ephemeral synthetic | Per pipeline |
| Staging | Production-like rehearsal and load/failure testing | Synthetic production-scale | High enough for release gates |
| Production | Customer workload | Real | Approved SLO |
| DR | Recovery target | Replicated/backed-up production state | Per RTO/RPO |

The canonical managed-workstation path is defined in
`docs/10-infrastructure-and-deployment/environments/development.md`. No shared
development VM is currently provisioned.

Staging must match production topology, security boundaries, deployment method, and managed-service classes closely enough for release and recovery rehearsals to be meaningful.
