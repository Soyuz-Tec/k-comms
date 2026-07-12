# Documentation Map

This map connects the twelve deployable-engineering-plan outputs to their primary artifacts.

| # | Required output | Primary location | Approval evidence |
|---:|---|---|---|
| 1 | C4 architecture diagrams | `docs/02-architecture/c4/` and `docs/02-architecture/diagrams/` | Architecture review record |
| 2 | Architecture decision records | `docs/02-architecture/adr/` | Approved ADRs |
| 3 | Domain model and database schema | `docs/03-domain-and-data/` | Data-model review and migration prototype |
| 4 | Versioned REST and WebSocket contracts | `docs/04-interfaces/` | Contract tests and schema validation |
| 5 | Message-delivery protocol | `docs/05-message-delivery/` | Model review, integration tests, failure tests |
| 6 | Capacity model | `docs/07-capacity-and-performance/` | Load-test results and sizing sign-off |
| 7 | SLO document | `docs/08-reliability/` | SRE/product approval and monitoring implementation |
| 8 | Threat model and security matrix | `docs/09-security-and-compliance/` | Security review and control evidence |
| 9 | Infrastructure-as-code design | `docs/10-infrastructure-and-deployment/` | Staging environment created from code |
| 10 | Testing strategy | `docs/11-testing-and-quality/` | Test plan, CI gates, coverage evidence |
| 11 | Migration and release strategy | `docs/10-infrastructure-and-deployment/release-strategy.md` | Rehearsed deployment and rollback |
| 12 | Cost, staffing, and phased plan | `docs/13-delivery-plan/` | Executive funding and staffing approval |

## Supporting collections

- Governance, assumptions, risks, and traceability: `docs/00-governance/`
- Product context and requirements: `docs/01-product-and-scope/`
- Software stack and environment standards: `docs/06-platform-and-stack/`
- Developer onboarding and implementation guides: `docs/12-development-guides/`
- Operational handbook and support model: `docs/14-operations/`
- Reference skeletons for future repositories: `skeletons/`
- Reusable document templates: `templates/`

## Definition of plan-ready

The engineering plan is ready for implementation when:

- All critical assumptions are resolved or explicitly bounded.
- Critical ADRs are approved.
- Interfaces have versioned schemas and representative examples.
- Capacity calculations are tied to tested benchmarks.
- SLOs have measurable service-level indicators.
- Threats have owners and planned mitigations.
- Staging can be provisioned from infrastructure code.
- The first two implementation increments have refined work packages and acceptance tests.
