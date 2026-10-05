# Rich content operations

The gallery lists existing conversation boards. Drawing creates a board; access
comes from current membership. Named checkpoints are separate from automatic
snapshots. Managers can rename or restore. Preserve the operation log and
ordinary backup/restore gates; do not edit checkpoint JSON by hand.
Checkpoint restores retain server-owned original-author lineage, including
nested restores. User erasure scrubs dependent restore chunks and checkpoint
caches while retaining unrelated updates. Reversing the lineage migration also
scrubs those chunks and caches before dropping metadata; it deliberately loses
dependent restored content to preserve erasure behavior on the older runtime.

Images must be shared through the normal conversation attachment workflow and
pass its safety scan. The board reference binds that same message, approved
version and conversation. Deleted, moderated, quarantined or inaccessible sources
cannot receive a new read authorization, be restored or exported. Previously
issued signed downloads expire at their reported deadline; previously downloaded
bytes cannot be recalled. A missing source appears as unavailable;
do not re-enable an old version or bypass the scanner to make it render.

`PersonalContentCleanupWorker` runs hourly and clears at most 1,000 expired
nonempty draft bodies per invocation with row locks that skip active writes.
Inspect the normal Oban failure/retry inventory if the sweep fails. Retrieval
hides expired text immediately; the sweep preserves the versioned empty
record so a device with an old version receives a conflict. Never delete all
version tombstones as a routine recovery shortcut. Governance erasure removes
scoped personal data through `Messaging.erase_personal_content/3` in its existing
transaction. Saved lists reference source messages and exclude revoked or
removed sources.

Unified search ranks a bounded authorized union and discloses limits. More
results pages continue within those candidates. Narrow the conversation, query
or content type if a source limit is reported. Calendar metadata covers at most
a two-year window. Search metadata never returns raw recording storage identity.

An application rollback with retained draft/saved content, approved board assets,
checkpoints or restored author lineage requires `rich_content_erasure_v1` on the
approved target. The current release's quiesced preflight obtains content-free
owner counts and refuses incompatible retained state. Preserve the target's
immutable declaration and use a compatible bridge or roll forward; keeping new
columns while running an older erasure implementation is insufficient.

Qualification must include tenant and current-session denial, source erasure,
draft conflict/clear on two sessions, approved image reload and export, and
checkpoint replay after restore. Synthetic browser/provider responses do not
prove production indexing capacity or physical-device usability. Optional drive
features are not part of this milestone.
