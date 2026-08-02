# ADR-0070: Accept whole-element whiteboard merge until the editor engine changes

- **Status:** Accepted
- **Date:** 2026-08-02
- **Owners:** Collaboration, Web
- **Reviewers:** Architecture, Release and Quality
- **Related requirements:** FR-COL-001, FR-SYNC-001, ADR-0063, ADR-0069

## Context

Concurrent whiteboard edits are resolved per *element*. `sceneModel.ts` mirrors
Excalidraw's own rule: the higher `version` wins, and equal versions are settled
by the lower `versionNonce`. The server reproduces it in `Snapshots` so a
snapshot cannot disagree with a replay.

The rule loses work. Two collaborators editing the same shape at the same
version contend even when they touched unrelated attributes: one drags a
rectangle while the other recolours it, one whole element wins, and the other
edit disappears with no conflict signal. The user finds their change undone and
usually cannot say when.

A review recommended merging per property for the non-geometric subset — stroke
colour, fill, opacity, font size — keeping whole-element resolution for
geometry. On investigation that recommendation is not implementable as stated.

**Excalidraw carries one version per element, not per property.** Given two
concurrent states of a shape, there is no way to know which attributes each side
*changed* — only which differ. Merging them means choosing values by a rule
neither user's client applied, producing an element state that never existed on
any replica.

A correct merge needs a common ancestor. Operations do carry `base_sequence`,
but it exists to fence the clear generation, and reconstructing the authoring
client's scene at that point would mean replaying history per element on every
merge. That is not a refinement of the current model; it is a different one —
per-property stamps and a convergent register per attribute, which is what a
purpose-built engine provides and what an Excalidraw adapter cannot retrofit.

## Decision

Whole-element last-writer-wins is accepted as a known, recorded limitation of
the Excalidraw adapter. No heuristic property merge is introduced.

The rule stays byte-identical in three places — the client projection, the
server snapshot projection, and Excalidraw's own reconciliation — because a
snapshot that disagreed with a replay would be a worse failure than the one this
records.

The remedy is engine replacement, not adapter surgery. ADR-0063 already keeps
Excalidraw replaceable for exactly this class of reason.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Heuristic property merge without a base | Some concurrent edits survive | Produces element states no client authored, silently and unpredictably | Trades a visible loss for an invisible corruption |
| Three-way merge from a reconstructed ancestor | Correct | Requires replaying history per element on every merge, and a per-element base the log does not record | Cost and complexity of a CRDT without its guarantees |
| Per-property stamps inside the adapter | Correct and convergent | Excalidraw neither produces nor preserves them; every element would need a parallel metadata document | This is engine replacement wearing an adapter's clothes |
| Surface a conflict warning to the user | Loss stops being silent | Cannot distinguish a lost edit from an ordinary overwrite without the same missing ancestor | Would fire constantly on normal drawing |
| Serialise edits per element server-side | No concurrent loss | Turns collaborative drawing into a queue; latency under simultaneous editing | Defeats the feature |

## Consequences

### Positive

- The merge rule stays identical across client, server snapshot, and SDK. Any
  divergence there would break replay equivalence, which is a worse defect.
- The limitation is recorded rather than rediscovered by a future reviewer.

### Negative and accepted trade-offs

- **Concurrent edits to different attributes of one shape still lose one of
  them, silently.** This is the accepted cost.
- Users have no signal when it happens.
- Impact scales with how often two people edit the same shape simultaneously,
  which is highest on the public instant-room front door.

### Operational consequences

None. No code changes.

## Validation

- Existing client tests continue to prove the equal-version, lower-nonce rule.
- ADR-0069's snapshot equivalence tests prove the server reproduces it exactly.
- `excalidrawConformance.test.ts` fails at typecheck if the SDK changes the
  fields the rule depends on.

## Revisit triggers

- Lost concurrent edits are reported by users or observed in support, which
  would move this from theoretical to measured.
- A purpose-built engine with per-property convergence becomes available to
  replace the Excalidraw adapter under ADR-0063's replaceability clause.
- Excalidraw gains per-property versioning, which would make the original
  recommendation implementable as stated.
