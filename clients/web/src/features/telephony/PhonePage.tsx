import { useCallback, useEffect, useRef, useState } from "react";
import { VoicemailPanel } from "./VoicemailPanel";
import { AgentQueuePanel } from "./AgentQueuePanel";
import type { FormEvent } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { SurfaceHeader } from "../../components/SurfaceHeader";
import { CallTypeNavigation } from "../calls/CallTypeNavigation";
import { useSession } from "../../app/session";
import { errorText, formatDateTime } from "../../lib/format";
import { useTelephony } from "./TelephonyProvider";
import type { PhoneCall } from "./types";
import { normalizePhoneDestination, otherPhoneNumber, phoneAuthorityLost, phoneCallIsActive, phoneCallLabel, phoneDurationLabel, phoneIdentityKey, phoneReadiness, phoneSetupAdvice } from "./types";
import "./telephony.css";

type HistoryFilters = { q?: string; direction?: "inbound" | "outbound"; from?: string; to?: string };

export function PhonePage() {
  const { session } = useSession();
  return <PhoneWorkspace key={phoneIdentityKey(session)} />;
}

function PhoneWorkspace() {
  const { api } = useSession();
  const phone = useTelephony();
  const [destination, setDestination] = useState("");
  const [calls, setCalls] = useState<PhoneCall[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<"all" | "missed">("all");
  const [historyDraft, setHistoryDraft] = useState({ q: "", direction: "", from: "", to: "" });
  const [historyFilters, setHistoryFilters] = useState<HistoryFilters>({});
  const [preparedNumber, setPreparedNumber] = useState<string | null>(null);
  const destinationInput = useRef<HTMLInputElement>(null);
  const generation = useRef(0);
  const load = useCallback(async (next: string | null = null) => {
    const version = ++generation.current;
    setLoading(true);
    setHistoryError(null);
    try {
      const page = await api.phoneCalls({ limit: 30, cursor: next, scope: filter === "missed" ? "missed" : undefined, ...historyFilters });
      if (version !== generation.current) return;
      setCalls((current) => next ? [...current, ...page.data.filter((call) => !current.some(({ id }) => id === call.id))] : page.data);
      setCursor(page.page.has_more ? page.page.next_cursor : null);
    } catch (reason: unknown) { if (version === generation.current) {
      if (phoneAuthorityLost(reason)) { setCalls([]); setCursor(null); setDestination(""); setPreparedNumber(null); }
      setHistoryError(errorText(reason));
    } }
    finally { if (version === generation.current) setLoading(false); }
  }, [api, filter, historyFilters]);

  useEffect(() => {
    setCalls([]);
    setCursor(null);
    void load();
    return () => { generation.current += 1; };
  }, [load, phone.currentCall?.id, phone.currentCall?.status]);

  async function dial(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const number = normalizePhoneDestination(destination);
    if (!number || !configured || phone.busy || phone.conversationBusy || currentActive) return;
    setPreparedNumber(null);
    await phone.dial(number);
    void load();
  }

  function useNumber(number: string) {
    const normalized = normalizePhoneDestination(number);
    if (!normalized) return;
    setDestination(normalized);
    setPreparedNumber(normalized);
    destinationInput.current?.focus();
  }

  function searchHistory(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (historyDraft.from && historyDraft.to && historyDraft.from > historyDraft.to) return;
    setHistoryFilters({
      ...(historyDraft.q.trim() ? { q: historyDraft.q.trim() } : {}),
      ...(historyDraft.direction ? { direction: historyDraft.direction as "inbound" | "outbound" } : {}),
      ...(historyDraft.from ? { from: historyDraft.from } : {}),
      ...(historyDraft.to ? { to: historyDraft.to } : {})
    });
  }

  const { canCall: configured, state: readiness } = phoneReadiness(phone.configuration);
  const advice = phoneSetupAdvice(phone.configuration);
  const setupNext = readiness === "disabled" && phone.configuration?.can_manage
    ? "Ask the service operator to complete provider and carrier checks before enabling phone calls. Review line assignments in Phone administration."
    : advice.next;
  const currentActive = Boolean(phone.currentCall && phoneCallIsActive(phone.currentCall));
  const normalizedDestination = normalizePhoneDestination(destination);
  const historyFiltered = Object.keys(historyFilters).length > 0;
  const visibleCalls = calls.filter((call) => filter === "all" || (call.direction === "inbound" && ["no_answer", "busy"].includes(call.status)));
  return <main className="page-shell phone-page" id="main-content">
    <SurfaceHeader title="Phone" description="Dial a phone number, review calls, and manage your voicemail." />
    <CallTypeNavigation active="phone" />
    {phone.loading ? <p role="status">Checking phone availability…</p> : !configured && <section className="phone-setup-note" aria-label="Phone setup">
      <div><h2>{advice.title}</h2><p>{setupNext}</p><small>Your personal call history remains available below.</small></div>
      {phone.configuration?.can_manage ? <Link className="button ghost" to="/admin?section=phone">Review phone setup</Link> : <button className="button ghost" type="button" onClick={() => void phone.refresh()}>Refresh phone availability</button>}
    </section>}
    {phone.error && <p className="form-error" role="alert">{phone.error}</p>}
    {phone.configuration?.number && <section className="phone-line" aria-label="Your phone line"><span>Your caller number <strong>{phone.configuration.number.phone_number}</strong></span><span>Extension {phone.configuration.number.extension}</span></section>}
    <div className="phone-workspace">
      <section className="phone-dialer" aria-labelledby="phone-dialer-heading">
        <h2 id="phone-dialer-heading">Dial a number</h2>
        <form onSubmit={(event) => void dial(event)}>
          <label className="field">Phone number<input ref={destinationInput} type="tel" inputMode="tel" autoComplete="tel" value={destination} onChange={(event) => { setDestination(event.currentTarget.value); setPreparedNumber(null); }} placeholder="+1 (415) 555-0123" maxLength={40} required disabled={currentActive || phone.busy} aria-describedby="phone-number-help" /></label>
          <p id="phone-number-help">Include + and the country code. Spaces, parentheses and dashes are accepted.{normalizedDestination && normalizedDestination !== destination.trim() && ` Number to call: ${normalizedDestination}.`}</p>
          {preparedNumber && <p role="status">Number {preparedNumber} is ready. Review it, then choose Call number.</p>}
          <div className="phone-keypad" role="group" aria-label="Number entry keypad">
            {["1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "0"].map((digit) => <button key={digit} className="button ghost" type="button" aria-label={digit === "+" ? "Enter country code prefix" : `Enter ${digit}`} disabled={currentActive || phone.busy || destination.length >= 40 || (digit === "+" && destination.length > 0)} onClick={() => { setDestination((value) => value + digit); setPreparedNumber(null); }}>{digit}</button>)}
            <button className="button ghost" type="button" aria-label="Delete last digit" disabled={!destination || currentActive || phone.busy} onClick={() => setDestination((value) => value.slice(0, -1))}><AppIcon name="backspace" /></button>
          </div>
          <details className="phone-keypad-help"><summary>About this keypad</summary><p className="phone-help">This keypad enters a number before calling; it does not send tones during a call.</p></details>
          {phone.conversationBusy && <p role="status">Leave your conversation call before dialing.</p>}
          <button className="button primary" type="submit" disabled={!configured || phone.busy || phone.conversationBusy || currentActive || !normalizedDestination}>{phone.busy ? "Connecting…" : "Call number"}</button>
        </form>
        <p className="phone-help"><Link to="/app/directory">Find a person for an Internet call</Link></p>
      </section>
      <section className="phone-history" aria-labelledby="phone-history-heading">
        <header><h2 id="phone-history-heading">Call history</h2><button className="button ghost" type="button" disabled={loading} onClick={() => void Promise.allSettled([phone.refresh(), load()])}>Refresh phone calls</button></header>
        <form className="phone-history-filters" onSubmit={searchHistory} aria-label="Phone history filters">
          <label className="field">Search phone history<input type="search" value={historyDraft.q} maxLength={40} placeholder="Phone number" onChange={event => setHistoryDraft(current => ({ ...current, q: event.target.value }))} /></label>
          <label className="field">Show calls<select value={filter} onChange={(event) => setFilter(event.currentTarget.value as "all" | "missed")}><option value="all">All calls</option><option value="missed">Missed calls</option></select></label>
          <details><summary>Date and direction</summary><div className="phone-history-date-filters">
            <label className="field">Direction<select value={historyDraft.direction} onChange={event => setHistoryDraft(current => ({ ...current, direction: event.target.value }))}><option value="">Incoming and outgoing</option><option value="inbound">Incoming</option><option value="outbound">Outgoing</option></select></label>
            <label className="field">From (UTC)<input type="date" value={historyDraft.from} max={historyDraft.to || undefined} onChange={event => setHistoryDraft(current => ({ ...current, from: event.target.value }))} /></label>
            <label className="field">To (UTC)<input type="date" value={historyDraft.to} min={historyDraft.from || undefined} onChange={event => setHistoryDraft(current => ({ ...current, to: event.target.value }))} /></label>
          </div></details>
          <div className="phone-actions"><button className="button ghost" type="submit" disabled={loading}>Search history</button>{historyFiltered && <button className="button ghost" type="button" onClick={() => { setHistoryDraft({ q: "", direction: "", from: "", to: "" }); setHistoryFilters({}); }}>Clear search filters</button>}</div>
        </form>
        {historyFiltered && <p className="phone-help">Searching your retained history{historyFilters.q ? ` for “${historyFilters.q}”` : ""}{historyFilters.direction ? ` · ${historyFilters.direction === "inbound" ? "Incoming" : "Outgoing"}` : ""}{historyFilters.from ? ` · from ${historyFilters.from} UTC` : ""}{historyFilters.to ? ` · through ${historyFilters.to} UTC` : ""}.</p>}
        {historyError && <p className="form-error" role="alert">{historyError}</p>}
        {loading && <p role="status">Loading phone history…</p>}
        {!loading && !historyError && visibleCalls.length === 0 && <div className="surface-empty"><AppIcon name="phone" /><strong>{historyFiltered ? "No calls match these filters." : filter === "missed" ? "No missed calls yet." : "No phone calls yet."}</strong><p>{historyFiltered ? "Try another number or widen the date range." : "Incoming and outgoing calls appear here when phone service is available."}</p></div>}
        <ul className="phone-history-list">{visibleCalls.map((call) => <li key={call.id}>
          <div><strong>{otherPhoneNumber(call)}</strong><span>{call.direction === "inbound" ? "Incoming" : "Outgoing"} · {phoneCallLabel(call)}</span><time dateTime={call.started_at}>{formatDateTime(call.started_at)}</time><span>{phoneDurationLabel(call)}</span>{call.end_reason && call.end_reason !== "answer_unconfirmed" && <span>{call.end_reason.replaceAll("_", " ")}</span>}</div>
          {call.can_join && !currentActive && <button className="button ghost" type="button" disabled={phone.busy || phone.conversationBusy} onClick={() => void phone.join(call)}>Connect audio</button>}
          {!phoneCallIsActive(call) && normalizePhoneDestination(otherPhoneNumber(call)) && <button className="button ghost" type="button" disabled={phone.busy || currentActive} onClick={() => useNumber(otherPhoneNumber(call))}>Use number</button>}
        </li>)}</ul>
        {cursor && <button className="button ghost" type="button" disabled={loading} onClick={() => void load(cursor)}>Load more phone calls</button>}
      </section>
      <VoicemailPanel onUseNumber={useNumber} callbackDisabled={phone.busy || currentActive} />
      <AgentQueuePanel />
    </div>
  </main>;
}
