import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AppIcon } from "../../components/AppIcon";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { ConfirmDialog } from "../../components/ActionDialog";
import { useModalDialog } from "../../components/useModalDialog";
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
  const [roomListStatus, setRoomListStatus] = useState<"loading" | "loaded" | "failed">("loading");
  const [error, setError] = useState(""); const [busy, setBusy] = useState(false); const [unlocked, setUnlocked] = useState(false);
  const [forgetDevice, setForgetDevice] = useState(false);
  const [messages, setMessages] = useState<PrivatePlaintext[]>([]); const [body, setBody] = useState("");
  const [title, setTitle] = useState(""); const [query, setQuery] = useState(""); const [people, setPeople] = useState<DirectoryPerson[]>([]); const [selectedPeople, setSelectedPeople] = useState<string[]>([]);
  const [recovery, setRecovery] = useState(""); const [generated, setGenerated] = useState("");
  const [request, setRequest] = useState<VerificationRequest | null>(null); const [sas, setSas] = useState<ShowSasCallbacks | null>(null);
  const [verifyUser, setVerifyUser] = useState(""); const [devices, setDevices] = useState<string[]>([]); const [verifyDevice, setVerifyDevice] = useState("");
  const runtime = useRef<MatrixPrivateClient | null>(null); const pendingCreate = useRef<string | null>(null); const pendingSend = useRef<string | null>(null);
  const alive = useRef(true);
  const cancelVerification = () => { if (busy) return; sas?.cancel(); void request?.cancel(); setSas(null); setRequest(null); };
  const verificationDialog = useModalDialog(cancelVerification, Boolean(request));
  const roomApi = useMemo(() => ({ ...api.privateRoomApi, matrixUploadPublicSigningKeys: (keys: Record<string, unknown>) => runWithStepUp(() => api.privateRoomApi.matrixUploadPublicSigningKeys(keys)) }), [api, runWithStepUp]);
  useEffect(() => {
    alive.current = true;
    setRoomListStatus("loading");
    void roomApi.privateRooms().then((value) => { if (alive.current) { setRooms(value); setRoomListStatus("loaded"); } }).catch((reason: unknown) => { if (alive.current) { setRoomListStatus("failed"); setError(reason instanceof Error ? reason.message : "Private rooms unavailable."); } });
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
  return <main className="page-shell private-rooms-page" aria-label="Private rooms">
    <SurfaceHeader title="Private rooms" description="Send encrypted message text to people you verify." />
    <section className="private-privacy-note" aria-label="Privacy boundaries">
      <AppIcon name="lock" />
      <div><strong>Message text is encrypted between participants.</strong><p>Room titles, membership and timing remain visible to the service. Backup and device-key erasure is not confirmed.</p>
        <details><summary>What private rooms support</summary><p>Message text uses Matrix Rust end-to-end encryption. Private rooms do not support calls, recording, server search, summaries, moderation capture, file uploads, whiteboards, shared documents or server plaintext export.</p><p>Governance erasure remains pending until provider backups and managed device key cleanup can be proven. Removing a participant cannot retract keys or copies they already received.</p></details>
      </div>
    </section>
    {error && <div className="inline-notice error" role="alert">{error}</div>}
    <section className="private-setup-steps" aria-label="Private room setup steps">
      <div><span aria-hidden="true">1</span><div><strong>{unlocked ? "Device unlocked" : "Unlock device"}</strong></div></div>
      <div><span aria-hidden="true">2</span><div><strong>Set up or recover your identity</strong><small>Save a recovery key or use a verified device.</small></div></div>
      <div><span aria-hidden="true">3</span><div><strong>Verify everyone in your room</strong><small>Compare the same symbols before sending.</small></div></div>
    </section>
    <section className="settings-card private-device-card" aria-label="Encrypted device"><div className="card-heading"><h2>Your encrypted device</h2><span className={`status-pill ${unlocked ? "success" : "neutral"}`}>{unlocked ? "Unlocked" : "Locked"}</span></div>
      {!unlocked ? <form className="private-unlock-form" onSubmit={(event) => { event.preventDefault(); const form = event.currentTarget; const password = String(new FormData(form).get("store_password") || ""); form.reset(); void action(async () => {
        const client = new MatrixPrivateClient(roomApi, session!.tenant.id, session!.user.id, { messages: (value) => { if (alive.current) setMessages(value); }, blocked: (message) => { if (alive.current) { setError(message); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setUnlocked(false); setForgetDevice(false); setRequest(null); setSas(null); pendingSend.current = null; } }, verification: (value) => { if (alive.current) setRequest(value); }, sas: (value) => { if (alive.current) setSas(value); } });
        runtime.current = client; await client.unlock(password); if (!alive.current) { await client.close(false); return; } setUnlocked(true);
        const target = rooms.find((value) => value.id === params.get("room")); if (target) await choose(target);
      }); }}><div className="field"><label htmlFor="private-store-password">Local crypto-store password</label><input id="private-store-password" name="store_password" type="password" autoComplete="off" minLength={12} required aria-describedby="private-password-help" /><small id="private-password-help">Use at least 12 characters. This protects this browser's encrypted store and stays on this device.</small></div><div className="form-actions"><button className="button primary" disabled={busy}>{busy ? "Unlocking…" : "Unlock encrypted device"}</button></div><p className="support-note">If you lose this password, use your saved recovery key or a verified second device. K-Comms cannot recover it for you.</p></form> : <>
        <div className="form-actions"><button className="button ghost compact" disabled={busy} onClick={() => void action(async () => { await runtime.current!.close(false); setUnlocked(false); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setRequest(null); setSas(null); pendingSend.current = null; })}>Lock device</button></div>
        <details className="private-disclosure"><summary>Set up or recover encryption</summary>
          <p>For your first device, create an identity and save its recovery key. For an existing identity, recover it or verify this device from another device.</p>
          <button className="button primary compact" disabled={busy || Boolean(generated)} onClick={() => void action(async () => setGenerated(await runtime.current!.prepareRecovery()))}>Set up a new identity and recovery key</button>
          {generated && <div className="private-recovery-key"><label className="field">Save this recovery key securely<textarea readOnly value={generated} spellCheck={false} /></label><p>Store this key somewhere safe before continuing. Anyone who has it can recover your encrypted identity.</p><button className="button primary compact" disabled={busy} onClick={() => void action(async () => { await runtime.current!.confirmRecoverySaved(); setGenerated(""); })}>I saved the key; finish setup</button></div>}
          <form onSubmit={(event) => { event.preventDefault(); const key = recovery; setRecovery(""); void action(async () => runtime.current!.recover(key)); }}><label className="field">Existing recovery key<input type="password" autoComplete="off" value={recovery} onChange={(event) => setRecovery(event.target.value)} required /></label><button className="button ghost compact" disabled={busy}>Recover this identity and history</button></form>
          <p className="support-note">An existing identity is never reset automatically. Verify another existing device with matching symbols (SAS) if recovery secrets are unavailable.</p>
        </details>
        <details className="private-disclosure"><summary>Device details and key removal</summary>
          <p>Matrix identity: <code>{publicDevice?.userId}</code><br />Device: <code>{publicDevice?.deviceId}</code></p>
          <p>Forgetting removes this browser's encrypted store for every private room on this device. Save your recovery key first.</p>
          <button className="button danger compact" disabled={busy} onClick={() => { setError(""); setForgetDevice(true); }}>Lock and forget device keys</button>
        </details>
      </>}
    </section>
    <div className={`private-room-layout${unlocked || room ? "" : " private-room-layout-locked"}`}><aside className="settings-card" aria-label="Private room list"><h2>Your rooms</h2>
      {roomListStatus === "loading" && <p className="empty-copy" role="status">Loading private rooms…</p>}
      {roomListStatus === "failed" && <p className="empty-copy">Your room list could not be loaded.</p>}
      {roomListStatus === "loaded" && rooms.length === 0 && <p className="empty-copy">No private rooms yet.</p>}
      {rooms.map((value) => <button className="button ghost private-room-choice" key={value.id} disabled={busy || !unlocked} aria-pressed={room?.id === value.id} onClick={() => void action(() => choose(value))}><span>{value.title}</span><small>{value.state.replaceAll("_", " ")}</small></button>)}
      <details className="private-disclosure"><summary>Create a new encrypted room</summary><form onSubmit={(event) => { event.preventDefault(); void action(async () => {
        pendingCreate.current ||= crypto.randomUUID(); const created = await roomApi.createPrivateRoom({ id: pendingCreate.current, title, member_ids: selectedPeople });
        pendingCreate.current = null; setRooms((current) => [created, ...current.filter((value) => value.id !== created.id)]); setTitle(""); setSelectedPeople([]); await choose(created);
      }); }}><label className="field">Room title<input value={title} onChange={(event) => { if (!pendingCreate.current) setTitle(event.target.value); }} maxLength={160} required disabled={Boolean(pendingCreate.current)} /></label>
      <label className="field">Find people<input value={query} onChange={(event) => setQuery(event.target.value)} /></label><fieldset className="settings-fieldset" disabled={Boolean(pendingCreate.current)}><legend>Participants (1–19)</legend>{people.map((person) => <label className="private-person-choice" key={person.id}><input type="checkbox" checked={selectedPeople.includes(person.id)} onChange={(event) => setSelectedPeople((current) => event.target.checked ? [...current, person.id].slice(0, 19) : current.filter((id) => id !== person.id))} />{person.display_name}</label>)}</fieldset>
      <p className="support-note">Each person must first enroll their encrypted device here. This creates a separate room; existing conversations keep their current privacy settings.</p><button className="button primary compact" disabled={busy || !unlocked || selectedPeople.length === 0}>{pendingCreate.current ? "Retry the same room creation" : "Create encrypted room"}</button></form></details>
    </aside>{(unlocked || room) && <section className="settings-card private-conversation" aria-label="Encrypted conversation"><h2>{room?.title || "Choose a private room"}</h2>
      {!room && <div className="private-room-empty"><AppIcon name="lock" /><p>Choose a room or create one to start. Verify every participant before you send a message.</p></div>}
      {room && <><p className="support-note">Verify everyone before sending. Membership epoch {room.membership_epoch}.</p><details className="private-disclosure"><summary>Verify participants and other devices</summary><p>Compare the symbols directly with the other person or your other device. Continue only when both devices show the same symbols.</p><label className="field">Participant<select value={verifyUser} onChange={(event) => { const user = event.target.value; setVerifyUser(user); setDevices([]); setVerifyDevice(""); void action(async () => { const value = await runtime.current!.devices(user); setDevices(value); setVerifyDevice(value[0] || ""); }); }}><option value="">Choose a person</option>{room.members.map((member) => <option key={member.user_id} value={member.matrix_user_id}>{people.find((person) => person.id === member.user_id)?.display_name || (member.user_id === session!.user.id ? session!.user.display_name : member.matrix_user_id)}</option>)}</select></label><label className="field">Device<select value={verifyDevice} onChange={(event) => setVerifyDevice(event.target.value)}>{devices.map((device) => <option key={device}>{device}</option>)}</select></label><button className="button primary compact" disabled={busy || !verifyUser || !verifyDevice} onClick={() => void action(async () => runtime.current!.verify(verifyUser, verifyDevice))}>Request SAS verification</button>
      {room.role === "owner" && room.members.filter((member) => member.user_id !== session!.user.id).map((member) => <button className="button danger compact" key={member.user_id} disabled={busy} onClick={() => void action(async () => { const updated = await roomApi.removePrivateMember(room.id, member.user_id, room.membership_epoch); setRoom(updated); setRooms((current) => current.map((value) => value.id === updated.id ? updated : value)); setMessages([]); })}>Remove {member.matrix_user_id} and rekey</button>)}</details>
      <button className="button ghost compact" disabled={busy || !unlocked} onClick={() => void action(async () => runtime.current!.loadEarlier())}>Load earlier encrypted history</button>
      <ol className="private-message-list" aria-live="polite">{messages.map((message) => <li key={message.id}><strong>{message.sender}</strong><p>{message.body}</p></li>)}</ol>
      <form onSubmit={(event) => { event.preventDefault(); void action(async () => { pendingSend.current ||= crypto.randomUUID(); await runtime.current!.send(body, pendingSend.current); pendingSend.current = null; setBody(""); }); }}><label className="field">Encrypted message<textarea value={body} onChange={(event) => { if (!pendingSend.current) setBody(event.target.value); }} disabled={!unlocked || Boolean(pendingSend.current)} maxLength={16000} required /></label><button className="button primary compact" disabled={busy || !unlocked || !body.trim()}>{pendingSend.current ? "Retry the same encrypted send" : "Send encrypted message"}</button></form>
      <details className="private-disclosure"><summary>Message history and retry details</summary><p>Only authenticated, verified encrypted events are displayed. Draft text stays in memory. Submitted encrypted intents are retained for exact retry by your current session; old membership generations cannot resume.</p></details></>}
    </section>}</div>
    {forgetDevice && <ConfirmDialog title="Forget this device's encryption keys?" description="This removes the encrypted store for every private room on this browser device." impact="Save your recovery key or verify another device first. This action does not prove deletion of provider backups, other devices or recipient copies." confirmLabel="Lock and forget device keys" tone="danger" busy={busy} error={error} onCancel={() => { if (!busy) setForgetDevice(false); }} onConfirm={() => void action(async () => { await runtime.current!.close(true); setUnlocked(false); setMessages([]); setBody(""); setGenerated(""); setRecovery(""); setRequest(null); setSas(null); pendingSend.current = null; setForgetDevice(false); })} />}
    {request && createPortal(<div className="modal-backdrop"><section ref={verificationDialog} className="modal-dialog private-verification" role="dialog" aria-modal="true" aria-label="Verify encryption identity" tabIndex={-1}><h2>Verify with {request.otherUserId}</h2><p>Device {request.otherDeviceId}. Compare the symbols (SAS) directly with the other person or your other device.</p>
      {!sas ? <button className="button primary" disabled={busy} onClick={() => void action(async () => { await runtime.current!.acceptVerification(request); setRequest(null); setSas(null); })}>Accept and show SAS</button> : <><p className="private-sas">{sas.sas.emoji?.map(([emoji, name]) => `${emoji} ${name}`).join(" · ") || sas.sas.decimal?.join(" · ")}</p><div className="form-actions"><button className="button primary" disabled={busy} onClick={() => void action(async () => sas.confirm())}>Both devices show the same SAS</button><button className="button danger" disabled={busy} onClick={() => { sas.mismatch(); setSas(null); setRequest(null); }}>SAS differs; cancel</button></div></>}
      <button className="button ghost" disabled={busy} onClick={cancelVerification}>Cancel verification</button>
    </section></div>, document.body)}
  </main>;
}
