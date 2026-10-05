import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { errorText } from "../../lib/format";
import type { PhoneRoute } from "./types";
import type { VoicemailMailbox } from "./voicemailTypes";
import type { IvrConfiguration, IvrMenuInput, IvrTarget } from "./ivrTypes";
import { validIvrTarget } from "./ivrTypes";

function emptyMenu(): IvrMenuInput {
  return { name: "Caller menu", prompt_media: "", choices: { "1": { kind: "hangup" } }, fallback: { kind: "hangup" }, digit_timeout_seconds: 10, max_retries: 1, enabled: false, version: 0, reason: "" };
}

function TargetEditor({ label, value, onChange, routes, mailbox }: { label: string; value: IvrTarget; onChange: (target: IvrTarget) => void; routes: PhoneRoute[]; mailbox: VoicemailMailbox | null }) {
  function chooseKind(kind: IvrTarget["kind"]) {
    switch (kind) {
      case "hangup": onChange({ kind }); break;
      case "route": onChange({ kind, route_id: routes.find(route => route.enabled)?.id ?? "" }); break;
      case "voicemail": onChange({ kind, mailbox_id: mailbox?.enabled ? mailbox.id : "" }); break;
      case "destination": onChange({ kind, destination: "" }); break;
    }
  }
  return <div className="ivr-target">
    <label className="field">{label}<select value={value.kind} onChange={event => chooseKind(event.currentTarget.value as IvrTarget["kind"])}>
      <option value="hangup">End call</option><option value="route">Queue or shared line</option><option value="voicemail">Voicemail mailbox</option><option value="destination">Phone number</option>
    </select></label>
    {value.kind === "route" && <label className="field">{label} route<select value={value.route_id} onChange={event => onChange({ kind: "route", route_id: event.currentTarget.value })} required>
      <option value="">Choose an enabled route</option>{value.route_id && !routes.some(route => route.id === value.route_id) && <option value={value.route_id}>Saved route unavailable</option>}
      {routes.map(route => <option key={route.id} value={route.id} disabled={!route.enabled}>{route.name}{!route.enabled ? " (off)" : ""}</option>)}
    </select></label>}
    {value.kind === "voicemail" && <label className="field">{label} mailbox<select value={value.mailbox_id} onChange={event => onChange({ kind: "voicemail", mailbox_id: event.currentTarget.value })} required>
      <option value="">Choose an enabled mailbox</option>{mailbox && <option value={mailbox.id} disabled={!mailbox.enabled}>Workspace mailbox{!mailbox.enabled ? " (off)" : ""}</option>}
      {value.mailbox_id && value.mailbox_id !== mailbox?.id && <option value={value.mailbox_id}>Saved mailbox unavailable</option>}
    </select></label>}
    {value.kind === "destination" && <label className="field">{label} phone number<input type="tel" value={value.destination} onChange={event => onChange({ kind: "destination", destination: event.currentTarget.value })} placeholder="+14155550123" pattern="\+[1-9][0-9]{7,14}" maxLength={16} required /></label>}
  </div>;
}

