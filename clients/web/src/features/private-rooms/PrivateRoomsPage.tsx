import { useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "react-router";
import type { VerificationRequest, ShowSasCallbacks } from "matrix-js-sdk/lib/crypto-api";
import { useSession } from "../../app/session";
import { useStepUp } from "../../app/step-up";
import type { DirectoryPerson } from "../../types";
import { MatrixPrivateClient, type PrivatePlaintext } from "./MatrixPrivateClient";
import type { PrivateRoom } from "./types";
import "./private-rooms.css";

export function PrivateRoomsPage() {
  const { session } = useSession();
  return session ? <PrivateRoomsWorkspace key={`${session.tenant.id}:${session.user.id}:${session.device.id}`} /> : null;
}
function PrivateRoomsWorkspace() {
  const { api, session } = useSession(); const { runWithStepUp } = useStepUp();
  const [params, setParams] = useSearchParams();
  const [rooms, setRooms] = useState<PrivateRoom[]>([]); const [room, setRoom] = useState<PrivateRoom | null>(null);
  const [error, setError] = useState(""); const [busy, setBusy] = useState(false); const [unlocked, setUnlocked] = useState(false);
  const [messages, setMessages] = useState<PrivatePlaintext[]>([]); const [body, setBody] = useState("");
  const [title, setTitle] = useState(""); const [query, setQuery] = useState(""); const [people, setPeople] = useState<DirectoryPerson[]>([]); const [selectedPeople, setSelectedPeople] = useState<string[]>([]);
  const [recovery, setRecovery] = useState(""); const [generated, setGenerated] = useState("");
  const [request, setRequest] = useState<VerificationRequest | null>(null); const [sas, setSas] = useState<ShowSasCallbacks | null>(null);
  const [verifyUser, setVerifyUser] = useState(""); const [devices, setDevices] = useState<string[]>([]); const [verifyDevice, setVerifyDevice] = useState("");
  const runtime = useRef<MatrixPrivateClient | null>(null); const pendingCreate = useRef<string | null>(null); const pendingSend = useRef<string | null>(null);
  const alive = useRef(true);
  const roomApi = useMemo(() => ({ ...api.privateRoomApi, matrixUploadPublicSigningKeys: (keys: Record<string, unknown>) => runWithStepUp(() => api.privateRoomApi.matrixUploadPublicSigningKeys(keys)) }), [api, runWithStepUp]);
  useEffect(() => {
    alive.current = true;
    void roomApi.privateRooms().then((value) => { if (alive.current) setRooms(value); }).catch((reason: unknown) => { if (alive.current) setError(reason instanceof Error ? reason.message : "Private rooms unavailable."); });
    return () => { alive.current = false; void runtime.current?.close(false); runtime.current = null; };
  }, [roomApi]);
  useEffect(() => {
    const controller = new AbortController();
    void api.directoryUsers(query, 25).then((page) => { if (!controller.signal.aborted) setPeople(page.data.filter((person) => person.id !== session!.user.id)); }).catch(() => undefined);
    return () => controller.abort();
  }, [api, query, session]);
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => { if (body || generated || pendingSend.current) { event.preventDefault(); event.returnValue = ""; } };
    window.addEventListener("beforeunload", warn); return () => window.removeEventListener("beforeunload", warn);
  }, [body, generated]);
  async function action(operation: () => Promise<void>) {
    setBusy(true); setError("");
    try { await operation(); } catch (reason: unknown) { if (alive.current) setError(reason instanceof Error ? reason.message : "Private operation failed."); }
    finally { if (alive.current) setBusy(false); }
  }
  async function choose(value: PrivateRoom) {
    if (body || pendingSend.current) throw new Error("Resolve the current message before switching encrypted rooms.");
    if (!runtime.current) throw new Error("Unlock your encrypted device first.");
    await runtime.current.select(value); if (!alive.current) return;
    const current = await roomApi.privateRoom(value.id); setRoom(current); setParams({ room: current.id });
  }
  const publicDevice = runtime.current?.publicDevice();
  return <main className="private-rooms-page" aria-labelledby="private-rooms-heading">
    <header><h1 id="private-rooms-heading">Private rooms</h1><p>Message text uses Matrix Rust end-to-end encryption. Room titles, membership and timing remain visible to the service.</p></header>
    <p className="private-mode-notice">Private rooms do not support recording, server search, summaries, moderation capture, file uploads or server plaintext export. Governance erasure remains pending until provider backups and managed device key cleanup can be proven.</p>
    {error && <p role="alert">{error}</p>}
    <section aria-label="Encrypted device"><h2>Your encrypted device</h2>
      {!unlocked ? <form onSubmit={(event) => { event.preventDefault(); const form = event.currentTarget; const password = String(new FormData(form).get("store_password") || ""); form.reset(); void action(async () => {
        const client = new MatrixPrivateClient(roomApi, session!.tenant.id, session!.user.id, { messages: (value) => { if (alive.current) setMessages(value); }, blocked: (message) => { if (alive.current) { setError(message); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setUnlocked(false); setRequest(null); setSas(null); pendingSend.current = null; } }, verification: (value) => { if (alive.current) setRequest(value); }, sas: (value) => { if (alive.current) setSas(value); } });
        runtime.current = client; await client.unlock(password); if (!alive.current) { await client.close(false); return; } setUnlocked(true);
        const target = rooms.find((value) => value.id === params.get("room")); if (target) await choose(target);
      }); }}><label>Local crypto-store password <input name="store_password" type="password" autoComplete="off" minLength={12} required /></label><button disabled={busy}>Unlock encrypted device</button><p>This password protects the browser’s SDK crypto store. It stays on this device; use your recovery key or verified second device if you lose it.</p></form> : <>
        <p>Matrix identity: <code>{publicDevice?.userId}</code><br />Device: <code>{publicDevice?.deviceId}</code></p>
        <button disabled={busy} onClick={() => void action(async () => { await runtime.current!.close(false); setUnlocked(false); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setRequest(null); setSas(null); pendingSend.current = null; })}>Lock device</button>
        <button disabled={busy} onClick={() => void action(async () => { await runtime.current!.close(true); setUnlocked(false); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setRequest(null); setSas(null); pendingSend.current = null; })}>Lock and forget device keys</button>
        <p>Forgetting removes this browser crypto store for every private room on this Matrix device. Save recovery first.</p>
        <details><summary>Set up or recover encryption</summary>
          <button disabled={busy || Boolean(generated)} onClick={() => void action(async () => setGenerated(await runtime.current!.prepareRecovery()))}>Set up a new identity and recovery key</button>
          {generated && <div><label>Save this recovery key securely <textarea readOnly value={generated} spellCheck={false} /></label><button disabled={busy} onClick={() => void action(async () => { await runtime.current!.confirmRecoverySaved(); setGenerated(""); })}>I saved the key; finish setup</button></div>}
          <form onSubmit={(event) => { event.preventDefault(); const key = recovery; setRecovery(""); void action(async () => runtime.current!.recover(key)); }}><label>Existing recovery key <input type="password" autoComplete="off" value={recovery} onChange={(event) => setRecovery(event.target.value)} required /></label><button disabled={busy}>Recover this identity and history</button></form>
          <p>An existing identity is never reset automatically. Verify another existing device with matching SAS if recovery secrets are unavailable.</p>
        </details>
      </>}
    </section>
    <div className="private-room-layout"><aside aria-label="Private room list"><h2>Your rooms</h2>{rooms.map((value) => <button key={value.id} disabled={busy || !unlocked} aria-pressed={room?.id === value.id} onClick={() => void action(() => choose(value))}>{value.title} <small>{value.state.replaceAll("_", " ")}</small></button>)}
      <details><summary>Create a new encrypted room</summary><form onSubmit={(event) => { event.preventDefault(); void action(async () => {
        pendingCreate.current ||= crypto.randomUUID(); const created = await roomApi.createPrivateRoom({ id: pendingCreate.current, title, member_ids: selectedPeople });
        pendingCreate.current = null; setRooms((current) => [created, ...current.filter((value) => value.id !== created.id)]); setTitle(""); setSelectedPeople([]); await choose(created);
      }); }}><label>Room title <input value={title} onChange={(event) => { if (!pendingCreate.current) setTitle(event.target.value); }} maxLength={160} required disabled={Boolean(pendingCreate.current)} /></label>
      <label>Find people <input value={query} onChange={(event) => setQuery(event.target.value)} /></label><fieldset disabled={Boolean(pendingCreate.current)}><legend>Participants (1–19)</legend>{people.map((person) => <label key={person.id}><input type="checkbox" checked={selectedPeople.includes(person.id)} onChange={(event) => setSelectedPeople((current) => event.target.checked ? [...current, person.id].slice(0, 19) : current.filter((id) => id !== person.id))} />{person.display_name}</label>)}</fieldset>
      <p>Each person must first enroll their Matrix device here. Room creation never converts an existing conversation.</p><button disabled={busy || !unlocked || selectedPeople.length === 0}>{pendingCreate.current ? "Retry the same room creation" : "Create encrypted room"}</button></form></details>
    </aside><section aria-label="Encrypted conversation"><h2>{room?.title || "Choose a private room"}</h2>
      {room && <><p>Membership epoch {room.membership_epoch}. Verify everyone before sending.</p><details><summary>Verify participants and other devices</summary><label>Participant <select value={verifyUser} onChange={(event) => { const user = event.target.value; setVerifyUser(user); setDevices([]); setVerifyDevice(""); void action(async () => { const value = await runtime.current!.devices(user); setDevices(value); setVerifyDevice(value[0] || ""); }); }}><option value="">Choose a person</option>{room.members.map((member) => <option key={member.user_id} value={member.matrix_user_id}>{member.matrix_user_id}</option>)}</select></label><label>Device <select value={verifyDevice} onChange={(event) => setVerifyDevice(event.target.value)}>{devices.map((device) => <option key={device}>{device}</option>)}</select></label><button disabled={busy || !verifyUser || !verifyDevice} onClick={() => void action(async () => runtime.current!.verify(verifyUser, verifyDevice))}>Request SAS verification</button>
      {room.role === "owner" && room.members.filter((member) => member.user_id !== session!.user.id).map((member) => <button key={member.user_id} disabled={busy} onClick={() => void action(async () => { const updated = await roomApi.removePrivateMember(room.id, member.user_id, room.membership_epoch); setRoom(updated); setRooms((current) => current.map((value) => value.id === updated.id ? updated : value)); setMessages([]); })}>Remove {member.matrix_user_id} and rekey</button>)}</details>
      <button disabled={busy || !unlocked} onClick={() => void action(async () => runtime.current!.loadEarlier())}>Load earlier encrypted history</button>
      <ol className="private-message-list" aria-live="polite">{messages.map((message) => <li key={message.id}><strong>{message.sender}</strong><p>{message.body}</p></li>)}</ol>
      <form onSubmit={(event) => { event.preventDefault(); void action(async () => { pendingSend.current ||= crypto.randomUUID(); await runtime.current!.send(body, pendingSend.current); pendingSend.current = null; setBody(""); }); }}><label>Encrypted message <textarea value={body} onChange={(event) => { if (!pendingSend.current) setBody(event.target.value); }} disabled={!unlocked || Boolean(pendingSend.current)} maxLength={16000} required /></label><button disabled={busy || !unlocked || !body.trim()}>{pendingSend.current ? "Retry the same encrypted send" : "Send encrypted message"}</button></form>
      <p>Only authenticated, verified encrypted events are displayed. Draft text stays in memory. Submitted encrypted intents are retained for exact retry by your current session; old membership generations cannot resume.</p></>}
    </section></div>
    {request && <section className="private-verification" role="dialog" aria-modal="true" aria-label="Verify encryption identity"><h2>Verify with {request.otherUserId}</h2><p>Device {request.otherDeviceId}. Compare the SAS directly with the other person or your other device.</p>
      {!sas ? <button disabled={busy} onClick={() => void action(async () => { await runtime.current!.acceptVerification(request); setRequest(null); setSas(null); })}>Accept and show SAS</button> : <><p className="private-sas">{sas.sas.emoji?.map(([emoji, name]) => `${emoji} ${name}`).join(" · ") || sas.sas.decimal?.join(" · ")}</p><button onClick={() => void action(async () => sas.confirm())}>Both devices show the same SAS</button><button onClick={() => { sas.mismatch(); setSas(null); setRequest(null); }}>SAS differs; cancel</button></>}
      <button onClick={() => { sas?.cancel(); void request.cancel(); setSas(null); setRequest(null); }}>Cancel verification</button>
    </section>}
  </main>;
}
