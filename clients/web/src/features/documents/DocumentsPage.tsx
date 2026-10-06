import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { useUnsavedWork } from "../../app/UnsavedWork";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { AppIcon } from "../../components/AppIcon";
import { formatDateTime } from "../../lib/format";
import { useWorkspaceData } from "../../app/workspace-data";
import type { DocumentEdit, DocumentSummary, SharedDocument } from "../../types/sharedDocuments";
import { SharedDocumentEditor } from "./SharedDocumentEditor";
import { useDocumentAuthorityGeneration, useSharedDocument } from "./useSharedDocument";
import "./documents.css";

export function DocumentsPage() {
  const generation = useDocumentAuthorityGeneration();
  return <DocumentsForIdentity key={generation} />;
}

function DocumentsForIdentity() {
  const { api, session } = useSession();
  const { conversations, loading } = useWorkspaceData();
  const [params, setParams] = useSearchParams();
  const requested = params.get("conversation");
  const conversation = requested ? conversations.find(value => value.id === requested) : conversations[0];
  const [documents, setDocuments] = useState<DocumentSummary[]>([]);
  const [query, setQuery] = useState("");
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState(0);
  const documentId = params.get("document");
  const identity = `${session?.tenant.id}:${session?.user.id}:${session?.device.id}`;
  const conversationId = conversation?.id;
  const currentConversation = useRef(conversationId);
  currentConversation.current = conversationId;
  const pageAuthorityEpoch = useRef(0);
  const createIntent = useRef<{ conversation: string; title: string; id: string } | null>(null);
  useEffect(() => {
    let current = true;
    const epoch = pageAuthorityEpoch.current;
    const currentScope = () => current && pageAuthorityEpoch.current === epoch;
    setDocuments([]); setError(null);
    if (conversationId) {
      setBusy(true);
      api.sharedDocuments.list(conversationId, query).then(values => { if (currentScope()) setDocuments(values); })
        .catch(() => { if (currentScope()) setError("These documents are unavailable or your access changed."); })
        .finally(() => { if (currentScope()) setBusy(false); });
    }
    return () => { current = false; };
  }, [api, conversationId, query, revision, identity]);
  const open = (document: DocumentSummary | SharedDocument) => setParams({ conversation: document.conversation_id, document: document.id });
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  async function create() {
    if (!conversation || !title.trim() || busy) return;
    const context = conversation.id, epoch = pageAuthorityEpoch.current;
    const requestedTitle = title.trim();
    if (createIntent.current?.conversation !== context || createIntent.current.title !== requestedTitle) createIntent.current = { conversation: context, title: requestedTitle, id: crypto.randomUUID() };
    const intent = createIntent.current!;
    setBusy(true); setError(null);
    try {
      const document = await api.sharedDocuments.create(context, intent.title, intent.id);
      if (!active.current || currentConversation.current !== context || pageAuthorityEpoch.current !== epoch) return;
      createIntent.current = null;
      open(document); setTitle(""); setRevision(value => value + 1);
    } catch { if (active.current && currentConversation.current === context && pageAuthorityEpoch.current === epoch) setError("Unable to confirm creation. Retry with this same title to recover the original document."); }
    finally { if (active.current && currentConversation.current === context && pageAuthorityEpoch.current === epoch) setBusy(false); }
  }
  const accessChanged = useCallback(() => {
    pageAuthorityEpoch.current++; setBusy(false);
    setDocuments([]); setQuery(""); setTitle(""); createIntent.current = null;
    setRevision(value => value + 1);
  }, []);
  if (loading) return <main id="main-content" className="centered-page" aria-busy="true"><p>Opening documents…</p></main>;
  return <main className="page-shell documents-page" id="main-content">
    <SurfaceHeader title="Shared documents" back={{ to: "/app/content", label: "Content" }} description="Write notes and plans together with your conversation members." className="documents-heading" actions={
      <label className="field">Conversation<select value={conversation?.id || ""} onChange={event => setParams({ conversation: event.target.value })}>
        {!conversation && <option value="">Choose a conversation</option>}
        {conversations.map(value => <option key={value.id} value={value.id}>{value.title || "Untitled conversation"}</option>)}
      </select></label>} />
    {error && <p role="alert">{error}</p>}
    {!conversation ? <section className="empty-state"><h2>Choose a conversation first</h2><Link to="/app/">Open Inbox</Link></section> : <div className="documents-workspace">
      <aside className="documents-library" aria-label="Conversation documents">
        <div className="documents-library-heading"><h2>Conversation documents</h2><p>Shared with current members of {conversation.title || "this conversation"}.</p></div>
        <label className="field">Find a document<input type="search" value={query} maxLength={160} onChange={event => setQuery(event.target.value)} placeholder="Search title or content" /></label>
        <div aria-busy={busy}>{documents.map(document => <button className={`document-library-item ${document.id === documentId ? "selected" : ""}`} key={document.id} onClick={() => open(document)} type="button" aria-current={document.id === documentId ? "page" : undefined}><strong>{document.title}</strong><span className="document-library-excerpt">{document.excerpt || "No text yet"}</span><small><time dateTime={document.updated_at}>Updated {formatDateTime(document.updated_at)}</time></small><small>Version {document.version}{document.readonly && " · Read only"}</small></button>)}
          {!busy && documents.length === 0 && <p>{query ? "No documents match this search. Try another title or phrase." : "No documents here yet. Create one to start writing together."}</p>}</div>
        <form onSubmit={event => { event.preventDefault(); void create(); }}><label className="field">New document title<input value={title} maxLength={160} onChange={event => setTitle(event.target.value)} /></label><button type="submit" className="button primary" disabled={busy || !title.trim()}>Create document</button></form>
      </aside>
      {documentId ? <DocumentWorkspace key={`${identity}:${documentId}`} id={documentId} onCopy={open} onAccessChanged={accessChanged} onChanged={() => setRevision(value => value + 1)} /> : <section className="document-welcome surface-empty"><AppIcon name="file" /><h2>{documents.length ? "Choose a document to continue" : "Write together"}</h2><p>{documents.length ? "Open a document from the library to read it and resume editing." : "Create meeting notes, an agenda or a shared plan, then edit with your conversation members."}</p>{documents[0] && <button type="button" className="button primary" onClick={() => open(documents[0]!)}>Continue {documents[0].title}</button>}<p className="document-sync-note">Unsent changes stay in this tab. Keep it open until syncing completes.</p></section>}
    </div>}
  </main>;
}

