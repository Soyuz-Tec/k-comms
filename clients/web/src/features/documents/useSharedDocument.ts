import { useCallback, useEffect, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { socketEndpoint } from "../../realtime";
import type { DocumentEdit, DocumentOperation, DocumentPresence, SharedDocument } from "../../types/sharedDocuments";
import { atomText, committedApply, optimisticApply, selectionIds, textChanges, type TextChange } from "./documentModel";
import { DocumentRealtime } from "./DocumentRealtime";

interface Engine { snapshot: SharedDocument; pending: DocumentEdit[] }
export function useSharedDocument(documentId: string) {
  const { api, session } = useSession();
  const [document, setDocument] = useState<SharedDocument | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<"connecting" | "live" | "offline" | "unavailable">("connecting");
  const statusRef = useRef(status);
  const [pendingCount, setPendingCount] = useState(0);
  const [peers, setPeers] = useState<Array<DocumentPresence & { observedAt: number }>>([]);
  const engine = useRef<Engine | null>(null);
  const commands = useRef<{ pump: () => void; presence: (anchor: number, head: number) => void } | null>(null);
  const userId = session?.user.id, deviceId = session?.device.id, tenantId = session?.tenant.id;

  const publish = useCallback(() => {
    const current = engine.current;
    if (!current) return;
    let atoms = current.snapshot.atoms;
    for (let index = 0; index < current.pending.length; index++) atoms = optimisticApply(atoms, current.pending[index]!, current.snapshot.version + index + 1);
    setDocument({ ...current.snapshot, atoms, content: atomText(atoms) });
    setPendingCount(current.pending.length);
  }, []);

  useEffect(() => {
    let active = true, pumping = false, synchronization: Promise<void> | null = null;
    let realtime: DocumentRealtime | null = null;
    let retryTimer: number | null = null;
    let reconnecting = false;
    engine.current = null; commands.current = null;
    setDocument(null); setPendingCount(0); setPeers([]); setError(null); setStatus("connecting");
    const accessLost = (failure: unknown) => [401, 403, 404].includes(Number((failure as { status?: unknown })?.status)) || (failure as { code?: unknown })?.code === "stale_document_generation";
    const unavailable = (message: string) => {
      if (!active) return;
      realtime?.disconnect(); engine.current = null; statusRef.current = "unavailable";
      if (retryTimer !== null) { window.clearTimeout(retryTimer); retryTimer = null; }
      setDocument(null); setPendingCount(0); setPeers([]); setStatus("unavailable"); setError(message);
    };
    const synchronize = () => {
      if (synchronization) return synchronization;
      synchronization = (async () => {
        if (!engine.current) {
          const snapshot = await api.sharedDocuments.get(documentId);
          if (!active) return;
          engine.current = { snapshot, pending: [] };
        } else {
          const deadline = Date.now() + 30_000;
          for (let pageIndex = 0; pageIndex < 40; pageIndex++) {
            const current = engine.current;
            if (!current) return;
            const replay = await api.sharedDocuments.replay(documentId, current.snapshot.generation, current.snapshot.version);
            if (!active) return;
            if (replay.page.generation !== current.snapshot.generation) throw new Error("Document generation changed");
            for (const operation of replay.data) current.snapshot = committedApply(current.snapshot, operation);
            if (!replay.page.has_more) break;
            if (!replay.data.length || Date.now() >= deadline || pageIndex === 39) throw new Error("Document replay did not finish within its limit");
          }
        }
        if (active) publish();
      })().finally(() => { synchronization = null; });
      return synchronization;
    };
    const accept = async (operation: DocumentOperation) => {
      if (!active || !engine.current) return;
      if (operation.generation !== engine.current.snapshot.generation) { unavailable("This document is no longer available"); return; }
      if (operation.version > engine.current.snapshot.version + 1) await synchronize();
      if (!active || !engine.current) return;
      engine.current.snapshot = committedApply(engine.current.snapshot, operation);
      publish();
    };
    const retry = () => {
      if (!active || retryTimer !== null) return;
      retryTimer = window.setTimeout(() => { retryTimer = null; void connect(); }, 3_000);
    };
    const pump = async () => {
      if (!active || pumping || statusRef.current !== "live" || !engine.current?.pending.length) return;
      pumping = true;
      const input = engine.current.pending[0]!;
      try {
        // Retries retain this exact UUID and exact input, including base version.
        // A lost response never creates a new operation or mutates its intent.
        const operation = await api.sharedDocuments.apply(documentId, input);
        if (!active) return;
        await accept(operation);
        if (!active || !engine.current) return;
        engine.current.pending = engine.current.pending.filter(item => item.client_operation_id !== input.client_operation_id);
        publish(); setError(null);
      } catch (failure) {
        if (!active) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else if ([409, 422].includes(Number((failure as { status?: unknown })?.status))) {
          statusRef.current = "offline"; setStatus("offline");
          setError("This edit could not be committed. Keep this page open and copy your unsent text before reloading.");
        } else {
          statusRef.current = "offline"; setStatus("offline"); setError("Connection interrupted. Your unsent edits remain in this tab.");
          realtime?.disconnect(); retry();
        }
      } finally {
        pumping = false;
        if (active && engine.current?.pending.length && statusRef.current === "live") void pump();
      }
    };
    async function connect() {
      if (!active || reconnecting) return;
      reconnecting = true;
      try {
        await synchronize();
        if (!active) return;
        const { ticket } = await api.socketTicket();
        if (!active) return;
        realtime?.disconnect();
        realtime = new DocumentRealtime(socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""), ticket, documentId, {
          operation: operation => { void accept(operation).catch(failure => {
            if (!active) return;
            if (accessLost(failure)) unavailable("Your access to this document changed");
            else { setError("Document synchronization was interrupted"); retry(); }
          }); },
          presence: presence => {
            if (!active || presence.device_id === deviceId || presence.generation !== engine.current?.snapshot.generation) return;
            setPeers(existing => [...existing.filter(peer => peer.device_id !== presence.device_id), { ...presence, observedAt: Date.now() }].slice(-50));
          },
          closed: () => { if (active) { statusRef.current = "offline"; setStatus("offline"); setPeers([]); retry(); } }
        });
        await realtime.connect();
        if (!active) return;
        // Joining first closes the snapshot-to-subscription gap. Durable replay
        // reconstructs every committed operation before retrying the outbox.
        await synchronize();
        if (!active) return;
        statusRef.current = "live"; setStatus("live"); setError(null); void pump();
      } catch (failure) {
        if (!active) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else { statusRef.current = "offline"; setStatus("offline"); setError("Unable to synchronize this document. Retrying…"); retry(); }
      } finally { reconnecting = false; }
    }
    commands.current = { pump: () => { void pump(); }, presence: (anchor, head) => {
      const current = engine.current;
      if (!current) return;
      let atoms = current.snapshot.atoms;
      for (let index = 0; index < current.pending.length; index++) atoms = optimisticApply(atoms, current.pending[index]!, current.snapshot.version + index + 1);
      realtime?.presence({ generation: current.snapshot.generation, ...selectionIds(atoms, anchor, head) });
    } };
    const beforeUnload = (event: BeforeUnloadEvent) => { if (engine.current?.pending.length) event.preventDefault(); };
    const presenceTimer = window.setInterval(() => setPeers(existing => existing.filter(peer => Date.now() - peer.observedAt < 15_000)), 3_000);
    // A quiet socket still rechecks current server authority. Withdrawn access
    // or governed erasure clears the tab even when no peer emits a new event.
    const authorityTimer = window.setInterval(() => {
      if (!active || statusRef.current !== "live") return;
      void synchronize().catch(failure => {
        if (!active) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else { statusRef.current = "offline"; setStatus("offline"); realtime?.disconnect(); retry(); }
      });
    }, 15_000);
    window.addEventListener("beforeunload", beforeUnload);
    statusRef.current = "connecting";
    void connect();
    return () => {
      active = false; realtime?.disconnect(); if (retryTimer !== null) window.clearTimeout(retryTimer);
      window.clearInterval(presenceTimer); window.clearInterval(authorityTimer); window.removeEventListener("beforeunload", beforeUnload);
      engine.current = null; commands.current = null;
    };
  }, [api, documentId, userId, deviceId, tenantId, publish]);

  const edit = useCallback((changes: TextChange[]) => {
    const current = engine.current;
    if (!current || current.snapshot.readonly || current.pending.length >= 100) throw new Error("This document is read only or has too many unsent edits");
    let atoms = current.snapshot.atoms;
    for (let index = 0; index < current.pending.length; index++) atoms = optimisticApply(atoms, current.pending[index]!, current.snapshot.version + index + 1);
    const input: DocumentEdit = { client_operation_id: crypto.randomUUID(), generation: current.snapshot.generation,
      base_version: current.snapshot.version, kind: "edit", changes: textChanges(atoms, changes) };
    optimisticApply(atoms, input, current.snapshot.version + current.pending.length + 1);
    current.pending.push(input); publish(); commands.current?.pump();
  }, [publish]);
  const presence = useCallback((anchor: number, head: number) => commands.current?.presence(anchor, head), []);
  return { document, edit, presence, peers, status, error, pendingCount };
}
