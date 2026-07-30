# Test Strategy

## Test portfolio

| Layer | Purpose | Examples |
|---|---|---|
| Unit | Pure domain rules and validation | Permission, retention, normalization |
| Property-based | Invariants over broad input space | Idempotency, cursor monotonicity, tenant separation |
| Integration | Database, jobs, storage, and PubSub behavior | Transaction rollback, retries, attachment states |
| Contract | API/event compatibility | OpenAPI/AsyncAPI schema checks |
| End-to-end | User-visible journeys | Authenticate, send, receive, reconnect, search, direct/group audio-video, screen sharing |
| Performance | Capacity and latency | Hot rooms, fan-out, reconnect storms, representative group video and forced-TURN bandwidth |
| Chaos/failure | Recovery and containment | Node kill, database failover, provider outage |
| Security | Abuse and trust boundaries | ID/media-kind substitution, overbroad media grants, SSRF, token/session tests |
| Recovery | Backup and DR | Restore, promotion, projection rebuild |
| Usability | Representative task success and comprehension | Invitation-to-first-message, daily collaboration, safe administration, operations triage |
| Accessibility | WCAG and assistive-technology behavior | Keyboard, screen reader, reflow, high contrast, route and dialog focus |

## CI policy

Fast deterministic tests run on every change. Expensive load, soak, chaos, and recovery suites run on scheduled or release-gate pipelines with versioned environments and retained evidence.

### ExUnit lanes and tags

The unfiltered suite remains the release authority. Tags are selectors for
focused feedback and investigation; adding a tag never removes a test from the
default full regression.

| Tag | Use |
|---|---|
| `:unit` | Pure transformations, policies, validation, and deterministic code without an integration boundary |
| `:integration` | PostgreSQL, PubSub, Oban, Phoenix, object storage, or another owned adapter boundary |
| `:concurrency` | Explicit interleavings, lock ordering, mailbox ordering, races, or revocation behavior |
| `:external` | A real provider or service outside the normal local test stack |
| `:slow` | A test that is intentionally expensive enough to exclude during rapid local iteration |
| Feature tags | A stable domain selector such as `:call`, `:conversation`, `:messaging`, `:presence`, or `:governance` |

Apply `:unit` or `:integration` at module level when every test has the same
boundary. Apply `:concurrency`, `:external`, and `:slow` only to the relevant
module or test. A concurrency test that uses PostgreSQL should carry both
`:integration` and `:concurrency`. Global application configuration, shared
process names, and external fixtures still determine whether a module must use
`async: false`; a tag does not make unsafe parallel execution safe.

The repository-owned runner provides these lanes:

```text
bash scripts/run_backend_tests.sh full
bash scripts/run_backend_tests.sh unit
bash scripts/run_backend_tests.sh integration
bash scripts/run_backend_tests.sh concurrency
bash scripts/run_backend_tests.sh coverage
```

Containerized developer equivalents are `make test`, `make test-unit`,
`make test-integration`, `make test-concurrency`, and `make test-coverage`.
The direct Mix aliases `mix test.unit`, `mix test.integration`, and
`mix test.concurrency` are available when the local dependencies are already
running.

### Coverage baseline

CI runs the full backend regression once with Elixir's built-in line coverage,
exports the umbrella-child results, and aggregates them with
`mix test.coverage`. The current policy sets the coverage threshold to zero:
the measured percentage is an observable baseline, not a quality claim or an
arbitrary merge threshold. Generated protocol implementations and test-support
modules are excluded so the aggregate describes production modules. Line
coverage does not prove branch, concurrency, failure-recovery, authorization,
or transaction-boundary behavior.

Raise a coverage threshold only through a reviewed change backed by a stable
history of comparable full-suite measurements. Coverage regressions should
first drive inspection of the affected domain and critical paths rather than
mechanical tests written solely to increase a percentage.

Automated accessibility checks are regression gates, not a WCAG conformance
claim. The participant, manual accessibility, scoring, privacy, and pilot
contract is defined in [usability-validation.md](usability-validation.md).
The browser matrix runs automated WCAG A/AA checks against fourteen named
representative states on desktop and mobile plus 320 CSS-pixel reflow, forced
colors, reduced motion, and WCAG text spacing. Manual assistive-technology
assessment remains a separate people-gate receipt.
