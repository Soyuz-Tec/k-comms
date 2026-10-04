import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { Link } from "react-router";
import { ApiError } from "../../api";
import { useSession } from "../../app/session";
import { useCallSession } from "../calls/CallSessionProvider";
import { errorText } from "../../lib/format";
import { phoneCallIsActive, phoneCallLabel, otherPhoneNumber } from "./types";
import type { PhoneCall, PhoneConfiguration, PhoneSession } from "./types";
import type { PhoneMedia, PhoneMediaState } from "./phoneMedia";
import { CALL_SESSION_TEARDOWN_EVENT } from "../calls/callSessionEvents";
import { setPhoneMediaBusy } from "./mediaOwnership";
import { usePhoneRingtone } from "./usePhoneRingtone";
import "./telephony.css";

interface PhoneContext {
  configuration: PhoneConfiguration | null;
  loading: boolean;
  error: string | null;
  activeCalls: PhoneCall[];
  currentCall: PhoneCall | null;
  busy: boolean;
  conversationBusy: boolean;
  refresh: () => Promise<void>;
  dial: (destination: string) => Promise<void>;
  answer: (call: PhoneCall) => Promise<void>;
  join: (call: PhoneCall) => Promise<void>;
  reject: (call: PhoneCall) => Promise<void>;
  end: () => Promise<void>;
}

const TelephonyContext = createContext<PhoneContext | null>(null);

