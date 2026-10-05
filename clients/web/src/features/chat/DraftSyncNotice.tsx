import type { DraftSyncState } from "./useSynchronizedDraft";
export function DraftSyncNotice({ sync }: { sync: DraftSyncState }) {
  if (sync.status === "conflict") return <div role="status" className="draft-sync-conflict"><p>A different draft was saved on another device. Your text is preserved here.</p><button type="button" onClick={sync.useRemote}>Use other device’s draft</button><button type="button" onClick={sync.keepLocal}>Keep this draft</button></div>;
  if (sync.status === "unavailable") return <p role="status">Draft kept on this device. Workspace synchronization will retry.</p>;
  if (sync.status === "syncing") return <p role="status">Synchronizing draft…</p>;
  if (sync.status === "synced") return <p className="composer-hint">Draft synchronized across your devices</p>;
  return null;
}
