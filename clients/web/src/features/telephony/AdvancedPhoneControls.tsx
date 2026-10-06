import { useCallback, useEffect, useState } from "react";
import { useSession } from "../../app/session";
import { errorText } from "../../lib/format";
import type { PhoneCall, PhoneCapabilities, PhoneControlAction, PhoneControlInput, PhoneControlReceipt } from "./types";
import { normalizePhoneDestination } from "./types";

export function AdvancedPhoneControls({ call, disabled, recoveryDisabled = disabled, sendDtmf, refresh }: {
  call: PhoneCall; disabled: boolean; recoveryDisabled?: boolean; sendDtmf: (digit: string) => Promise<void>; refresh: () => Promise<void>;
}) {
  const { api } = useSession();
  const [capabilities, setCapabilities] = useState<PhoneCapabilities>({});
  const [destination, setDestination] = useState("");
  const [receipts, setReceipts] = useState<PhoneControlReceipt[]>([]);
  const [pending, setPending] = useState<PhoneControlInput | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    try {
      const [caps, commands] = await Promise.all([api.phoneCapabilities(), api.phoneControls(call.id)]);
      setCapabilities(caps); setReceipts(commands.data);
    } catch (reason) { setError(errorText(reason)); }
  }, [api, call.id]);
  useEffect(() => {
    void load();
    const timer = window.setInterval(() => { void load(); }, 2_000);
    return () => window.clearInterval(timer);
  }, [load]);
  const submit = async (input: PhoneControlInput) => {
    if (busy) return;
    setBusy(true); setError(null); setPending(input);
    try {
      let receipt = await api.requestPhoneControl(call.id, input);
      if (receipt.action === "dtmf" && receipt.dispatch && input.digit) {
        let status: "submitted" | "unknown" = "submitted";
        try { await sendDtmf(input.digit); } catch { status = "unknown"; }
        receipt = await api.completePhoneControl(call.id, receipt.id, status);
      }
      setReceipts((current) => [receipt, ...current.filter(({ id }) => id !== receipt.id)]);
      setPending(null); await refresh();
    } catch (reason) {
      setError(`The control outcome could not be confirmed. Retry the same request to read its durable receipt. ${errorText(reason)}`);
    } finally { setBusy(false); }
  };
  const action = (name: PhoneControlAction, digit?: string) => {
    const transfer = name === "blind_transfer" || name === "consult_transfer";
    const number = normalizePhoneDestination(destination);
    if (transfer && !number) return;
    void submit({ action: name, digit, ...(transfer ? { destination: number! } : {}), idempotency_key: crypto.randomUUID() });
  };
  const enabled = (name: PhoneControlAction) => capabilities[name]?.supported === true;
  const state = call.control_state ?? "connected";
  const blocked = disabled || busy || Boolean(pending) || receipts.some(({ status, action }) => action !== "dtmf" && (status === "pending" || status === "dispatching" || status === "unknown"));
  const recoveryBlocked = recoveryDisabled || busy || Boolean(pending) || receipts.some(({ status, action }) => action !== "dtmf" && (status === "pending" || status === "dispatching" || status === "unknown"));
  const transferValid = normalizePhoneDestination(destination);
  const latest = receipts[0];
  const cancellableUnknown = latest?.action === "consult_transfer" && latest.status === "unknown";
  return <section aria-label="Advanced phone controls">
    <p role="status">Call control: {state}</p>
    {error && <p role="alert" className="form-error">{error}</p>}
    {pending && <button type="button" className="button ghost" disabled={disabled || busy} onClick={() => void submit(pending)}>Retry control request</button>}
    {enabled("dtmf") && (state === "connected" || state === "consulting") && <fieldset disabled={blocked} aria-label="In-call keypad">
      <legend>Phone keypad</legend>
      <div className="phone-keypad">{["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"].map((digit) =>
        <button type="button" key={digit} onClick={() => action("dtmf", digit)} aria-label={`Send tone ${digit}`}>{digit}</button>)}</div>
      <p>Submitted tones were accepted by the audio SDK. Carrier receipt cannot be confirmed.</p>
    </fieldset>}
    {enabled("hold") && state === "connected" && <button type="button" className="button ghost" disabled={blocked} onClick={() => action("hold")}>Hold</button>}
    {enabled("resume") && state === "held" && <button type="button" className="button primary" disabled={blocked} onClick={() => action("resume")}>Resume</button>}
    {(enabled("blind_transfer") || enabled("consult_transfer")) && (state === "connected" || state === "held") && <fieldset disabled={blocked}>
      <legend>Transfer</legend>
      <label>International destination<input value={destination} onChange={(event) => setDestination(event.target.value)} inputMode="tel" placeholder="+1 (415) 555-0100" maxLength={40} aria-describedby="phone-transfer-help" /></label>
      <p id="phone-transfer-help">Include + and the country code. Spaces, parentheses and dashes are accepted.{transferValid && ` Destination: ${transferValid}.`}</p>
      {enabled("blind_transfer") && state === "connected" && <button type="button" className="button ghost" disabled={!transferValid} onClick={() => action("blind_transfer")}>Transfer now</button>}
      {enabled("consult_transfer") && <button type="button" className="button ghost" disabled={!transferValid} onClick={() => action("consult_transfer")}>Consult before transfer</button>}
      <p>Only operator-approved destination prefixes are accepted.</p>
    </fieldset>}
    {state === "consulting" && <div className="phone-actions">
      {enabled("complete_transfer") && <button type="button" className="button primary" disabled={blocked} onClick={() => action("complete_transfer")}>Complete transfer</button>}
      {enabled("cancel_transfer") && <button type="button" className="button ghost" disabled={recoveryBlocked} onClick={() => action("cancel_transfer")}>Cancel consultation</button>}
    </div>}
    {enabled("voicemail") && call.direction === "inbound" && (state === "connected" || state === "held") && <button type="button" className="button ghost" disabled={blocked} onClick={() => action("voicemail")}>Send to voicemail</button>}
    {cancellableUnknown && enabled("cancel_transfer") && <button type="button" className="button ghost" disabled={recoveryDisabled || busy || Boolean(pending)} onClick={() => action("cancel_transfer")}>Cancel uncertain consultation</button>}
    {latest && <p role="status">Latest {latest.action.replaceAll("_", " ")}: {latest.status}{latest.failure_reason ? ` (${latest.failure_reason.replaceAll("_", " ")})` : ""}</p>}
    {latest?.status === "unknown" && latest.action !== "dtmf" && latest.action !== "blind_transfer" && <button type="button" className="button ghost" disabled={recoveryDisabled || busy} onClick={() => {
      setBusy(true); setError(null);
      void api.reconcilePhoneControl(call.id, latest.id).then(() => load()).catch((reason: unknown) => setError(errorText(reason))).finally(() => setBusy(false));
    }}>Reconcile phone control</button>}
    {!enabled("hold") && <p>Hold and consultation require a configured and qualified phone switch.</p>}
  </section>;
}
