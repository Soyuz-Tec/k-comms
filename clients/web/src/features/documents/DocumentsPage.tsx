import { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import type { DocumentSummary, SharedDocument } from "../../types/sharedDocuments";
import { SharedDocumentEditor } from "./SharedDocumentEditor";
import { useSharedDocument } from "./useSharedDocument";
import "./documents.css";

export function DocumentsPage() {
  const { session } = useSession();
  return <DocumentsForIdentity key={`${session?.tenant.id}:${session?.user.id}:${session?.device.id}`} />;
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
  const createIntent = useRef<{ conversation: string; title: string; id: string } | null>(null);
  useEffect(() => {
    let current = true;
    setDocuments([]); setError(null);
    if (conversationId) {
      setBusy(true);
      api.sharedDocuments.list(conversationId, query).then(values => { if (current) setDocuments(values); })
        .catch(() => { if (current) setError("These documents are unavailable or your access changed."); })
        .finally(() => { if (current) setBusy(false); });
    }
    return () => { current = false; };
  }, [api, conversationId, query, revision, identity]);
  const open = (document: DocumentSummary | SharedDocument) => setParams({ conversation: document.conversation_id, document: document.id });
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  async function create() {
    if (!conversation || !title.trim() || busy) return;
    const context = conversation.id;
    const requestedTitle = title.trim();
    if (createIntent.current?.conversation !== context || createIntent.current.title !== requestedTitle) createIntent.current = { conversation: context, title: requestedTitle, id: crypto.randomUUID() };
    const intent = createIntent.current!;
    setBusy(true); setError(null);
    try {
      const document = await api.sharedDocuments.create(context, intent.title, intent.id);
      if (!active.current || currentConversation.current !== context) return;
      createIntent.current = null;
      open(document); setTitle(""); setRevision(value => value + 1);
    } catch { if (active.current && currentConversation.current === context) setError("Unable to confirm creation. Retry with this same title to recover the original document."); }
    finally { if (active.current && currentConversation.current === context) setBusy(false); }
  }
  if (loading) return <main id="main-content" className="centered-page" aria-busy="true"><p>Opening documents…</p></main>;
  return <main className="documents-page" id="main-content">
    <header className="documents-heading"><div><span className="eyebrow">Conversation collaboration</span><h1>Shared documents</h1><p>Write plaintext and Markdown together. Changes sync with current conversation members.</p></div>
      <label>Conversation<select value={conversation?.id || ""} onChange={event => setParams({ conversation: event.target.value })}>
        {!conversation && <option value="">Choose a conversation</option>}
        {conversations.map(value => <option key={value.id} value={value.id}>{value.title || "Untitled conversation"}</option>)}
      </select></label></header>
    {error && <p role="alert">{error}</p>}
    {!conversation ? <section className="empty-state"><h2>Choose a conversation first</h2><Link to="/app/">Open Inbox</Link></section> : <div className="documents-workspace">
      <aside className="documents-library" aria-label="Conversation documents">
        <label>Find a document<input type="search" value={query} maxLength={160} onChange={event => setQuery(event.target.value)} placeholder="Search title or content" /></label>
        <form onSubmit={event => { event.preventDefault(); void create(); }}><label>New document title<input value={title} maxLength={160} onChange={event => setTitle(event.target.value)} /></label><button type="submit" className="button primary" disabled={busy || !title.trim()}>Create document</button></form>
        <div aria-busy={busy}>{documents.map(document => <button className={`document-library-item ${document.id === documentId ? "selected" : ""}`} key={document.id} onClick={() => open(document)} type="button" aria-current={document.id === documentId ? "page" : undefined}><strong>{document.title}</strong><small>Version {document.version} · {document.readonly ? "Read only" : "Shared"}</small></button>)}
          {!busy && documents.length === 0 && <p>No accessible documents match this conversation.</p>}</div>
      </aside>
      {documentId ? <DocumentWorkspace key={`${identity}:${documentId}`} id={documentId} onCopy={open} onChanged={() => setRevision(value => value + 1)} /> : <section className="document-welcome"><h2>Write together</h2><p>Create meeting notes, an agenda or a shared plan, then edit with your conversation members.</p><p>Documents support up to 16,000 characters. Unsent changes stay in this tab; keep it open until syncing completes.</p></section>}
    </div>}
  </main>;
}

function DocumentWorkspace({ id, onCopy, onChanged }: { id: string; onCopy: (value: SharedDocument) => void; onChanged: () => void }) {
  const { api } = useSession();
  const { document, edit, presence, peers, status, error, pendingCount } = useSharedDocument(id);
  const [titleDraft, setTitleDraft] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  if (!document) return <section className="document-welcome" aria-busy={status === "connecting"}><h2>{status === "unavailable" ? "Document unavailable" : "Opening document…"}</h2>{error && <p role="alert">{error}</p>}</section>;
  const actionsAllowed = status === "live" && pendingCount === 0 && !busy;
  async function rename() {
    if (!document || !actionsAllowed || !titleDraft?.trim()) return;
    setBusy(true); setActionError(null);
    try {
      await api.sharedDocuments.apply(id, { client_operation_id: crypto.randomUUID(), generation: document.generation,
        base_version: document.version, kind: "rename", title: titleDraft.trim() });
      if (!active.current) return;
      setTitleDraft(null); onChanged();
    } catch { setActionError("The title changed or access was withdrawn. Wait for synchronization and try again."); }
    finally { setBusy(false); }
  }
  async function copy() {
    if (!document || !actionsAllowed) return;
    setBusy(true); setActionError(null);
    try { const copied = await api.sharedDocuments.copy(id, `${document.title.slice(0, 150)} copy`, crypto.randomUUID()); if (active.current) { onCopy(copied); onChanged(); } }
    catch { setActionError("Unable to copy this document. A copy retains the original authors’ deletion obligations."); }
    finally { setBusy(false); }
  }
  function download() {
    if (!document || !actionsAllowed) return;
    // Fresh server authority is checked by get; local optimistic text cannot
    // masquerade as a committed export or bypass a pending deletion fence.
    setBusy(true); setActionError(null);
    void api.sharedDocuments.get(id).then(current => {
      if (!active.current) return;
      const url = URL.createObjectURL(new Blob([current.title + "\n\n" + current.content], { type: "text/plain;charset=utf-8" }));
      const link = window.document.createElement("a"); link.href = url; link.download = "k-comms-document.txt"; link.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
    }).catch(() => setActionError("The document is no longer available for export.")).finally(() => setBusy(false));
  }
  return <section className="document-workspace" aria-label={document.title}>
    <header className="document-toolbar"><div><h2>{document.title}</h2><p role="status" aria-live="polite">{pendingCount ? `${pendingCount} unsent ${pendingCount === 1 ? "edit" : "edits"}` : status === "live" ? "All changes synced" : "Connection interrupted"} · Version {document.version}</p></div>
      <div className="document-actions"><button type="button" disabled={!actionsAllowed || document.readonly} onClick={() => setTitleDraft(document.title)}>Rename</button><button type="button" disabled={!actionsAllowed} onClick={() => { void copy(); }}>Make a copy</button><button type="button" disabled={!actionsAllowed} onClick={download}>Export text</button></div></header>
    {titleDraft !== null && <form className="document-title-form" onSubmit={event => { event.preventDefault(); void rename(); }}><label>Document title<input value={titleDraft} onChange={event => setTitleDraft(event.target.value)} maxLength={160} autoFocus /></label><button disabled={!actionsAllowed || !titleDraft.trim()}>Save title</button><button type="button" onClick={() => setTitleDraft(null)}>Cancel</button></form>}
    {(error || actionError) && <p role="alert">{actionError || error}</p>}
    <p className="document-presence" aria-live="polite">{peers.length ? `${peers.length} other ${peers.length === 1 ? "device is" : "devices are"} editing here. Highlighted text shows their selections.` : "You are editing this document."}</p>
    {document.readonly && <p role="status">This document reached its retained edit limit. Export it or make a lineage-preserving copy to continue.</p>}
    <SharedDocumentEditor content={document.content} atoms={document.atoms} readonly={document.readonly || status === "unavailable"} peers={peers} onEdit={edit} onSelection={presence} onError={setActionError} />
    <footer className="document-disclosure"><p>Plaintext and Markdown · {Array.from(document.content).length.toLocaleString()} / 16,000 characters. Paste up to 2,048 characters per edit.</p><p>Governed deletion of any original author removes this entire document and its copies. Legal holds preserve the content and its edit history.</p><p>Unsent changes remain in this tab. Closing it discards changes that have not reached the server.</p></footer>
  </section>;
}
