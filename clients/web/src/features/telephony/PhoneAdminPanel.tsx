import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import { VoicemailAdminPanel } from "./VoicemailAdminPanel";
import { PhoneRoutingPanel } from "./PhoneRoutingPanel";
import { useTelephony } from "./TelephonyProvider";
import type { PhoneConfiguration, PhoneNumberInput } from "./types";
import { phoneNumberInputError, phoneReadiness } from "./types";

function AssignedMemberSelect({ initialUserId, members }: { initialUserId: string | undefined; members: { id: string; display_name: string }[] }) {
  const [userId, setUserId] = useState(initialUserId ?? "");
  return <select name="user_id" value={userId} onChange={(event) => setUserId(event.currentTarget.value)} required><option value="">Choose a member</option>{members.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select>;
}

export function PhoneAdminPanel() {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const { refresh } = useTelephony();
  const [configuration, setConfiguration] = useState<PhoneConfiguration | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const reasonRef = useRef<HTMLTextAreaElement | null>(null);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const version = ++generation.current;
    setLoading(true);
    setError(null);
    try {
      const result = await api.phoneAdminConfiguration();
      if (version === generation.current) setConfiguration(result);
    } catch (reason: unknown) { if (version === generation.current) setError(errorText(reason)); }
    finally { if (version === generation.current) setLoading(false); }
  }, [api]);
  useEffect(() => { void load(); return () => { generation.current += 1; }; }, [load]);

  const number = configuration?.number;
  const readiness = phoneReadiness(configuration);
  const eligibleUsers = users.filter((user) => user.status === "active" && user.account_type !== "service" && user.account_type !== "guest");
  const assignedUser = eligibleUsers.find((user) => user.id === number?.user_id);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const input = Object.fromEntries(["phone_number", "extension", "user_id", "inbound_trunk_id", "outbound_trunk_id", "reason"].map((name) => [name, String(form.get(name) ?? "").trim()])) as unknown as PhoneNumberInput;
    setError(null);
    setSaved(false);
    const validationError = phoneNumberInputError(input, eligibleUsers.map(({ id }) => id));
    if (validationError) { setError(validationError); return; }
    setBusy(true);
    try {
      const result = await runWithStepUp(() => api.updatePhoneNumber(input));
      setConfiguration((current) => current ? { ...current, number: result, line_assigned: true, configured: phoneReadiness(current).providerReady } : current);
      if (reasonRef.current) reasonRef.current.value = "";
      setSaved(true);
      await refresh();
    } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }

  return <section className="phone-admin-panel" aria-labelledby="phone-admin-heading">
    <h2 id="phone-admin-heading">Workspace phone setup</h2>
    <p>Set up one carrier number and one member extension for this workspace. Complete each step with your service operator.</p>
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p role="status">Phone assignment saved. Carrier connectivity still needs to be verified with your service operator.</p>}
    {loading && <p role="status">Loading phone settings…</p>}
    {!loading && !configuration && <button className="button ghost" type="button" onClick={() => void load()}>Retry phone settings</button>}
    {configuration && <form key={number ? [number.id, number.phone_number, number.extension, number.user_id, number.inbound_trunk_id, number.outbound_trunk_id].join(":") : "new"} noValidate onSubmit={(event) => void submit(event)}>
      <ol className="phone-setup-steps">
        <li>
          <h3>1. Provider</h3>
          <p className="phone-step-state">{!readiness.enabled ? "Phone service is off" : readiness.providerReady ? "Provider configuration ready" : "Provider configuration incomplete"}</p>
          <p>The service operator configures LiveKit SIP and keeps its credentials in secure deployment settings. This form saves a line assignment; it does not buy a number or enable the service.</p>
          <p>{!readiness.enabled ? "Keep calling off until the operator completes carrier checks." : readiness.providerReady ? "Configuration is available for call attempts. It does not prove that your carrier routes calls or two-way audio." : "Ask the operator to check the provider endpoints, credentials, and enabled media service."}</p>
          <button className="button ghost" type="button" disabled={busy || loading} onClick={() => void load()}>Refresh setup status</button>
        </li>
        <li><fieldset disabled={busy}>
          <legend>2. Number</legend>
          <p className="phone-step-state">{number ? `Saved carrier number: ${number.phone_number}` : "No carrier number saved"}</p>
          <p>Acquire the number and create inbound and outbound SIP trunks with your carrier and LiveKit first. Copy their exact IDs below.</p>
          <label className="field">Phone number<input name="phone_number" type="tel" defaultValue={number?.phone_number ?? ""} placeholder="+14155550123" pattern="\+[1-9][0-9]{7,14}" maxLength={16} required aria-describedby="phone-admin-number-help" /></label>
          <p id="phone-admin-number-help" className="phone-help">Use +, a country code, and 8–15 digits. For example, +14155550123.</p>
          <label className="field">Inbound SIP trunk ID<input name="inbound_trunk_id" defaultValue={number?.inbound_trunk_id ?? ""} pattern="[A-Za-z0-9_\-]{2,200}" minLength={2} maxLength={200} required aria-describedby="phone-admin-inbound-help" /></label>
          <p id="phone-admin-inbound-help" className="phone-help">The trunk receiving this number must use a private, individual inbound dispatch rule. Ask the operator to confirm the routing.</p>
          <label className="field">Outbound SIP trunk ID<input name="outbound_trunk_id" defaultValue={number?.outbound_trunk_id ?? ""} pattern="[A-Za-z0-9_\-]{2,200}" minLength={2} maxLength={200} required aria-describedby="phone-admin-outbound-help" /></label>
          <p id="phone-admin-outbound-help" className="phone-help">The trunk used to place calls must permit this number as the caller ID.</p>
        </fieldset></li>
        <li><fieldset disabled={busy}>
          <legend>3. Assignment</legend>
          <p className="phone-step-state">{assignedUser ? `${assignedUser.display_name} · extension ${number?.extension}` : number ? "Assigned member needs review" : "No member assigned"}</p>
          <p>This member receives incoming calls unless an enabled queue or shared line policy selects another eligible member. Past call history stays with its answering member.</p>
          <label className="field">Assigned member<AssignedMemberSelect initialUserId={number?.user_id} members={eligibleUsers} /></label>
          <label className="field">Extension<input name="extension" inputMode="numeric" defaultValue={number?.extension ?? ""} pattern="[0-9]{2,8}" minLength={2} maxLength={8} required aria-describedby="phone-admin-extension-help" /></label>
          <p id="phone-admin-extension-help" className="phone-help">Use 2–8 digits. The extension labels this line; it does not enable internal extension dialing.</p>
        </fieldset></li>
        <li>
          <h3>4. Verify</h3>
          <p>With the service operator, verify inbound ringing, answer, reject, outbound caller ID, two-way audio, and hangup using real phone endpoints before rollout. Saving this form does not verify carrier connectivity.</p>
        </li>
      </ol>
      <label className="field">Reason for this change<textarea ref={reasonRef} name="reason" required minLength={3} maxLength={500} disabled={busy} aria-describedby="phone-admin-reason-help" /></label>
      <p id="phone-admin-reason-help" className="phone-help">Briefly explain the assignment or routing change for the audit record. Saving requires password verification.</p>
      <button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save phone line"}</button>
    </form>}
    {configuration && <PhoneRoutingPanel />}
    {configuration && <VoicemailAdminPanel />}
  </section>;
}
