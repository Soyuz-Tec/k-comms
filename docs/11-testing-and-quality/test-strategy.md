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

Automated accessibility checks are regression gates, not a WCAG conformance
claim. The participant, manual accessibility, scoring, privacy, and pilot
contract is defined in [usability-validation.md](usability-validation.md).
The browser matrix runs automated WCAG A/AA checks against fourteen named
representative states on desktop and mobile plus 320 CSS-pixel reflow, forced
colors, reduced motion, and WCAG text spacing. Manual assistive-technology
assessment remains a separate people-gate receipt.
