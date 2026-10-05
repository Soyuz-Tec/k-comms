# ADR-0091: Durable rich content and authorized unified retrieval

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Collaboration, ConversationContent, Web
- **Related decisions:** ADR-0027, ADR-0069, ADR-0075, ADR-0077, ADR-0083, ADR-0086

## Context

The full UC roadmap requires a board gallery, durable images, named versions,
export, ranked cross-surface retrieval, saved messages and synchronized drafts.
Existing board snapshots are replay acceleration, not user-restorable versions.
Inline browser image bytes cannot become trusted persistent assets. Optional
personal-drive storage remains outside this product decision.

## Decision

Collaboration owns board titles, named checkpoints, and durable asset references.
Gallery reads recheck active conversation membership. Managers rename using a
separate optimistic library version and restore using the exact scene sequence.
Checkpoints materialize the bounded current generation and restore by appending
ordinary clear/update operations in one transaction; no history is overwritten.
There are at most 100 named checkpoints and 100 image references per board.
User erasure discards all checkpoints on affected boards as well as snapshots,
because a checkpoint can include another author's subsequently erased text.
Checkpoints retain an internal set of scene authors, including the inherited
authors of earlier restores. Restored operations copy that server-owned lineage
from the locked checkpoint; browser payloads cannot provide it. User erasure
neutralizes whole restored update chunks whose lineage includes the erased
author, retaining unrelated ordinary operations by other users. This conservative
rule also applies to checkpoints of restored scenes, preventing a second restore
from hiding the original author behind a manager's identity.

Images are existing message-owned, scan-clean, version-pinned PNG/JPEG/WebP/GIF
attachments of at most 10 MiB. The interface explicitly shares the image with
the conversation before registering it on the board. Collaboration owns
`BoardAssetPort`; the dedicated ConversationContent façade
`Messaging.BoardAssets` implements its transaction-only claim and independent
read, returning a typed receipt. The configured binding lives in the port.
The adapter uses current source verification without source row locks: taking
source locks after a board lock would invert governance erasure's lock order.
The durable record is a reference and every later byte read must revalidate;
creating that reference never grants independent access to erased content.
The adapter checks the exact tenant, conversation, active source message, owner
at initial claim, scan verdict and immutable storage identity. Each future read,
scene append, restore and export rechecks that source. The board persists only
asset UUID references. No SVG, inline data URI, embedded URL, or external storage
key supplied by a browser enters the durable scene as an image source.

The browser fetches only an approved version-pinned download URL, verifies the
raster magic and declared byte size, and gives the decoded image to the canvas
in memory. Authorized scene export fetches approved image bytes at export time;
the downloaded file can contain those bytes, as any authorized file download
can. A previously downloaded file cannot be recalled by later access changes. An
already-issued signed download remains usable until its reported expiry;
subsequent authorization requests fail after source access or safety changes.

ConversationContent owns user-private saved message references and drafts.
Saved lists hydrate only active source messages in currently authorized
conversations, and never create a second content copy. Each user has at most
500 saved messages and 500 draft scopes. Main and thread drafts have explicit
optimistic versions; empty bodies are durable tombstones. A stale device cannot
silently overwrite or recreate a cleared draft. The interface preserves local
text on conflict and offers the two actual versions. Body text expires from
retrieval after 30 days; an hourly, bounded, worker-authorized sweep physically
scrubs expired text and increments its tombstone version. Governance erasure
also removes the owner's drafts inside the erasure transaction.

Attachment-only messages persist a bounded attachment count and claim every
scan-approved attachment inside the same message transaction. Empty messages
without an approved attachment still fail. Existing thread root, tenant,
membership, attachment ownership, idempotency and outbox rules apply. Rich text
uses a small formatting dialect rendered as React text elements; raw HTML is
never interpreted and no arbitrary image or script markup is supported.

Web composes unified search using public owner façades for messages, files,
board titles/text, meetings and available artifacts. It never reads a foreign
schema. Candidate ranking combines literal title/phrase and token relevance,
then time and stable identity. Facets and pagination describe this bounded
candidate union, with explicit source-limit flags and a maximum two-year meeting
window. A cursor is bound to the tenant, user and query filters. This does not
claim an exhaustive global index or unconstrained relevance ranking.

## Consequences

Additive migrations retain the one-owner-per-migration rule: Collaboration
library storage and restore lineage, and ConversationContent personal composition storage. The
architecture registry gains the consumer-owned port, dedicated adapter façade,
typed receipts and new public operations through the reviewed API transition.
Existing content erasure and storage scanning remain authoritative. No drive
model, public asset upload, provider credential, or architecture exemption is
introduced. The older runtime can still display attachment-only messages as
attachments; reverse schema migration materializes a plain attachment label
before restoring the older body constraint.
Reversing the lineage migration neutralizes dependent restore payloads and drops
their snapshots and checkpoints before removing metadata; rollback deliberately
loses that restored content so the older runtime cannot expose it after erasure.

## Validation

Require negative controls for source deletion/moderation, foreign tenants,
invalid sessions, unscanned and unbound images, checkpoint erasure, stale scene
and draft versions, attachment-only rollback, cursor scope and escaped rich
text. Browser journeys exercise gallery, checkpoints, export, saved items,
conflict recovery and ranked retrieval. Physical pen/touch accessibility and
production load and retention execution require separate runtime evidence.
