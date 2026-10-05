# ADR-0110: Compose the remaining full-UC owner contracts

- Status: Accepted
- Date: 2026-10-05
- Decision owners: K-Comms architecture and domain engineering

## Context

The remaining UC milestones were developed in isolated branches with separate
owner contracts, migration capabilities and current-authority boundaries. Their
shared release inventories, facade snapshots and governed deletion workflows
must be composed before combined runtime qualification. A passing feature branch
does not establish combined platform or live provider acceptance.

## Decision

Compose only the explicitly reviewed milestones: shared documents, workspace
discovery, delegated calendar synchronization, bounded IVR and queue routing,
existing phone-provider resource administration, native and desktop clients,
background call wake, saved recognition and separately consented quote summaries,
explicit plaintext federation and separate private encrypted rooms.

Each source remains with its existing domain owner. Combine the immutable public
facade inventory and exact technical interface declarations without exposing
foreign schemas or adding generic access. Preserve the boundary baseline and
validator. The single reviewed manifest transition records the exact semantic
additions relative to the frozen Member workflows parent; regenerate that exact
list when the integration source changes. Retire it only after its owner
contracts are protected.

Retain every milestone's forward migration, capability label, rollback hazard,
tenant fingerprint, private configuration boundary and durable provider receipt.
Compose historical repair and pending-deletion obligations together. Completion
requires all applicable owner proofs; one feature cannot erase or substitute
another owner's proof. Preserve current device/session authority, canonical lock
order, original content lineage and shared absolute effect deadlines.

Keep real provider gates closed until their acceptance criteria are satisfied.
Do not convert unknown acknowledgments into repeated native effects, or a local
purge into proof of recipient-key or complete remote-backup erasure. Plaintext
federation cannot admit a private encrypted room. Preserve production performance
budgets and maintained pinned SDKs.

## Qualification

Before release, validate the composed contracts and strict architecture, compile
with warnings as errors and both required Core dependency-cycle gates, execute
meaningful owner and full regressions, run real local browser/HTTP/realtime
journeys, and prove forward migrations, retained-state rollback refusal and
fingerprint coverage. Complete production build, accessibility, performance,
security and immutable artifact gates.

This decision authorizes source composition. It is not a receipt for executed
crypto, native hardware, carrier/calendar/homeserver, staging or production
acceptance. The intentionally offline staging VM remains an external release
prerequisite; independent production approval remains protected.
