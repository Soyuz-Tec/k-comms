import { useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router";
import type { ApiClient } from "../../api";
import type { Conversation } from "../../types";
import type { UnifiedResult, UnifiedResultKind, UnifiedSearchPage } from "../../types/rich-content";
import { errorText } from "../../lib/format";
import { useModalDialog } from "../../components/useModalDialog";

const kinds: Array<[UnifiedResultKind | "all", string]> = [["all", "Everything"], ["message", "Messages"], ["file", "Files"], ["whiteboard", "Boards"], ["meeting", "Meetings"], ["recording", "Recordings"], ["transcript", "Transcripts"]];
export function UnifiedSearchPanel({ api, conversations, initialConversationId, onClose }: { api: ApiClient; conversations: Conversation[]; initialConversationId?: string | null; onClose: () => void }) {
  const [query, setQuery] = useState(""); const [kind, setKind] = useState<UnifiedResultKind | "all">("all");
  const [conversation, setConversation] = useState(initialConversationId || "");
  const [data, setData] = useState<UnifiedResult[]>([]); const [page, setPage] = useState<UnifiedSearchPage | null>(null);
  const [busy, setBusy] = useState(false); const [error, setError] = useState(""); const [searched, setSearched] = useState(false);
  const generation = useRef(0); const dialog = useModalDialog(onClose);
  const submitted = useRef({ query: "", kind: "all" as UnifiedResultKind | "all", conversation: "" });
  async function load(cursor: string | null = null) {
    const input = cursor ? submitted.current : { query: query.trim(), kind, conversation };
    if (input.query.length < 2 || busy) return;
    const request = ++generation.current; setBusy(true); setError("");
    try {
      const response = await api.unifiedSearch(input.query, { kind: input.kind, conversation_id: input.conversation || undefined, cursor, limit: 25 });
      if (request !== generation.current) return;
      submitted.current = input; setData(old => cursor ? [...old, ...response.data] : response.data); setPage(response); setSearched(true);
    } catch (e) { if (request === generation.current) {
      if (e && typeof e === "object" && "status" in e && [401, 403, 404].includes(Number(e.status))) {
        setData([]); setPage(null); setSearched(false);
      }
      setError(errorText(e));
    } }
    finally { if (request === generation.current) setBusy(false); }
  }
  function search(e: FormEvent) { e.preventDefault(); void load(); }
  return <div className="modal-backdrop"><section ref={dialog} className="modal-dialog search-panel" role="dialog" aria-modal="true" aria-labelledby="unified-search-title" aria-busy={busy}>
    <header><h2 id="unified-search-title">Search workspace</h2><button type="button" onClick={onClose} aria-label="Close workspace search">Close</button></header>
    <form onSubmit={search}>
      <label>Search messages, files, boards and meetings<input type="search" minLength={2} maxLength={160} value={query} onChange={e => setQuery(e.target.value)} data-initial-focus /></label>
      <label>Content type<select value={kind} onChange={e => setKind(e.target.value as UnifiedResultKind | "all")}>{kinds.map(([value, label]) => <option key={value} value={value}>{label}{page?.facets[value as UnifiedResultKind] !== undefined ? ` (${page.facets[value as UnifiedResultKind]})` : ""}</option>)}</select></label>
      <label>Conversation<select value={conversation} onChange={e => setConversation(e.target.value)}><option value="">All my conversations</option>{conversations.map(item => <option key={item.id} value={item.id}>{item.title || "Conversation"}</option>)}</select></label>
      <button type="submit" disabled={busy || query.trim().length < 2}>Search</button>
    </form>
    {error && <p role="alert">{error} <button type="button" disabled={busy} onClick={() => void load()}>Retry search</button></p>}
    {searched && data.length === 0 && <p>No accessible content matches.</p>}
    <ol aria-label="Ranked search results">{data.map(item => <li key={`${item.kind}:${item.id}`}><Link to={item.path} onClick={onClose}><strong>{item.title}</strong><span> · {kinds.find(([value]) => value === item.kind)?.[1]}</span><p>{item.excerpt}</p></Link></li>)}</ol>
    {page && <p>Results are ranked within authorized source candidates. Meeting search covers a two-year window.{Object.values(page.page.source_limits).some(Boolean) && " Some sources reached their result limit; refine your query to find more."}</p>}
    {page?.page.has_more && <button type="button" disabled={busy} onClick={() => void load(page.page.next_cursor)}>More results</button>}
  </section></div>;
}
