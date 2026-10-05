import { useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { FederationRoom, FederationTimeline } from "../../types/federation";
import { errorText } from "../../lib/format";
import "./FederationPanel.css";
export function FederationPanel({ api, conversationId, canManage }: { api: ApiClient; conversationId: string; canManage: boolean }) {
  const [loaded, setLoaded] = useState(false);
  const [room, setRoom] = useState<FederationRoom | null>(null);
  const [timeline, setTimeline] = useState<FederationTimeline | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [disclosure, setDisclosure] = useState(false);
  const [pending, setPending] = useState<{ key: string; body: string } | null>(null);
  async function run(operation: () => Promise<void>) {
    if (busy) return;
    setBusy(true); setError(null);
    try { await operation(); } catch (reason) { setError(errorText(reason)); } finally { setBusy(false); }
  }
  async function load() { setRoom(await api.federationRoom(conversationId)); setTimeline(null); setLoaded(true); }
  async function exportMetadata() {
    const metadata = await api.exportFederationMetadata(conversationId);
    const url = URL.createObjectURL(new Blob([JSON.stringify(metadata, null, 2)], { type: "application/json" }));
    try { const anchor = document.createElement("a"); anchor.href = url; anchor.download = "federation-local-metadata.json"; anchor.click(); }
    finally { URL.revokeObjectURL(url); }
  }
  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const domain = String(new FormData(event.currentTarget).get("domain") || "");
    if (!disclosure) return;
    await run(async () => { setRoom(await api.createFederationRoom(conversationId, domain)); setLoaded(true); });
  }
  async function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!room) return;
    const form = event.currentTarget;
    const body = String(new FormData(form).get("body") || "");
    const request = pending && pending.body === body ? pending : { key: crypto.randomUUID(), body };
    setPending(request);
    await run(async () => { await api.sendFederationMessage(conversationId, room.version, body, request.key); setPending(null); form.reset(); });
  }
  async function invite(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!room) return;
    const principal = String(new FormData(event.currentTarget).get("principal") || "");
    await run(async () => { setRoom(await api.inviteFederationParticipant(conversationId, room.version, principal)); });
  }
  return <details className="federation-panel" onToggle={event => { if (event.currentTarget.open && !loaded && !busy) void run(load); }}>
    <summary>External workspace federation</summary>
    <p>Messages here use a plaintext Matrix bridge. The configured homeserver and approved remote workspace can read and retain them. Existing K-Comms messages are never sent automatically. This bridge does not provide private room encryption.</p>
    {error && <p role="alert" className="form-error">{error}</p>}
    <button type="button" className="button compact" disabled={busy} onClick={() => void run(load)}>Reload federation state</button>
    {loaded && !room && canManage && <form onSubmit={create}><label className="field">Approved remote server domain<input name="domain" autoComplete="off" maxLength={253} required /></label><label className="checkbox-row"><input type="checkbox" checked={disclosure} onChange={e => setDisclosure(e.target.checked)} />I approve this plaintext bridge and the remote workspace's retention.</label><button className="button primary compact" disabled={busy || !disclosure}>Create external room</button></form>}
    {loaded && !room && !canManage && <p>Ask a conversation owner to create an approved external room.</p>}
    {room && <><dl className="definition-list"><div><dt>Remote workspace</dt><dd>{room.domain}</dd></div><div><dt>Declared residency</dt><dd>{room.residency} (not independently verified)</dd></div><div><dt>Room</dt><dd>{room.status}</dd></div><div><dt>Your consent</dt><dd>{room.consent}</dd></div><div><dt>Remote cleanup</dt><dd>{room.remote_cleanup_state}</dd></div></dl>
      {room.status === "creating" && <p>The durable provider command is pending. Reload after it completes.</p>}
      {room.status === "active" && room.consent === "none" && <><label className="checkbox-row"><input type="checkbox" checked={disclosure} onChange={e => setDisclosure(e.target.checked)} />I consent to sending and receiving plaintext with this remote workspace.</label><button type="button" className="button compact" disabled={busy || !disclosure} onClick={() => void run(async () => setRoom(await api.federationConsent(conversationId, room.version, true)))}>Accept bridge consent</button></>}
      {room.consent === "accepted" && <button type="button" className="button danger compact" disabled={busy} onClick={() => void run(async () => { setRoom(await api.federationConsent(conversationId, room.version, false)); setTimeline(null); })}>Withdraw my consent</button>}
      {room.status === "active" && room.consent === "accepted" && <>
        {canManage && <form onSubmit={invite}><label className="field">Invite a Matrix participant from {room.domain}<input name="principal" placeholder={`@person:${room.domain}`} required maxLength={255} /></label><button className="button compact" disabled={busy}>Send invitation</button><p>They must accept in their own Matrix client. An invitation never joins them automatically.</p></form>}
        <form onSubmit={send}><label className="field">Bridge message<textarea name="body" rows={3} maxLength={8000} required /></label><button className="button primary compact" disabled={busy}>Queue plaintext bridge message</button></form>
        <button type="button" className="button compact" disabled={busy} onClick={() => void run(async () => setTimeline(await api.federationTimeline(conversationId)))}>Load remote messages</button>
        {timeline && <><ol className="federation-messages" aria-label="External workspace messages">{timeline.events.map(event => <li key={event.id}><strong>{event.sender}</strong><p>{event.body}</p><small>{new Date(event.timestamp).toLocaleString()}</small></li>)}</ol>{timeline.cursor && <button type="button" className="button compact" disabled={busy} onClick={() => void run(async () => { const older = await api.federationTimeline(conversationId, timeline.cursor || undefined); setTimeline({ ...older, events: [...timeline.events, ...older.events] }); })}>Load earlier messages</button>}</>}
      </>}
      {canManage && room.status !== "fenced" && <button type="button" className="button danger compact" disabled={busy} onClick={() => void run(async () => { setRoom(await api.closeFederationRoom(conversationId, room.version)); setTimeline(null); })}>Stop bridge and request cleanup</button>}
      {room.remote_cleanup_state !== "none" && <p>Local redaction or leaving a room cannot prove deletion on remote servers. Governance retains the pending obligation.</p>}
      <button type="button" className="button compact" disabled={busy} onClick={() => void run(exportMetadata)}>Download local federation metadata</button>
      <p>This export contains local room metadata and up to 1000 observed event receipts. Remote message content and remote deletion proof are outside this export.</p>
    </>}
  </details>;
}
