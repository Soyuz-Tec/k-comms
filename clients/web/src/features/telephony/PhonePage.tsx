import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router";
import { useSession } from "../../app/session";
import { errorText, formatDateTime } from "../../lib/format";
import { useTelephony } from "./TelephonyProvider";
import type { PhoneCall } from "./types";
import { otherPhoneNumber, phoneCallIsActive, phoneCallLabel, phoneDurationLabel } from "./types";
import "./telephony.css";

export function PhonePage() {
  const { api } = useSession();
  const phone = useTelephony();
  const [destination, setDestination] = useState("");
  const [calls, setCalls] = useState<PhoneCall[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [filter, setFilter] = useState<"all" | "missed">("all");
  const generation = useRef(0);
  const load = useCallback(async (next: string | null = null) => {
    const version = ++generation.current;
    setLoading(true);
    setHistoryError(null);
    try {
      const page = await api.phoneCalls({ limit: 30, cursor: next, scope: filter === "missed" ? "missed" : undefined });
      if (version !== generation.current) return;
      setCalls((current) => next ? [...current, ...page.data.filter((call) => !current.some(({ id }) => id === call.id))] : page.data);
      setCursor(page.page.has_more ? page.page.next_cursor : null);
    } catch (reason: unknown) { if (version === generation.current) setHistoryError(errorText(reason)); }
    finally { if (version === generation.current) setLoading(false); }
  }, [api, filter]);

  useEffect(() => {
    setCalls([]);
    setCursor(null);
    if (phone.configuration?.enabled && phone.configuration.number) void load();
    return () => { generation.current += 1; };
  }, [load, phone.configuration?.enabled, phone.configuration?.number?.id, phone.currentCall?.status]);

  async function dial(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!/^\+[1-9]\d{7,14}$/.test(destination.trim())) return;
    await phone.dial(destination.trim());
    void load();
  }

  const configured = Boolean(phone.configuration?.enabled && phone.configuration.configured && phone.configuration.number);
  const currentActive = Boolean(phone.currentCall && phoneCallIsActive(phone.currentCall));
  const visibleCalls = calls.filter((call) => filter === "all" || (call.direction === "inbound" && ["no_answer", "busy"].includes(call.status)));
  return <main className="page-shell phone-page" id="main-content">
    <header className="page-heading"><div><h1>Phone</h1><p>Call phone numbers and review your personal call history.</p></div><Link className="button ghost" to="/app/calls">Conversation calls</Link></header>
    {phone.loading ? <p role="status">Checking phone availability…</p> : !configured && <section className="phone-setup-note" aria-label="Phone setup">
      <h2>Phone calling needs setup</h2>
      <p>{!phone.configuration?.enabled ? "Phone calling is disabled for this service." : !phone.configuration.configured ? "A telephony provider must be connected before phone calls are available." : "Ask your workspace administrator to assign you a phone number and extension."}</p>
      {phone.configuration?.can_manage && <Link className="button primary" to="/admin?section=phone">Set up a phone line</Link>}
    </section>}
    {phone.error && <p className="form-error" role="alert">{phone.error}</p>}
    {phone.configuration?.number && <section className="phone-line" aria-label="Your phone line"><strong>{phone.configuration.number.phone_number}</strong><span>Extension {phone.configuration.number.extension}</span></section>}
    <div className="phone-workspace">
      <section className="phone-dialer" aria-labelledby="phone-dialer-heading">
        <h2 id="phone-dialer-heading">Dial a number</h2>
        <form onSubmit={(event) => void dial(event)}>
          <label className="field">Phone number<input type="tel" inputMode="tel" autoComplete="tel" value={destination} onChange={(event) => setDestination(event.currentTarget.value)} placeholder="+14155550123" pattern="\+[1-9][0-9]{7,14}" required aria-describedby="phone-number-help" /></label>
          <p id="phone-number-help">Include + and the country code.</p>
          {phone.conversationBusy && <p role="status">Leave your conversation call before dialing.</p>}
          <button className="button primary" type="submit" disabled={!configured || phone.busy || phone.conversationBusy || currentActive || !/^\+[1-9]\d{7,14}$/.test(destination.trim())}>{phone.busy ? "Connecting…" : "Call number"}</button>
        </form>
      </section>
      <section className="phone-history" aria-labelledby="phone-history-heading">
        <header><h2 id="phone-history-heading">Call history</h2><button className="button ghost" type="button" disabled={loading || !phone.configuration?.number} onClick={() => void Promise.allSettled([phone.refresh(), load()])}>Refresh phone calls</button></header>
        <label className="field">Show calls<select value={filter} onChange={(event) => setFilter(event.currentTarget.value as "all" | "missed")}><option value="all">All calls</option><option value="missed">Missed calls</option></select></label>
        {historyError && <p className="form-error" role="alert">{historyError}</p>}
        {loading && <p role="status">Loading phone history…</p>}
        {!loading && visibleCalls.length === 0 && <p>{filter === "missed" ? "No missed calls yet." : "No phone calls yet."}</p>}
        <ul className="phone-history-list">{visibleCalls.map((call) => <li key={call.id}>
          <div><strong>{otherPhoneNumber(call)}</strong><span>{call.direction === "inbound" ? "Incoming" : "Outgoing"} · {phoneCallLabel(call)}</span><time dateTime={call.started_at}>{formatDateTime(call.started_at)}</time><span>{phoneDurationLabel(call)}</span>{call.end_reason && call.end_reason !== "answer_unconfirmed" && <span>{call.end_reason.replaceAll("_", " ")}</span>}</div>
          {call.can_join && !currentActive && <button className="button ghost" type="button" disabled={phone.busy || phone.conversationBusy} onClick={() => void phone.join(call)}>Connect audio</button>}
          {!phoneCallIsActive(call) && configured && <button className="button ghost" type="button" disabled={phone.busy || phone.conversationBusy || currentActive} onClick={() => setDestination(otherPhoneNumber(call))}>Use number</button>}
        </li>)}</ul>
        {cursor && <button className="button ghost" type="button" disabled={loading} onClick={() => void load(cursor)}>Load more phone calls</button>}
      </section>
    </div>
  </main>;
}
