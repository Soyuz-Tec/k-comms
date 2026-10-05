import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { socketEndpoint } from "../../realtime";
import type { DocumentEdit, DocumentOperation, DocumentPresence, SharedDocument } from "../../types/sharedDocuments";
import { atomText, committedApply, optimisticApply, selectionIds, textChanges, type TextChange } from "./documentModel";
import { DocumentRealtime } from "./DocumentRealtime";

interface Engine { snapshot: SharedDocument; pending: DocumentEdit[] }
const accessLost = (failure: unknown) => [401, 403, 404].includes(Number((failure as { status?: unknown })?.status)) || (failure as { code?: unknown })?.code === "stale_document_generation";
// Only this opaque memo token is used as a React key. Equivalent session
// objects keep it; credential or owner-authority changes discard local scope.
export function useDocumentAuthorityGeneration() {
  const { api, session } = useSession();
  return useMemo(() => crypto.randomUUID(), [api,
    session?.access_token, session?.refresh_token,
    session?.tenant.id, session?.tenant.status,
    session?.user.id, session?.user.tenant_id, session?.user.role,
    session?.user.status, session?.user.version, session?.user.account_type,
    session?.user.access_scope, session?.user.platform_role, session?.user.platform_role_expires_at,
    session?.device.id, session?.device.user_id, session?.device.revoked_at
  ]);
}