export function IvrAdminPanel() {
  const { api } = useSession();
  const { runWithStepUp } = useStepUp();
  const [configuration, setConfiguration] = useState<IvrConfiguration | null>(null);
  const [draft, setDraft] = useState<IvrMenuInput>(emptyMenu);
  const [routes, setRoutes] = useState<PhoneRoute[]>([]);
  const [mailbox, setMailbox] = useState<VoicemailMailbox | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [stale, setStale] = useState(false);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true); setError(null); setSaved(false);
    try {
      const [config, routePage, box] = await Promise.all([api.phoneIvrConfiguration(), api.phoneRoutes(), api.voicemailMailbox()]);
      if (current !== generation.current) return;
      setConfiguration(config); setRoutes(routePage.data); setMailbox(box);
      const menu = config.menu;
      setDraft(menu ? { name: menu.name, prompt_media: menu.prompt_media, choices: menu.choices, fallback: menu.fallback, digit_timeout_seconds: menu.digit_timeout_seconds, max_retries: menu.max_retries, enabled: menu.enabled, version: menu.version, reason: "" } : emptyMenu());
      setStale(false);
    } catch (reason) { if (current === generation.current) setError(errorText(reason)); }
    finally { if (current === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => { setConfiguration(null); setDraft(emptyMenu()); setBusy(false); void load(); return () => { generation.current += 1; }; }, [load]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const input = { ...draft, name: draft.name.trim(), prompt_media: draft.prompt_media.trim(), reason: draft.reason.trim() };
    if (!input.name || input.name.length > 100 || !/^sound:[A-Za-z0-9_/-]{1,150}$/.test(input.prompt_media) || input.reason.length < 3 || input.reason.length > 500 || !Object.values(input.choices).every(validIvrTarget) || !validIvrTarget(input.fallback) || !Number.isInteger(input.digit_timeout_seconds) || input.digit_timeout_seconds < 5 || input.digit_timeout_seconds > 30 || !Number.isInteger(input.max_retries) || input.max_retries < 0 || input.max_retries > 2) {
      setError("Enter an installed prompt, valid targets, 5–30 seconds for digits, 0–2 retries, and an audit reason."); return;
    }
    const current = generation.current;
    setBusy(true); setError(null); setSaved(false);
    try {
      const menu = await runWithStepUp(() => api.savePhoneIvr(input));
      if (current !== generation.current) return;
      setConfiguration(config => config ? { ...config, menu } : config);
      setDraft({ ...input, version: menu.version, reason: "" }); setSaved(true);
    } catch (reason) {
      if (current !== generation.current || stepUpWasCancelled(reason)) return;
      if (reason instanceof ApiError && reason.code === "stale_version") { setStale(true); setError("This menu changed elsewhere. Your draft is preserved. Reload the saved menu and review it before saving again."); }
      else setError(errorText(reason));
    } finally { if (current === generation.current) setBusy(false); }
  }
  function changeChoice(digit: string, target: IvrTarget | null) {
    setDraft(current => { const choices = { ...current.choices }; if (target) choices[digit] = target; else delete choices[digit]; return { ...current, choices }; });
  }
  const unusedDigit = "123456789".split("").find(digit => !draft.choices[digit]);
  return <section className="phone-ivr-panel" aria-labelledby="phone-ivr-heading">
    <h2 id="phone-ivr-heading">Caller menu</h2>
    <p>Play one reviewed prompt, then route a caller’s digit to an enabled queue, voicemail mailbox, or phone number. Calls keep their original 45-second admission budget.</p>
    {loading && <p role="status">Loading caller menu…</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p role="status">Caller menu saved.</p>}
    <button className="button ghost" type="button" disabled={busy || loading} onClick={() => void load()}>Reload saved caller menu</button>
    {configuration && <form onSubmit={event => void submit(event)}>
      {!configuration.available && <p>Caller menus are unavailable until the service operator qualifies the PBX and reviewed prompts. Save an inactive menu or turn an existing menu off.</p>}
      <fieldset disabled={busy || loading}>
        <label className="field">Menu name<input value={draft.name} onChange={event => setDraft({ ...draft, name: event.currentTarget.value })} maxLength={100} required /></label>
        <label className="field">Caller menu prompt<input value={draft.prompt_media} onChange={event => setDraft({ ...draft, prompt_media: event.currentTarget.value })} list="ivr-reviewed-prompts" placeholder="sound:custom/caller-menu" maxLength={156} required /></label>
        <datalist id="ivr-reviewed-prompts">{configuration.approved_prompts.map(prompt => <option key={prompt} value={prompt} />)}</datalist>
        <p>The prompt should describe each digit and tell callers how the fallback works. The operator’s reviewed prompt list is required to enable the menu.</p>
        <div className="ivr-choices">{Object.entries(draft.choices).sort().map(([digit, target]) => <div key={digit} className="ivr-choice">
          <TargetEditor label={`Digit ${digit}`} value={target} onChange={value => changeChoice(digit, value)} routes={routes} mailbox={mailbox} />
          <button className="button ghost" type="button" disabled={Object.keys(draft.choices).length <= 1} onClick={() => changeChoice(digit, null)}>Remove digit {digit}</button>
        </div>)}</div>
        <button className="button ghost" type="button" disabled={!unusedDigit || Object.keys(draft.choices).length >= 9} onClick={() => { if (unusedDigit) changeChoice(unusedDigit, { kind: "hangup" }); }}>Add digit {unusedDigit ?? ""}</button>
        <TargetEditor label="Fallback" value={draft.fallback} onChange={fallback => setDraft({ ...draft, fallback })} routes={routes} mailbox={mailbox} />
        <label className="field">Seconds to enter a digit<input type="number" min={5} max={30} value={draft.digit_timeout_seconds} onChange={event => setDraft({ ...draft, digit_timeout_seconds: Number(event.currentTarget.value) })} required /></label>
        <label className="field">Prompt retries<input type="number" min={0} max={2} value={draft.max_retries} onChange={event => setDraft({ ...draft, max_retries: Number(event.currentTarget.value) })} required /></label>
        <label><input type="checkbox" checked={draft.enabled} disabled={!configuration.available && !draft.enabled} onChange={event => setDraft({ ...draft, enabled: event.currentTarget.checked })} /> Enable caller menu</label>
        <label className="field">Caller menu change reason<textarea value={draft.reason} onChange={event => setDraft({ ...draft, reason: event.currentTarget.value })} minLength={3} maxLength={500} required /></label>
        <button className="button primary" type="submit" disabled={stale}>{busy ? "Saving caller menu…" : "Save caller menu"}</button>
      </fieldset>
    </form>}
  </section>;
}