export function TelephonyProvider({ children }: { children: ReactNode }) {
  const { api, session, mediaActionsAllowed } = useSession();
  const conversation = useCallSession();
  const conversationBusy = Boolean(conversation.launchRequest) || Boolean(conversation.sessionState &&
    (conversation.sessionState.joined || ["prejoin", "joining", "leaving"].includes(conversation.sessionState.phase)));
  const [configuration, setConfiguration] = useState<PhoneConfiguration | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [activeCalls, setActiveCalls] = useState<PhoneCall[]>([]);
  const [currentCall, setCurrentCall] = useState<PhoneCall | null>(null);
  const [busy, setBusy] = useState(false);
  const [mediaState, setMediaState] = useState<PhoneMediaState | null>(null);
  const [playbackBlocked, setPlaybackBlocked] = useState(false);
  const [muted, setMuted] = useState(false);
  const mediaRef = useRef<PhoneMedia | null>(null);
  const audioRef = useRef<HTMLDivElement | null>(null);
  const callRef = useRef<PhoneCall | null>(null);
  const operation = useRef(0);
  const actionBusy = useRef(false);
  const polling = useRef(false);
  const alive = useRef(true);
  const ending = useRef<{ callId: string; promise: Promise<void> } | null>(null);

  const releaseMedia = useCallback(() => {
    mediaRef.current?.disconnect();
    mediaRef.current = null;
    setMediaState(null);
    setPlaybackBlocked(false);
    setMuted(false);
  }, []);

  const reconcile = useCallback((call: PhoneCall) => {
    callRef.current = call;
    setCurrentCall(call);
    if (!phoneCallIsActive(call) || !call.active_on_this_device) {
      operation.current += 1;
      releaseMedia();
      setPhoneMediaBusy(false);
      actionBusy.current = false;
      setBusy(false);
      if (phoneCallIsActive(call)) {
        callRef.current = null;
        setCurrentCall(null);
      }
    }
  }, [releaseMedia]);

  const endOwnedCall = useCallback((): Promise<void> => {
    const call = callRef.current;
    if (!call?.active_on_this_device || !phoneCallIsActive(call)) return Promise.resolve();
    if (ending.current?.callId === call.id) return ending.current.promise;
    const version = ++operation.current;
    actionBusy.current = true;
    setBusy(true);
    setError(null);
    releaseMedia();
    const promise = Promise.resolve().then(async () => {
      try {
        const result = await api.endPhoneCall(call.id);
        if (alive.current && version === operation.current) reconcile(result);
      } catch (reason: unknown) {
        if (alive.current && version === operation.current) {
          // Keep ownership and End controls until the durable phone leg ends.
          setError(`Hanging up failed. Retry End call. ${errorText(reason)}`);
        }
      } finally {
        if (ending.current?.callId === call.id) ending.current = null;
        if (alive.current) { actionBusy.current = false; setBusy(false); }
      }
    });
    ending.current = { callId: call.id, promise };
    return promise;
  }, [api, reconcile, releaseMedia]);

  const loadActive = useCallback(async () => {
    if (polling.current || !alive.current) return;
    polling.current = true;
    const version = operation.current;
    try {
      const result = await api.phoneCalls({ scope: "active", limit: 30 });
      if (!alive.current || version !== operation.current) return;
      setActiveCalls(result.data);
      const owned = callRef.current;
      if (owned && phoneCallIsActive(owned)) {
        const latest = result.data.find(({ id }) => id === owned.id) ?? await api.phoneCall(owned.id);
        if (alive.current && version === operation.current) reconcile(latest);
      }
    } catch (reason: unknown) {
      if (alive.current && version === operation.current) {
        if (reason instanceof ApiError && [401, 403].includes(reason.status)) {
          operation.current += 1;
          releaseMedia();
          callRef.current = null;
          setCurrentCall(null);
          setActiveCalls([]);
          setPhoneMediaBusy(false);
          actionBusy.current = false;
          setBusy(false);
        }
        setError(`Phone updates are unavailable. ${errorText(reason)}`);
      }
    } finally { polling.current = false; }
  }, [api, reconcile, releaseMedia]);

  const refresh = useCallback(async () => {
    try {
      const result = await api.phoneConfiguration();
      if (!alive.current) return;
      setConfiguration(result);
      setError(null);
      if (result.enabled && result.configured && result.number) await loadActive();
      else {
        setActiveCalls([]);
        if (!result.enabled || !result.number) {
          const owned = callRef.current;
          if (owned?.active_on_this_device && phoneCallIsActive(owned)) await endOwnedCall();
          else {
            operation.current += 1;
            releaseMedia();
            callRef.current = null;
            setCurrentCall(null);
            setPhoneMediaBusy(false);
            actionBusy.current = false;
            setBusy(false);
          }
        }
      }
    } catch (reason: unknown) {
      if (alive.current) {
        if (reason instanceof ApiError && [401, 403].includes(reason.status)) {
          operation.current += 1;
          releaseMedia();
          callRef.current = null;
          setCurrentCall(null);
          setActiveCalls([]);
          setPhoneMediaBusy(false);
          actionBusy.current = false;
          setBusy(false);
        }
        setError(errorText(reason));
      }
    } finally { if (alive.current) setLoading(false); }
  }, [api, loadActive, endOwnedCall, releaseMedia]);

  useEffect(() => {
    alive.current = true;
    void refresh();
    return () => {
      alive.current = false;
      operation.current += 1;
      mediaRef.current?.disconnect();
      mediaRef.current = null;
      setPhoneMediaBusy(false);
      const owned = callRef.current;
      if (owned?.active_on_this_device && phoneCallIsActive(owned) && ending.current?.callId !== owned.id) void api.endPhoneCall(owned.id).catch(() => undefined);
    };
  }, [refresh, session?.user.id, session?.device.id]);

  useEffect(() => {
    const enabled = configuration?.enabled && configuration.configured && configuration.number;
    const poll = () => { if (enabled && document.visibilityState === "visible") void loadActive(); };
    const focus = () => { void refresh(); };
    const timer = window.setInterval(poll, 3_000);
    window.addEventListener("focus", focus);
    window.addEventListener("online", focus);
    document.addEventListener("visibilitychange", poll);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", focus);
      window.removeEventListener("online", focus);
      document.removeEventListener("visibilitychange", poll);
    };
  }, [configuration, loadActive, refresh]);

  async function connectAction(action: () => Promise<PhoneSession>, reconnectCallId?: string) {
    if (actionBusy.current) return;
    if (callRef.current && phoneCallIsActive(callRef.current) && callRef.current.id !== reconnectCallId) { setError("End your current phone call first."); return; }
    if (conversationBusy) { setError("Leave your conversation call before using the phone."); return; }
    if (mediaActionsAllowed === false || window.isSecureContext === false) {
      setError("Phone audio requires a secure HTTPS connection."); return;
    }
    if (!navigator.mediaDevices?.getUserMedia) { setError("This browser does not provide microphone access."); return; }
    actionBusy.current = true;
    setPhoneMediaBusy(true);
    const version = ++operation.current;
    setBusy(true);
    setError(null);
    try {
      // Permission is requested before reserving an incoming call or dialing.
      const preview = await navigator.mediaDevices.getUserMedia({ audio: true });
      preview.getTracks().forEach((track) => track.stop());
      if (!alive.current || version !== operation.current) return;
      const result = await action();
      if (!alive.current || version !== operation.current) {
        if (result.data.active_on_this_device) void api.endPhoneCall(result.data.id).catch(() => undefined);
        return;
      }
      callRef.current = result.data;
      setCurrentCall(result.data);
      const { PhoneMedia: Media } = await import("./phoneMedia");
      if (!alive.current || version !== operation.current || !audioRef.current) return;
      releaseMedia();
      const media = new Media(result.credential, audioRef.current,
        (state) => { if (alive.current && version === operation.current) setMediaState(state); },
        (blocked) => { if (alive.current && version === operation.current) setPlaybackBlocked(blocked); });
      mediaRef.current = media;
      await media.connect(result.credential);
      if (!alive.current || version !== operation.current) { media.disconnect(); return; }
    } catch (reason: unknown) {
      if (!alive.current || version !== operation.current) return;
      releaseMedia();
      setError(`Phone audio could not connect. ${errorText(reason)}`);
      const call = callRef.current;
      if (call?.active_on_this_device && phoneCallIsActive(call)) {
        try { reconcile(await api.endPhoneCall(call.id)); }
        catch { setError("Phone audio could not connect, and hanging up failed. Retry End call to release the phone line."); }
      }
    } finally {
      if (alive.current && version === operation.current) {
        actionBusy.current = false;
        setBusy(false);
        if (!callRef.current || !phoneCallIsActive(callRef.current)) setPhoneMediaBusy(false);
        void loadActive();
      }
    }
  }

  async function reject(call: PhoneCall) {
    if (actionBusy.current) return;
    actionBusy.current = true;
    setBusy(true);
    setError(null);
    try { await api.rejectPhoneCall(call.id); await loadActive(); }
    catch (reason: unknown) { setError(errorText(reason)); }
    finally { actionBusy.current = false; setBusy(false); }
  }

  async function end() {
    await endOwnedCall();
    await loadActive();
  }

  useEffect(() => {
    const teardown = () => { void end(); };
    window.addEventListener(CALL_SESSION_TEARDOWN_EVENT, teardown);
    return () => window.removeEventListener(CALL_SESSION_TEARDOWN_EVENT, teardown);
  });

  async function toggleMute() {
    if (!mediaRef.current) return;
    try { await mediaRef.current.setMuted(!muted); setMuted(!muted); }
    catch (reason: unknown) { setError(errorText(reason)); }
  }

  const incoming = activeCalls.filter((call) => call.direction === "inbound" && call.can_answer && call.id !== currentCall?.id);
  const ringtone = usePhoneRingtone(incoming.length > 0);
  const ownsActive = Boolean(currentCall && phoneCallIsActive(currentCall));
  return <TelephonyContext.Provider value={{ configuration, loading, error, activeCalls, currentCall, busy,
    conversationBusy, refresh,
    dial: (destination) => connectAction(() => api.dialPhone(destination, crypto.randomUUID())),
    answer: (call) => connectAction(() => api.answerPhoneCall(call.id)),
    join: (call) => connectAction(() => api.joinPhoneCall(call.id), call.id),
    reject, end }}>
    {children}
    <div ref={audioRef} hidden aria-hidden="true" />
    {(incoming.length > 0 || currentCall) && <aside className="phone-call-dock" aria-label="Phone call controls">
      {error && !currentCall && <p className="form-error" role="alert">{error}</p>}
      {incoming.map((call) => <section key={call.id} aria-label={`Incoming call from ${call.from_number}`}>
        <p role="status"><strong>Incoming phone call</strong><span>{call.from_number}</span></p>
        {ringtone.blocked && !ringtone.muted && <p>Ringtone audio is blocked by this browser. <button className="button ghost" type="button" onClick={() => void ringtone.enable()}>Enable ringtone</button></p>}
        <button className="button ghost" type="button" aria-pressed={ringtone.muted} onClick={ringtone.toggleMuted}>{ringtone.muted ? "Unmute ringtone" : "Mute ringtone"}</button>
        {conversationBusy && <p>Leave your conversation call to answer.</p>}
        <div className="phone-actions">
          <button className="button primary" type="button" disabled={busy || conversationBusy || ownsActive} onClick={() => void connectAction(() => api.answerPhoneCall(call.id))}>Answer</button>
          <button className="button ghost" type="button" disabled={busy} onClick={() => void reject(call)}>Reject</button>
        </div>
      </section>)}
      {currentCall && <section aria-label="Current phone call">
        <p role="status"><strong>{otherPhoneNumber(currentCall)}</strong><span>{phoneCallLabel(currentCall)}{ownsActive && mediaState ? ` · Audio ${mediaState}` : ""}</span></p>
        {error && <p className="form-error" role="alert">{error}</p>}
        {playbackBlocked && <button className="button primary" type="button" onClick={() => void mediaRef.current?.startPlayback()}>Enable phone audio</button>}
        {ownsActive && configuration?.enabled && configuration.configured && configuration.number && currentCall.can_join && (mediaState === "disconnected" || mediaState === null) && <button className="button primary" type="button" disabled={busy || conversationBusy} onClick={() => void connectAction(() => api.joinPhoneCall(currentCall.id), currentCall.id)}>Reconnect phone audio</button>}
        <div className="phone-actions">
          {ownsActive && <><button className="button ghost" type="button" disabled={busy || mediaState !== "connected"} aria-pressed={muted} onClick={() => void toggleMute()}>{muted ? "Unmute" : "Mute"}</button><button className="button danger" type="button" onClick={() => void end()}>End call</button></>}
          {!ownsActive && <button className="button ghost" type="button" onClick={() => { setCurrentCall(null); callRef.current = null; }}>Dismiss</button>}
          <Link className="button ghost" to="/app/calls/phone">Phone history</Link>
        </div>
      </section>}
    </aside>}
  </TelephonyContext.Provider>;
}

export function useTelephony(): PhoneContext {
  const value = useContext(TelephonyContext);
  if (!value) throw new Error("useTelephony must be used within TelephonyProvider");
  return value;
}
