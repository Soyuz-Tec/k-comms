import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import type { BoardSummary } from "../../types/rich-content";
import { errorText, formatDateTime } from "../../lib/format";

export function BoardGallery({ api, onOpen, conversationTitles }: { api: ApiClient; onOpen: (id: string) => void; conversationTitles?: ReadonlyMap<string, string> }) {
  const [boards, setBoards] = useState<BoardSummary[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(true);
  const [truncated, setTruncated] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let current = true;
    setBusy(true); setError("");
    void api.boardGallery(query).then(page => {
      if (!current) return;
      setBoards(page.data); setTruncated(page.page.truncated);
    }).catch(reason => { if (current) {
      if (reason && typeof reason === "object" && "status" in reason && [401, 403, 404].includes(Number(reason.status))) {
        setBoards([]); setTruncated(false);
      }
      setError(errorText(reason));
    } }).finally(() => { if (current) setBusy(false); });
    return () => { current = false; };
  }, [api, query, attempt]);
  return <section id="whiteboard-gallery" className="board-library board-gallery" aria-label="Whiteboard gallery" aria-busy={busy}>
    <h2>Your conversation boards</h2><p className="board-gallery-help">Resume a recent board below. On the canvas, open Canvas controls to start with a template, or Board history &amp; assets to name your board and save checkpoints.</p>
    <label className="field">Find a board<input type="search" value={query} onChange={e => setQuery(e.target.value)} maxLength={160} /></label>
    {error && <p role="alert">{error} <button className="button ghost" type="button" onClick={() => setAttempt(v => v + 1)}>Retry gallery</button></p>}
    {!busy && !error && boards.length === 0 && <p>No saved boards match. Draw in a conversation to create its board.</p>}
    <ul className="board-gallery-grid">{boards.map(board => <li key={board.id}><button type="button" onClick={() => onOpen(board.conversation_id)}><strong>{board.title}</strong><small>{conversationTitles?.get(board.conversation_id) || "Conversation board"}</small><time dateTime={board.updated_at}>Updated {formatDateTime(board.updated_at)}</time><small>Revision {board.sequence}</small></button></li>)}</ul>
    {truncated && <p role="status">Showing the most recent 30 matches. Refine the board title to find older boards.</p>}
  </section>;
}