type ActionIntent = { kind: "rename"; input: DocumentEdit; epoch: number } | { kind: "copy"; title: string; clientId: string; epoch: number };

function DocumentWorkspace({ id, onCopy, onChanged, onAccessChanged }: { id: string; onCopy: (value: SharedDocument) => void; onChanged: () => void; onAccessChanged: () => void }) {
  const { api } = useSession();
  const { document, edit, presence, peers, status, error, pendingCount, authorityEpoch, isCurrentAuthority, reportAuthorityFailure } = useSharedDocument(id);
  const [titleDraft, setTitleDraft] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pendingAction, setPendingAction] = useState<ActionIntent | null>(null);
  const intent = useRef<ActionIntent | null>(null);
  const inFlight = useRef(false);
  const active = useRef(true);
  const reportedLoss = useRef<number | null>(null);
  useEffect(() => { active.current = true; return () => { active.current = false; intent.current = null; }; }, []);
  useEffect(() => {
    intent.current = null; inFlight.current = false;
    setPendingAction(null); setBusy(false); setTitleDraft(null); setActionError(null);
  }, [api, id, authorityEpoch]);
  useEffect(() => {
    if (status === "unavailable" && reportedLoss.current !== authorityEpoch) {
      reportedLoss.current = authorityEpoch; onAccessChanged();
    }
  }, [status, authorityEpoch, onAccessChanged]);
  useUnsavedWork(() => Boolean(document && (pendingCount > 0 || intent.current || (titleDraft !== null && titleDraft !== document.title))),
    "This document has unsent edits, a changed title, or an action awaiting confirmation.");
  if (!document) return <section className="document-welcome" aria-busy={status === "connecting"}><h2>{status === "unavailable" ? "Document unavailable" : status === "offline" ? "Document connection unavailable" : "Opening document…"}</h2>{error && <p role="alert">{error}</p>}</section>;
  const connectionReady = status === "live" && pendingCount === 0;
  const actionsAllowed = connectionReady && !busy && !pendingAction;
  async function submitAction(request: ActionIntent) {
    if (!active.current || inFlight.current || !isCurrentAuthority(request.epoch)) return;
    intent.current = request; inFlight.current = true;
    setPendingAction(request); setBusy(true); setActionError(null);
    const current = () => active.current && intent.current === request && isCurrentAuthority(request.epoch);
    const finish = () => { intent.current = null; setPendingAction(null); };
    try {
      if (request.kind === "rename") {
        await api.sharedDocuments.apply(id, request.input);
        if (!current()) return;
        finish(); setTitleDraft(null); onChanged();
      } else {
        const copied = await api.sharedDocuments.copy(id, request.title, request.clientId);
        if (!current()) return;
        finish(); onCopy(copied); onChanged();
      }
    } catch (failure) {
      if (!current()) return;
      if (reportAuthorityFailure(failure)) { finish(); setTitleDraft(null); }
      else if ([400, 409, 422].includes(Number((failure as { status?: unknown })?.status))) {
        finish(); setActionError("This action was rejected. Wait for synchronization before trying a new action.");
      } else {
        // A timeout can hide a committed response. Keep the original UUID,
        // generation, base version and payload until this intent is confirmed.
        setActionError(`Unable to confirm ${request.kind === "copy" ? "the copy" : "the title change"}. Retry the pending action to recover its original result.`);
      }
    } finally {
      // A withdrawn scope or a later action must not be changed by this result.
      if (active.current && isCurrentAuthority(request.epoch) && (intent.current === request || intent.current === null)) {
        inFlight.current = false; setBusy(false);
      }
    }
  }
  function rename() {
    if (!document || !actionsAllowed || !titleDraft?.trim() || intent.current) return;
    void submitAction({ kind: "rename", epoch: authorityEpoch, input: {
      client_operation_id: crypto.randomUUID(), generation: document.generation,
      base_version: document.version, kind: "rename", title: titleDraft.trim()
    } });
  }
  function copy() {
    if (!document || !actionsAllowed || intent.current) return;
    void submitAction({ kind: "copy", epoch: authorityEpoch,
      title: `${Array.from(document.title).slice(0, 150).join("")} copy`, clientId: crypto.randomUUID() });
  }
  function download() {
    if (!document || !actionsAllowed || inFlight.current) return;
    const epoch = authorityEpoch;
    const current = () => active.current && isCurrentAuthority(epoch);
    // Fresh server authority is checked by get; local optimistic text cannot
    // masquerade as a committed export or bypass a pending deletion fence.
    inFlight.current = true; setBusy(true); setActionError(null);
    void api.sharedDocuments.get(id).then(snapshot => {
      if (!current()) return;
      const url = URL.createObjectURL(new Blob([snapshot.title + "\n\n" + snapshot.content], { type: "text/plain;charset=utf-8" }));
      const link = window.document.createElement("a"); link.href = url; link.download = "k-comms-document.txt"; link.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
    }).catch(failure => {
      if (current() && !reportAuthorityFailure(failure)) setActionError("Unable to confirm current authority for export. Try again when connected.");
    }).finally(() => { if (current()) { inFlight.current = false; setBusy(false); } });
  }
  return <section className="document-workspace" aria-label={document.title}>
    <header className="document-toolbar"><div><h2>{document.title}</h2><p role="status" aria-live="polite">{status === "live" ? pendingCount ? `Syncing · ${pendingCount} unsent ${pendingCount === 1 ? "edit" : "edits"}` : "All changes synced" : `Offline · ${pendingCount ? `${pendingCount} unsent ${pendingCount === 1 ? "edit" : "edits"}` : "Showing the last synced version"}`} · Version {document.version}</p></div>
      <div className="document-actions"><button className="button ghost" type="button" disabled={!actionsAllowed || document.readonly} onClick={() => setTitleDraft(document.title)}>Rename</button><button className="button ghost" type="button" disabled={!actionsAllowed} onClick={copy}>Make a copy</button><button className="button ghost" type="button" disabled={!actionsAllowed} onClick={download}>Export text</button></div></header>
    {pendingAction && <p role="status">{busy ? `Confirming ${pendingAction.kind === "copy" ? "the copy" : "the title change"}…` : `A ${pendingAction.kind === "copy" ? "copy" : "title change"} is awaiting confirmation.`} <button className="button ghost" type="button" disabled={!connectionReady || busy} onClick={() => { if (intent.current) void submitAction(intent.current); }}>Retry pending action</button></p>}
    {titleDraft !== null && <form className="document-title-form" onSubmit={event => { event.preventDefault(); void rename(); }}><label className="field">Document title<input value={titleDraft} onChange={event => setTitleDraft(event.target.value)} disabled={!!pendingAction || busy} maxLength={160} autoFocus /></label><button className="button primary" disabled={!actionsAllowed || !titleDraft.trim()}>Save title</button><button className="button ghost" type="button" disabled={!!pendingAction || busy} onClick={() => setTitleDraft(null)}>Cancel</button></form>}
    {(error || actionError) && <p role="alert">{actionError || error}</p>}
    <p className="document-presence" aria-live="polite">{status !== "live" ? "Live presence is unavailable while disconnected." : peers.length ? `${peers.length} other ${peers.length === 1 ? "device is" : "devices are"} editing here. Highlighted text shows their selections.` : "You are editing this document."}</p>
    {document.readonly && <p role="status">This document reached its retained edit limit. Export it or make a lineage-preserving copy to continue.</p>}
    <SharedDocumentEditor content={document.content} atoms={document.atoms} readonly={document.readonly || status === "unavailable"} peers={peers} onEdit={edit} onSelection={presence} onError={setActionError} />
    <footer className="document-disclosure"><p>Plaintext and Markdown · {Array.from(document.content).length.toLocaleString()} / 16,000 characters.</p><details><summary>Document limits and retention</summary><p>Paste up to 2,048 characters per edit.</p><p>Governed deletion of any original author removes this entire document and its copies. Legal holds preserve the content and its edit history.</p><p>Unsent text stays only in this tab. Leaving requires confirmation until edits sync and pending actions finish. Closing the tab or changing your sign-in or permissions clears local work.</p></details></footer>
  </section>;
}