export function useSharedDocument(documentId: string) {
  const { api, session } = useSession();
  const generation = useDocumentAuthorityGeneration();
  const scope = useMemo(() => ({ generation, documentId }), [generation, documentId]);
  const renderedScope = useRef(scope);
  renderedScope.current = scope;
  const [document, setDocument] = useState<SharedDocument | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<"connecting" | "live" | "offline" | "unavailable">("connecting");
  const statusRef = useRef(status);
  const [pendingCount, setPendingCount] = useState(0);
  const [peers, setPeers] = useState<Array<DocumentPresence & { observedAt: number }>>([]);
  const engine = useRef<Engine | null>(null);
  const authority = useRef({ epoch: 0, available: false, scope: null as typeof scope | null });
  const [authorityEpoch, setAuthorityEpoch] = useState(0);
  const commands = useRef<{ deny: () => void; pump: () => void; presence: (anchor: number, head: number) => void } | null>(null);
  const deviceId = session?.device.id;
  const sameScope = useCallback(() => authority.current.scope === renderedScope.current, []);

  const publish = useCallback(() => {
    const current = engine.current;
    if (!current) return;
    let atoms = current.snapshot.atoms;
    for (let index = 0; index < current.pending.length; index++) atoms = optimisticApply(atoms, current.pending[index]!, current.snapshot.version + index + 1);
    setDocument({ ...current.snapshot, atoms, content: atomText(atoms) });
    setPendingCount(current.pending.length);
  }, []);

  useEffect(() => {
    let active = true, conflicted = false, pumping = false, synchronization: Promise<void> | null = null;
    let realtime: DocumentRealtime | null = null;
    let retryTimer: number | null = null;
    let reconnecting = false;
    const epoch = ++authority.current.epoch;
    authority.current.scope = scope; authority.current.available = true; setAuthorityEpoch(epoch);
    const currentScope = () => active && sameScope() && authority.current.available && authority.current.epoch === epoch;
    engine.current = null; commands.current = null;
    setDocument(null); setPendingCount(0); setPeers([]); setError(null); setStatus("connecting");
    const unavailable = (message: string) => {
      if (!currentScope()) return;
      authority.current.available = false; setAuthorityEpoch(++authority.current.epoch);
      statusRef.current = "unavailable"; commands.current = null; engine.current = null; realtime?.disconnect();
      if (retryTimer !== null) { window.clearTimeout(retryTimer); retryTimer = null; }
      setDocument(null); setPendingCount(0); setPeers([]); setStatus("unavailable"); setError(message);
    };
    const synchronize = () => {
      if (synchronization) return synchronization;
      synchronization = (async () => {
        if (!engine.current) {
          const snapshot = await api.sharedDocuments.get(documentId);
          if (!currentScope()) return;
          engine.current = { snapshot, pending: [] };
        } else {
          const deadline = Date.now() + 30_000;
          for (let pageIndex = 0; pageIndex < 40; pageIndex++) {
            const current = engine.current;
            if (!current) return;
            const replay = await api.sharedDocuments.replay(documentId, current.snapshot.generation, current.snapshot.version);
            if (!currentScope()) return;
            if (replay.page.generation !== current.snapshot.generation) throw Object.assign(new Error("Document generation changed"), { code: "stale_document_generation" });
            for (const operation of replay.data) current.snapshot = committedApply(current.snapshot, operation);
            if (!replay.page.has_more) break;
            if (!replay.data.length || Date.now() >= deadline || pageIndex === 39) throw new Error("Document replay did not finish within its limit");
          }
        }
        if (currentScope()) publish();
      })().finally(() => { synchronization = null; });
      return synchronization;
    };
    const accept = async (operation: DocumentOperation) => {
      if (!currentScope() || !engine.current) return;
      if (operation.generation !== engine.current.snapshot.generation) { unavailable("This document is no longer available"); return; }
      if (operation.version > engine.current.snapshot.version + 1) await synchronize();
      if (!currentScope() || !engine.current) return;
      engine.current.snapshot = committedApply(engine.current.snapshot, operation);
      publish();
    };
    const retry = () => {
      if (!currentScope() || retryTimer !== null) return;
      retryTimer = window.setTimeout(() => { retryTimer = null; void connect(); }, 3_000);
    };
    const pump = async () => {
      if (!currentScope() || pumping || statusRef.current !== "live" || !engine.current?.pending.length) return;
      pumping = true;
      const input = engine.current.pending[0]!;
      try {
        // Retries retain this exact UUID and exact input, including base version.
        // A lost response never creates a new operation or mutates its intent.
        const operation = await api.sharedDocuments.apply(documentId, input);
        if (!currentScope()) return;
        await accept(operation);
        if (!currentScope() || !engine.current) return;
        engine.current.pending = engine.current.pending.filter(item => item.client_operation_id !== input.client_operation_id);
        publish(); setError(null);
      } catch (failure) {
        if (!currentScope()) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else if ([400, 409, 422].includes(Number((failure as { status?: unknown })?.status))) {
          conflicted = true; statusRef.current = "offline"; setStatus("offline");
          setError("This edit could not be committed. Keep this page open and copy your unsent text before reloading.");
        } else {
          statusRef.current = "offline"; setStatus("offline"); setError("Connection interrupted. Your unsent edits remain in this tab.");
          realtime?.disconnect(); retry();
        }
      } finally {
        pumping = false;
        if (currentScope() && engine.current?.pending.length && statusRef.current === "live") void pump();
      }
    };
    async function connect() {
      if (!currentScope() || reconnecting) return;
      reconnecting = true;
      try {
        await synchronize();
        if (!currentScope()) return;
        const { ticket } = await api.socketTicket();
        if (!currentScope()) return;
        realtime?.disconnect();
        realtime = new DocumentRealtime(socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""), ticket, documentId, {
          operation: operation => { void accept(operation).catch(failure => {
            if (!currentScope()) return;
            if (accessLost(failure)) unavailable("Your access to this document changed");
            else { setError("Document synchronization was interrupted"); retry(); }
          }); },
          presence: presence => {
            if (!currentScope() || presence.device_id === deviceId || presence.generation !== engine.current?.snapshot.generation) return;
            setPeers(existing => [...existing.filter(peer => peer.device_id !== presence.device_id), { ...presence, observedAt: Date.now() }].slice(-50));
          },
          closed: () => { if (currentScope()) { statusRef.current = "offline"; setStatus("offline"); setPeers([]); retry(); } }
        });
        await realtime.connect();
        if (!currentScope()) return;
        // Joining first closes the snapshot-to-subscription gap. Durable replay
        // reconstructs every committed operation before retrying the outbox.
        await synchronize();
        if (!currentScope()) return;
        statusRef.current = conflicted ? "offline" : "live"; setStatus(statusRef.current);
        if (!conflicted) { setError(null); void pump(); }
      } catch (failure) {
        if (!currentScope()) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else { statusRef.current = "offline"; setStatus("offline"); setError("Unable to synchronize this document. Retrying…"); retry(); }
      } finally { reconnecting = false; }
    }
    commands.current = { deny: () => unavailable("Your access to this document changed"), pump: () => { void pump(); }, presence: (anchor, head) => {
      if (!currentScope()) return;
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
      if (!currentScope()) return;
      void synchronize().catch(failure => {
        if (!currentScope()) return;
        if (accessLost(failure)) unavailable("Your access to this document changed");
        else { statusRef.current = "offline"; setStatus("offline"); realtime?.disconnect(); retry(); }
      });
    }, 15_000);
    window.addEventListener("beforeunload", beforeUnload);
    statusRef.current = "connecting";
    void connect();
    return () => {
      active = false; authority.current.available = false; authority.current.epoch++; realtime?.disconnect(); if (retryTimer !== null) window.clearTimeout(retryTimer);
      window.clearInterval(presenceTimer); window.clearInterval(authorityTimer); window.removeEventListener("beforeunload", beforeUnload);
      engine.current = null; commands.current = null;
    };
  }, [api, scope, documentId, deviceId, publish, sameScope]);

  const edit = useCallback((changes: TextChange[]) => {
    const current = engine.current;
    if (!sameScope() || !authority.current.available || !current || current.snapshot.readonly || current.pending.length >= 100) throw new Error("This document is read only or has too many unsent edits");
    let atoms = current.snapshot.atoms;
    for (let index = 0; index < current.pending.length; index++) atoms = optimisticApply(atoms, current.pending[index]!, current.snapshot.version + index + 1);
    const input: DocumentEdit = { client_operation_id: crypto.randomUUID(), generation: current.snapshot.generation,
      base_version: current.snapshot.version, kind: "edit", changes: textChanges(atoms, changes) };
    optimisticApply(atoms, input, current.snapshot.version + current.pending.length + 1);
    current.pending.push(input); publish(); commands.current?.pump();
  }, [publish, sameScope]);
  const presence = useCallback((anchor: number, head: number) => commands.current?.presence(anchor, head), []);
  const isCurrentAuthority = useCallback((epoch: number) => sameScope() && authority.current.available && authority.current.epoch === epoch, [sameScope]);
  const reportAuthorityFailure = useCallback((failure: unknown) => {
    if (!accessLost(failure)) return false;
    commands.current?.deny();
    return true;
  }, []);
  const visible = sameScope() && authority.current.available;
  return { document: visible ? document : null, edit, presence, peers: visible ? peers : [],
    status: sameScope() ? status : "connecting" as const, error: sameScope() ? error : null, pendingCount: visible ? pendingCount : 0,
    authorityEpoch, isCurrentAuthority, reportAuthorityFailure };
}
