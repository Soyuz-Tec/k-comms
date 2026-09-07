# Whiteboard recovery and controls — 2026-09-06

This change completes the six outstanding whiteboard improvements identified in
the interface review:

1. Completed scene-update batches survive a tab or browser restart through a
   device-scoped IndexedDB outbox, with a localStorage fallback for browsers
   that deny IndexedDB.
2. The drawing toolbar auto-hides after eight seconds of inactivity. A compact
   reveal control, top-edge pointer dwell, keyboard focus, and blocking-surface
   rules preserve discoverability and accessibility.
3. The status bar distinguishes `Synced`, `Syncing`, `Unsynced changes`, and
   `Sync paused`, including the pending operation count.
4. Undo/redo remain the editor-native actions and shortcuts. K-Comms owns a
   tested PNG export action and a shared clear confirmation that states its
   full conversation scope.
5. Message deep links select and scroll to the referenced objects after editor
   initialization and report missing or partial references explicitly.
6. Clear-copy language now consistently describes all objects and the
   conversation-wide effect.

The server remains the source of truth. Local outbox entries are idempotent
scene batches only; they contain no credentials and are removed after server
acknowledgement. A stale-generation response always replays authoritative
history instead of applying edits to a board that was cleared elsewhere.

Recovery is best effort: browsers can deny or evict storage, and a process crash
before the 350 ms batching checkpoint can lose the latest unfinished gesture.
The interface warns when recovery storage is unavailable. Browser content stays
scoped to the tenant, user, device, and conversation and is not a server backup.

Desktop browser proof covers IndexedDB reload recovery, drawing and replay,
clear, PNG download, and real native undo/redo. Desktop and mobile both cover
whiteboard layout, toolbar hide/reveal, and stale reference feedback. The live
two-browser journey checks presence, durable operations, replay, and shared clear
against a synthetic local tenant.
