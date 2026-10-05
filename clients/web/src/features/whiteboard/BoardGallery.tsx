import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import type { BoardSummary } from "../../types/rich-content";
import { errorText } from "../../lib/format";

export function BoardGallery({ api, onOpen }: { api: ApiClient; onOpen: (id: string) => void }) {
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
  return <section className="board-library" aria-label="Whiteboard gallery" aria-busy={busy}>
    <h2>Your conversation boards</h2>
    <label>Find a board<input type="search" value={query} onChange={e => setQuery(e.target.value)} maxLength={160} /></label>
    {error && <p role="alert">{error} <button type="button" onClick={() => setAttempt(v => v + 1)}>Retry gallery</button></p>}
    {!busy && !error && boards.length === 0 && <p>No saved boards match. Draw in a conversation to create its board.</p>}
    <ul className="board-gallery-grid">{boards.map(board => <li key={board.id}><button type="button" onClick={() => onOpen(board.conversation_id)}><strong>{board.title}</strong><span>{new Date(board.updated_at).toLocaleDateString()} · Revision {board.sequence}</span></button></li>)}</ul>
    {truncated && <p role="status">Showing the most recent 30 matches. Refine the board title to find older boards.</p>}
  </section>;
}
