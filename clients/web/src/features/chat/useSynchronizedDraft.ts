import { useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api";
import type { SynchronizedDraft } from "../../types/rich-content";

export interface DraftSyncState { status: "local" | "syncing" | "synced" | "conflict" | "unavailable"; remote: SynchronizedDraft | null; useRemote: () => void; keepLocal: () => void; edited: () => void; }
export function useSynchronizedDraft(api: ApiClient | undefined, conversationId: string | null, threadKey: string,
  body: string, onRemote: (body: string) => void): DraftSyncState {
  const [status, setStatus] = useState<DraftSyncState["status"]>("local");
  const [remote, setRemote] = useState<SynchronizedDraft | null>(null);
  const bodyRef = useRef(body); bodyRef.current = body;
  const onRemoteRef = useRef(onRemote); onRemoteRef.current = onRemote;
  const versionRef = useRef<number | null>(null); const lastSaved = useRef("");
  const dirty = useRef(false); const conflict = useRef(false); const busy = useRef(false);
  const retry = useRef(0);
  const generation = useRef(0); const writeRef = useRef<() => Promise<void>>(async () => undefined);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const token = ++generation.current; let alive = true;
    versionRef.current = null; dirty.current = false; conflict.current = false; busy.current = false; retry.current = 0;
    setRemote(null); setStatus("local");
    if (!api || !conversationId || typeof api.messageDraft !== "function") return;
    const active = () => alive && token === generation.current;
    async function read() {
      if (!active() || busy.current) return;
      busy.current = true;
      try {
        const draft = await api!.messageDraft(conversationId!, threadKey);
        if (!active()) return;
        const first = versionRef.current === null;
        const local = bodyRef.current;
        if (draft.version !== versionRef.current || first) {
          if ((dirty.current || (first && local !== "")) && local !== draft.body && (!first || draft.version > 0 || draft.body !== "")) {
            conflict.current = true; setRemote(draft); setStatus("conflict");
          } else if (!dirty.current && (!first || local === "")) {
            versionRef.current = draft.version; lastSaved.current = draft.body;
            onRemoteRef.current(draft.body); setStatus("synced");
          } else {
            versionRef.current = draft.version; lastSaved.current = draft.body;
            dirty.current = local !== draft.body; setStatus(dirty.current ? "local" : "synced");
            if (dirty.current) window.setTimeout(() => { if (active()) void writeRef.current(); }, 0);
          }
        } else if (!conflict.current) setStatus(dirty.current ? "local" : "synced");
      } catch { if (active()) setStatus("unavailable"); }
      finally { if (active()) busy.current = false; }
    }
    async function write() {
      if (!active() || busy.current || conflict.current || !dirty.current || versionRef.current === null) return;
      const snapshot = bodyRef.current; const expected = versionRef.current;
      busy.current = true; setStatus("syncing");
      try {
        const saved = await api!.updateMessageDraft(conversationId!, snapshot, expected, threadKey);
        if (!active()) return;
        versionRef.current = saved.version; lastSaved.current = snapshot; retry.current = 0;
        dirty.current = bodyRef.current !== snapshot; setStatus(dirty.current ? "local" : "synced");
      } catch (reason: unknown) {
        if (!active()) return;
        if (reason && typeof reason === "object" && "code" in reason && reason.code === "stale_draft") {
          try {
            const latest = await api!.messageDraft(conversationId!, threadKey);
            if (active()) { conflict.current = true; setRemote(latest); setStatus("conflict"); }
          } catch { if (active()) setStatus("unavailable"); }
        } else setStatus("unavailable");
        retry.current += 1;
      } finally {
        if (active()) { busy.current = false; if (dirty.current && !conflict.current) window.setTimeout(() => { if (active()) void writeRef.current(); }, [1_000, 3_000, 10_000, 30_000][Math.min(retry.current, 3)]); }
      }
    }
    writeRef.current = write;
    void read();
    const focus = () => void read();
    const timer = window.setInterval(() => { if (!document.hidden) void read(); }, 30_000);
    window.addEventListener("focus", focus);
    return () => { alive = false; window.clearInterval(timer); window.removeEventListener("focus", focus); };
  }, [api, conversationId, threadKey]);

  useEffect(() => {
    if (!dirty.current || conflict.current) return;
    const timer = window.setTimeout(() => void writeRef.current(), 800);
    return () => window.clearTimeout(timer);
  }, [body, attempt]);
  function edited() { dirty.current = true; if (!conflict.current) setStatus("local"); }
  function useRemote() {
    if (!remote) return;
    versionRef.current = remote.version; lastSaved.current = remote.body; dirty.current = false; conflict.current = false;
    onRemoteRef.current(remote.body); setRemote(null); setStatus("synced");
  }
  function keepLocal() {
    if (!remote) return;
    versionRef.current = remote.version; lastSaved.current = remote.body; dirty.current = true; conflict.current = false;
    setRemote(null); setStatus("local"); setAttempt(value => value + 1);
  }
  return { status, remote, useRemote, keepLocal, edited };
}
