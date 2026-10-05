import { useEffect, useState } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { errorText, formatTime } from "../../lib/format";
import type { Message } from "../../types";

export function SavedItemsPage() {
  const { api } = useSession();
  const [items, setItems] = useState<Message[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(true);
  const [cursor, setCursor] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  function accessDenied(reason: unknown) {
    return Boolean(reason && typeof reason === "object" && "status" in reason && [401, 403, 404].includes(Number(reason.status)));
  }
  function fail(reason: unknown) {
    if (accessDenied(reason)) { setItems([]); setCursor(null); }
    setError(errorText(reason));
  }
  useEffect(() => {
    let current = true; setBusy(true); setError("");
    void api.savedItems().then(page => { if (current) { setItems(page.data); setCursor(page.page.next_cursor || null); } })
      .catch(e => { if (current) fail(e); }).finally(() => { if (current) setBusy(false); });
    return () => { current = false; };
  }, [api, attempt]);
  async function more() {
    if (!cursor || busy) return;
    setBusy(true); setError("");
    try { const page = await api.savedItems(cursor); setItems(current => [...current, ...page.data].filter((item, index, all) => all.findIndex(other => other.id === item.id) === index)); setCursor(page.page.next_cursor || null); }
    catch (e) { fail(e); } finally { setBusy(false); }
  }
  async function remove(messageId: string) {
    setError("");
    try { await api.unsaveMessage(messageId); setItems(current => current.filter(item => item.id !== messageId)); }
    catch (e) { fail(e); }
  }
  return <main id="main-content" className="settings-page" aria-busy={busy}>
    <h1>Saved items</h1><p>Only you can see your saved list. A saved message remains available while you have access to its conversation.</p>
    {error && <p role="alert">{error} <button type="button" onClick={() => setAttempt(v => v + 1)}>Retry saved items</button></p>}
    {!busy && !error && items.length === 0 && !cursor && <p>No saved messages yet. Use Save on a message to keep it here.</p>}
    <ul>{items.map(item => <li key={item.id}>
      <Link to={`/app/?conversation=${encodeURIComponent(item.conversation_id)}&message=${encodeURIComponent(item.id)}`}><strong>{item.body || "Attachment message"}</strong><span> · {formatTime(item.inserted_at)}</span></Link>
      <button type="button" onClick={() => void remove(item.id)} aria-label={`Remove saved message ${item.conversation_sequence}`}>Remove</button>
    </li>)}</ul>{cursor && <button type="button" disabled={busy} onClick={() => void more()}>More saved messages</button>}
  </main>;
}
