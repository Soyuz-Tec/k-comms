import { useCallback, useEffect, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { errorText, formatDateTime } from "../../lib/format";
import type { VoicemailMessage, VoicemailPlayback } from "./voicemailTypes";
import { approvedVoicemailPlayback } from "./voicemailTypes";

export function VoicemailPanel() {
  const { api } = useSession();
  const [messages, setMessages] = useState<VoicemailMessage[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [configured, setConfigured] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [playing, setPlaying] = useState<{ id: string; signed: VoicemailPlayback } | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const generation = useRef(0);
  const load = useCallback(async (next: string | null = null) => {
    const version = ++generation.current;
    setLoading(true); setError(null);
    try {
      const page = await api.voicemails({ cursor: next });
      if (generation.current !== version) return;
      setConfigured(page.configured);
      setMessages(current => next ? [...current, ...page.data.filter(message => !current.some(item => item.id === message.id))] : page.data);
      setCursor(page.page.has_more ? page.page.next_cursor : null);
    } catch (reason) { if (generation.current === version) setError(errorText(reason)); }
    finally { if (generation.current === version) setLoading(false); }
  }, [api]);
  useEffect(() => { void load(); return () => { generation.current += 1; }; }, [load]);
  useEffect(() => {
    if (!messages.some(message => message.status === "pending" || message.status === "deleting")) return;
    const timer = window.setTimeout(() => { if (!document.hidden && !busy) void load(); }, 5_000);
    return () => window.clearTimeout(timer);
  }, [messages, busy, load]);
  useEffect(() => {
    if (!playing) return;
    const timer = window.setTimeout(() => setPlaying(null), Math.max(0, Date.parse(playing.signed.expires_at) - Date.now()));
    return () => window.clearTimeout(timer);
  }, [playing]);
  async function play(message: VoicemailMessage) {
    setBusy(message.id); setError(null); setPlaying(null);
    const version = generation.current;
    try {
      const signed = await api.voicemailPlayback(message.id);
      if (generation.current !== version) return;
      if (!approvedVoicemailPlayback(signed)) throw new Error("Playback could not be verified. Refresh voicemail and try again.");
      setPlaying({ id: message.id, signed });
    } catch (reason) { if (generation.current === version) setError(errorText(reason)); }
    finally { if (generation.current === version) setBusy(null); }
  }
  async function read(id: string) {
    try {
      const message = await api.markVoicemailRead(id);
      setMessages(current => current.map(item => item.id === id ? message : item));
    } catch (reason) { setError(errorText(reason)); setPlaying(null); }
  }
  async function remove(id: string) {
    setBusy(id); setError(null);
    try {
      await api.deleteVoicemail(id);
      setPlaying(null); setConfirming(null);
      setMessages(current => current.map(item => item.id === id ? { ...item, status: "deleting" } : item));
    } catch (reason) { setError(errorText(reason)); }
    finally { setBusy(null); }
  }
  return <section className="phone-voicemail" aria-labelledby="voicemail-heading">
    <header><h2 id="voicemail-heading">Voicemail</h2><button type="button" className="button ghost" disabled={loading || Boolean(busy)} onClick={() => { setPlaying(null); void load(); }}>Refresh voicemail</button></header>
    {!loading && !configured && <p>Voicemail capture needs a verified phone provider and protected storage. Existing messages remain available according to your access and retention policy.</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {loading && <p role="status">Loading voicemail…</p>}
    {!loading && !error && messages.length === 0 && <p>No voicemail messages.</p>}
    <ul className="phone-history-list">{messages.map(message => <li key={message.id}>
      <div><strong>{message.read_at ? "Voicemail" : "Unread voicemail"}</strong><time dateTime={message.inserted_at}>{formatDateTime(message.inserted_at)}</time>
        <span>{message.status === "pending" ? "Recording is being processed" : message.status === "deleting" ? "Deletion in progress" : message.status === "failed" ? "Recording unavailable" : `${message.duration_seconds ?? 0} seconds`}</span>
        <span>Retained until {formatDateTime(message.retention_expires_at)}</span>
        {playing?.id === message.id && <audio controls autoPlay src={playing.signed.url} aria-label="Voicemail playback" onPlay={() => void read(message.id)} onError={() => { setPlaying(null); setError("Playback expired or became unavailable. Refresh voicemail and try again."); }} />}
      </div>
      {message.status === "available" && <button type="button" className="button ghost" disabled={Boolean(busy)} onClick={() => void play(message)}>Listen to voicemail</button>}
      {message.status !== "deleting" && <button type="button" className="button ghost" disabled={Boolean(busy)} onClick={() => setConfirming(message.id)}>Delete voicemail</button>}
      {confirming === message.id && <div role="group" aria-label="Confirm voicemail deletion"><p>Delete this voicemail? This removes the recording after retention and legal hold checks.</p><button type="button" className="button ghost" disabled={Boolean(busy)} onClick={() => void remove(message.id)}>Confirm deletion</button><button type="button" className="button ghost" disabled={Boolean(busy)} onClick={() => setConfirming(null)}>Keep voicemail</button></div>}
    </li>)}</ul>
    {cursor && <button type="button" className="button ghost" disabled={loading} onClick={() => void load(cursor)}>Load more voicemail</button>}
  </section>;
}
