# ADR-0101: Bounded server-owned shared documents

- **Status:** Accepted
- **Qualification:** Behavioural and independent security qualification pending
- **Date:** 2026-10-05
- **Owner:** Collaboration
- **Related decisions:** ADR-0092, ADR-0093, ADR-0096

Current workspace humans in durable conversations can create and edit plaintext
and Markdown documents using the maintained CodeMirror 6 editor. The server owns
a bounded RGA implementation; CodeMirror is the editor, not a third-party
cryptographic or CRDT assurance claim. Instant rooms, guest identities and
conversation-only accounts are excluded from this durable document lifecycle.

Each insert references an admitted immutable atom ID and creates one atom per
Unicode scalar. Deletes tombstone exact admitted IDs. Parents never change;
server committed sequence orders siblings deterministically. Concurrent edits
converge through server receipts, authenticated sockets and ordered durable
replay. UTF-16 editor offsets are mapped to complete scalar boundaries; unpaired
surrogates and split surrogate edits are rejected. Combining characters remain
individual scalars, while the maintained editor supplies normal input behaviour.
Client authorship, arbitrary graphs and opaque replacement snapshots are never
accepted. Generation mismatches refuse writes. UUID idempotency retains exact
input and actor/device binding; a lost acknowledgement replays the same intent.
Title changes require exact current version CAS. A copy is an owner command
that retains source authorship and creates new atom identity.

The owner retains at most 1,000 document rows per tenant and 40 per conversation, 16,000 visible
scalars / 65,536 content bytes, 32,000 total atoms, 4,000 committed operations,
250 historical authors, 16 MiB of retained operation input/payload/metadata per document,
32 changes per operation, 2,048 inserted scalars and
4,096 deleted IDs per operation. Exhaustion fails closed; it cannot compact
away tombstones, ancestry, author evidence or idempotency. Read-only documents
can be exported or copied through fresh authority. Search returns bounded
summaries; snapshots and replay are separate authenticated operations.

Governance tenant protection is the first retained lock. Identity owns current
quota/tenant/User/Device/Session fences through ContentWriteGrant. Collaboration
then retains its tenant document-capacity prefix before Conversation SHARE and
current membership; document resources are last. Absolute
budgets and current authority are rechecked after waits and before disclosure.
Collaboration consumes its exact ProtectionPort; Governance alone accesses
legal holds and deletion requests. Pending governed erasure denies all document
retrieval, writes, copies, replay and presence for affected authors/conversations.
Socket joins and every send/receive check current retained authority.

Server-derived provenance conservatively unions every original content/title
writer and every copied source author. It cannot be rewritten by a client.
**Governed erasure of any original author removes the entire derived document
and its copies, including every operation and deleted atom's text.** Unrelated
documents survive. Legal holds and unknown lineage prevent completion.
Erased rows retain only content-free generation fences; late or replayed work
cannot recreate the document. The real registered deletion workflow records
shared_document_erasure_version only after the synchronous owner receipt, and
historical completion is repaired under the same writer fences.

Unsent browser edits remain only in the current tab and are not persisted as
plaintext in browser storage. Reconnect obtains fresh socket tickets, replays
committed operations and retries exact unknown acknowledgements. Identity or
document changes clear in-memory content and stop stale callbacks. Quiet live
tabs recheck authorized replay every 15 seconds and clear withdrawn access. Closing a
page with unsent edits warns the user; the interface discloses this limit.

The five existing Whiteboards table access namespaces stay frozen to their
existing owner implementation; SharedDocuments owns only its two new tables.
All canonical tables belong to Collaboration. Public DTOs, facade inventory,
exact configured port, OpenAPI/JSON Schema/WebSocket protocol and release
capability are declared explicitly. shared_documents_v1 guards every retained
document/operation row, including erased generation fences; an incompatible
rollback requires quiescence and zero hazards. Migration down refuses retained
rows. Release fingerprints use owner ID projections only, hashed by Release.

Provider qualification is not relevant to this plaintext owner implementation.
Backend concurrency/privacy, client Unicode/replay/unknown-ACK, controller and
real cross-device browser tests, independent source/security review and the
normal protected release chain remain required before claiming qualification.
