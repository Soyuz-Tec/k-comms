# On-call Guide

## Before joining the rotation

On-call engineers need least-privilege access to dashboards, logs/traces,
deployment history, retained release bundles, provider status, runbooks, alert
routing, and the approved escalation roster. Break-glass access is time-bound,
reason-bearing, independently reviewed, and audited.

Each operator must complete synthetic exercises for authentication, send/replay,
queue backlog, notification provider failure, attachment scanning, pod
replacement, rollback/roll-forward, and backup restore before taking primary
call.

Record each exercise in the restricted training/incident system with synthetic
participant code or role, exact environment and release, scenario, start/end
time, commands/actions, stop conditions evaluated, result, reviewer, review
expiry, and evidence URI. Link the aggregate result from readiness gates
`environment.operating_authority` and `people.role_exercises`; never mark the
repository ledger template passed. A validator can prove receipt metadata is
complete, but only the named operations authority can certify an operator.

## Alert contract

Every page includes:

- affected capability and content-blind user impact;
- severity, threshold, current value, and freshness;
- environment, region, release revision, and owning team;
- first diagnostic query or dashboard;
- safe mitigation and explicit stop condition;
- verification, rollback, escalation, and communication steps; and
- versioned runbook link.

Do not page for a condition with no actionable response. Ticket-only or
dashboard-only signals are preferable for non-urgent trends.

## First ten minutes

1. Acknowledge the page and check whether another incident is active.
2. Confirm freshness and user impact from content-blind health, queue, provider,
   error-rate, latency, deployment, and synthetic-journey evidence.
3. Classify tenant scope and security/privacy relevance. Escalate suspected
   isolation, loss, or secret exposure immediately.
4. Check recent deployment/config/provider changes and the relevant runbook.
5. Apply only the bounded safe mitigation. Stop if preconditions do not match.
6. Verify recovery using readiness, synthetics, queue movement, provider state,
   and a synthetic user journey.
7. Open/refresh the incident record with timestamps, evidence links, actions,
   and next update time.

## Safe control boundary

The `/ops` UI is a content-blind read model and bounded control surface. It does
not grant arbitrary Kubernetes, database, object-storage, or provider
credentials. Cluster rollback, restore, migration repair, and break-glass work
stay in the approved release/operations pipeline with retained receipts.

Use the runbooks under `docs/08-reliability/runbooks`. If a runbook lacks user
impact, diagnostic start, mitigation, stop condition, verification, owner, or
escalation, treat that as a readiness defect and do not improvise a destructive
production action.

## Handoff and follow-up

Handoff includes current impact, release, timeline, hypotheses, actions and
results, open risks, next decision, communication status, and evidence links.
Every Sev-1/Sev-2 produces a problem review and tracked corrective actions.
Exercises, contact routes, provider credentials, and runbook links are reviewed
at least quarterly and after material architecture/provider changes.
