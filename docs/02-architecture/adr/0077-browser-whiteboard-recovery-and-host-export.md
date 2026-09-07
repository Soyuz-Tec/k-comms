# ADR-0077: Recover browser whiteboard edits locally and keep export host-owned

- **Status:** Accepted
- **Date:** 2026-09-06
- **Owners:** Collaboration, Web
- **Reviewers:** Architecture, Security, Release and Quality
- **Related requirements:** FR-COL-001, FR-MSG-003, NFR-SEC-001, NFR-REL-001,
  ADR-0063, ADR-0069, ADR-0070

## Context

The conversation whiteboard already has a durable, sequenced server history and
an idempotent realtime adapter. The browser, however, retained an unsent scene
batch only in memory. A tab crash or browser restart could therefore lose a
completed drawing gesture. The host also had no explicit save state, no
first-class export action, and no feedback when a message deep link referred to
an object that had since been deleted.

The embedded editor exposes its own undo/redo actions and keyboard shortcuts,
but K-Comms must not reimplement or persist a second history. Vendor-owned
export, load, and save flows are intentionally disabled by ADR-0063.

## Decision

1. Keep unsent, allow-listed scene-update batches in an install-scoped browser
   outbox. Use IndexedDB as the primary store and a synchronous localStorage
   checkpoint until its write completes, retaining the fallback when IndexedDB
   is unavailable. Seal immutable operations after a 350 ms debounce or page
   exit; unsealed gestures may be lost on an abrupt process termination. Store
   each operation separately and remove only acknowledged IDs so concurrent
   tabs cannot overwrite each other's work. Store no tokens, identities beyond the
   scoped key, or unrelated conversation data. Keep an in-flight batch durable
   until its idempotent server acknowledgement arrives.
2. The server remains authoritative. On load, replay server history first,
   overlay recoverable local batches, then send those batches with their
   existing client operation IDs. A stale-generation response discards the
   local batch and replays authoritative history instead of silently merging
   edits across a clear.
3. Expose four host-owned states: `Synced`, `Syncing`, `Unsynced changes`, and
   `Sync paused`. Include a pending count and actionable error text; do not
   claim that a local edit is saved before the server acknowledges it.
4. Hide the editor's top drawing toolbar after eight seconds of inactivity.
   Reveal it with a top-edge pointer dwell, keyboard focus, or a compact
   always-discoverable button. Keep the toolbar accessible and visible while a
   menu, dialog, text editor, or other blocking surface is active, and respect
   reduced-motion and forced-colors preferences.
5. Keep undo/redo native to the embedded editor (buttons and Ctrl/Cmd keyboard
   shortcuts). K-Comms does not duplicate those actions in host controls.
   Host-owned `Export PNG` is the only export path and uses the current scene,
   app state, and files through the editor export API. Clear remains an
   explicit, shared destructive action that starts a new server-authoritative
   board generation and resets editor undo history, not server retention; its
   confirmation names the full conversation scope. PNG files do not embed
   editable scene metadata.
6. When a message reference focuses the board, select and scroll to the
   referenced IDs after the editor is ready. Report a missing or partial
   reference instead of pretending that the target exists.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Keep pending edits in React memory | No browser storage API | A tab crash loses a completed gesture | Rejected |
| Write every pointer frame to the server | Small recovery window | Excessive writes, noisy history, and worse latency | Rejected |
| Persist a second host undo stack | Host could control every action | Diverges from Excalidraw history and creates conflicting semantics | Rejected |
| Keep the vendor export menu | No host code | Reintroduces unreviewed file/save flows and branding | Rejected |
| Hide tools with no reveal affordance | Maximum canvas area | Discoverability and keyboard access regress | Rejected |

## Consequences

- Browser restarts recover completed unsent batches without changing the API or
  database contract. Idempotency prevents duplicate operations after a crash.
- Whiteboard scene content is temporarily present in browser storage, so the
  outbox is cleared on acknowledgement and never includes credentials. Users
  on browsers that deny both storage APIs still get a usable canvas, but only
  in-memory recovery.
- Native editor undo/redo remains predictable, while PNG export is auditable
  and testable at the K-Comms boundary.
- The compact toolbar reveal and explicit sync status give back workspace area
  without making drawing tools undiscoverable.

## Validation

- Unit tests cover outbox fallback round-trip, malformed/unsupported data
  rejection, in-flight save recovery semantics, explicit sync states, stale
  generation handling, host export, native shortcut allowance, and toolbar
  hide/reveal behavior.
- Desktop browser journeys cover drawing, IndexedDB reload recovery, durable
  replay, clear, PNG download, and real undo/redo. Desktop and mobile journeys
  both cover layout, focus-reference feedback, toolbar reveal, and accessibility.
- Release qualification must use the same immutable image digest in staging and
  production and retain the normal backup, rollback, and post-deploy evidence.
