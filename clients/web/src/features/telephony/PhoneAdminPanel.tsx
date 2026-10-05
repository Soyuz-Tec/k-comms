import { useCallback, useEffect, useId, useRef, useState } from "react";
import type { FormEvent, KeyboardEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import { VoicemailAdminPanel } from "./VoicemailAdminPanel";
import { PhoneRoutingPanel } from "./PhoneRoutingPanel";
import { IvrAdminPanel } from "./IvrAdminPanel";
import { QueueSupervisorPanel } from "./QueueSupervisorPanel";
import { PhoneProvisioningPanel, usePhoneProvisioningAuthority } from "./PhoneProvisioningPanel";
import { useTelephony } from "./TelephonyProvider";
import type { PhoneConfiguration, PhoneNumberInput } from "./types";
import { phoneNumberInputError, phoneReadiness } from "./types";
import "./PhoneAdminPanel.css";

const phoneSections = [["setup", "Setup"], ["numbers", "Numbers"], ["routing", "Routing"], ["voicemail", "Voicemail"], ["queues", "Queues"], ["menu", "Caller menu"]] as const;
type PhoneSection = typeof phoneSections[number][0];

function AssignedMemberSelect({ initialUserId, members }: { initialUserId: string | undefined; members: { id: string; display_name: string }[] }) {
  const [userId, setUserId] = useState(initialUserId ?? "");
  return <select name="user_id" value={userId} onChange={(event) => setUserId(event.currentTarget.value)} required><option value="">Choose a member</option>{members.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select>;
}

export function PhoneAdminPanel() {
  const authority = usePhoneProvisioningAuthority();
  if (!authority.allowed) return <p role="alert">Phone setup requires a current owner or administrator with full workspace access.</p>;
  return <PhoneAdminContent key={authority.generation} isCurrent={authority.isCurrent} />;
}

function PhoneAdminContent({ isCurrent }: { isCurrent: () => boolean }) {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const { refresh } = useTelephony();
  const [configuration, setConfiguration] = useState<PhoneConfiguration | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [managementEnabled, setManagementEnabled] = useState<boolean | null>(null);
  const reasonRef = useRef<HTMLTextAreaElement | null>(null);
  const [section, setSection] = useState<PhoneSection>("setup");
  const tabId = useId();
  const generation = useRef(0);
  const load = useCallback(async () => {
    if (!isCurrent()) return;
    const version = ++generation.current;
    setLoading(true);
    setError(null);
    try {
      const result = await api.phoneAdminConfiguration();
      if (isCurrent() && version === generation.current) setConfiguration(result);
    } catch (reason: unknown) { if (isCurrent() && version === generation.current) setError(errorText(reason)); }
    finally { if (isCurrent() && version === generation.current) setLoading(false); }
  }, [api, isCurrent]);
  useEffect(() => { setManagementEnabled(null); setBusy(false); setSaved(false); void load(); return () => { generation.current += 1; }; }, [load]);

  const number = configuration?.number;
  const readiness = phoneReadiness(configuration);
  const eligibleUsers = users.filter((user) => user.status === "active" && user.account_type === "human" && user.access_scope === "workspace");
  const assignedUser = eligibleUsers.find((user) => user.id === number?.user_id);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!isCurrent()) return;
    const form = new FormData(event.currentTarget);
    const input = Object.fromEntries(["phone_number", "extension", "user_id", "inbound_trunk_id", "outbound_trunk_id", "reason"].map((name) => [name, String(form.get(name) ?? "").trim()])) as unknown as PhoneNumberInput;
    input.version = configuration?.number?.version ?? 0;
    setError(null);
    setSaved(false);
    const validationError = phoneNumberInputError(input, eligibleUsers.map(({ id }) => id));
    if (validationError) { setError(validationError); return; }
    const serial = generation.current;
    setBusy(true);
    try {
      const result = await runWithStepUp(() => {
        if (!isCurrent()) throw new Error("Phone setup authority changed. Refresh your current access.");
        return api.updatePhoneNumber(input);
      });
      if (!isCurrent() || serial !== generation.current) return;
      setConfiguration((current) => current ? { ...current, number: result, line_assigned: true, configured: phoneReadiness(current).providerReady } : current);
      if (reasonRef.current) reasonRef.current.value = "";
      setSaved(true);
      await refresh();
    } catch (reason: unknown) { if (isCurrent() && serial === generation.current && !stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { if (isCurrent() && serial === generation.current) setBusy(false); }
  }

  function navigateTabs(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    const direction = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (!direction && event.key !== "Home" && event.key !== "End") return;
    event.preventDefault();
    const next = event.key === "Home" ? 0 : event.key === "End" ? phoneSections.length - 1 : (index + direction + phoneSections.length) % phoneSections.length;
    const nextSection = phoneSections[next]![0];
    setSection(nextSection);
    document.getElementById(`${tabId}-tab-${nextSection}`)?.focus();
  }
  function showNumberAssignment() {
    setSection("numbers");
    document.getElementById(`${tabId}-tab-numbers`)?.focus();
  }

  return <section className="phone-admin-panel" aria-labelledby="phone-admin-heading">
    <div className="card-heading"><div><h2 id="phone-admin-heading">Workspace phone setup</h2><p>Manage your carrier number, member assignment and incoming call experience.</p></div></div>
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p className="inline-notice" role="status">Phone assignment saved. Carrier connectivity still needs to be verified with your service operator.</p>}
    {loading && <p role="status">Loading phone settings…</p>}
    {!loading && !configuration && <button className="button ghost" type="button" onClick={() => void load()}>Retry phone settings</button>}
    <div className="phone-admin-tabs" role="tablist" aria-label="Phone administration">
      {phoneSections.map(([id, label], index) => <button type="button" role="tab" key={id} id={`${tabId}-tab-${id}`} aria-controls={`${tabId}-panel-${id}`} aria-selected={section === id} tabIndex={section === id ? 0 : -1} onClick={() => setSection(id)} onKeyDown={(event) => navigateTabs(event, index)}>{label}</button>)}
    </div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-setup`} aria-labelledby={`${tabId}-tab-setup`} hidden={section !== "setup"} tabIndex={0}>
      {configuration && <>
        <dl className="phone-readiness-overview" aria-label="Phone setup status">
          <div><dt>Provider</dt><dd><span className={`status-pill ${readiness.enabled && readiness.providerReady ? "success" : "neutral"}`}>{!readiness.enabled ? "Phone service is off" : readiness.providerReady ? "Provider configuration ready" : "Provider configuration incomplete"}</span></dd></div>
          <div><dt>Carrier number</dt><dd>{number ? number.phone_number : "No carrier number saved"}</dd></div>
          <div><dt>Member assignment</dt><dd>{assignedUser ? `${assignedUser.display_name} · extension ${number?.extension}` : number ? "Assigned member needs review" : "No member assigned"}</dd></div>
        </dl>
        <div className="phone-admin-next-step"><h3>{number ? "Verify your calling setup" : "Add your carrier number"}</h3><p>{number ? "Verify inbound ringing, answer, reject, outbound caller ID, two-way audio and hangup with your service operator before rollout." : "Acquire a number and its inbound and outbound SIP trunks with your service operator, then save the number and assign it to a member."}</p><button className="button primary" type="button" onClick={showNumberAssignment}>{number ? "Review number assignment" : "Set up number assignment"}</button></div>
        <p className="phone-help">{!readiness.enabled ? "Keep calling off until the operator completes carrier checks." : readiness.providerReady ? "Provider configuration is available for call attempts; carrier routing and two-way audio still need verification." : "Ask the operator to complete provider configuration before rollout."}</p>
        <button className="button ghost" type="button" disabled={busy || loading} onClick={() => void load()}>Refresh setup status</button>
        <details className="phone-admin-details"><summary>Provider setup and rollout checks</summary><p>The service operator configures LiveKit SIP and keeps its credentials in secure deployment settings. Saving an assignment does not buy a number or enable the service.</p><p>With the service operator, verify inbound ringing, answer, reject, outbound caller ID, two-way audio, and hangup using real phone endpoints before rollout. Saving this form does not verify carrier connectivity.</p></details>
      </>}
    </div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-numbers`} aria-labelledby={`${tabId}-tab-numbers`} hidden={section !== "numbers"} tabIndex={0}>
      <PhoneProvisioningPanel onApplied={async () => { await load(); if (isCurrent()) await refresh(); }} onManagementMode={setManagementEnabled} />
      {configuration && managementEnabled === false && <form key={number ? [number.id, number.phone_number, number.extension, number.user_id, number.inbound_trunk_id, number.outbound_trunk_id].join(":") : "new"} noValidate onSubmit={(event) => void submit(event)}>
        <fieldset className="phone-admin-fields" disabled={busy}>
          <legend>Carrier number</legend>
          <label className="field">Phone number<input name="phone_number" type="tel" defaultValue={number?.phone_number ?? ""} placeholder="+14155550123" pattern="\+[1-9][0-9]{7,14}" maxLength={16} required aria-describedby="phone-admin-number-help" /></label>
          <p id="phone-admin-number-help" className="phone-help">Use +, a country code, and 8–15 digits. For example, +14155550123.</p>
          <div className="phone-admin-field-grid">
            <label className="field">Inbound SIP trunk ID<input name="inbound_trunk_id" defaultValue={number?.inbound_trunk_id ?? ""} pattern="[A-Za-z0-9_\-]{2,200}" minLength={2} maxLength={200} required aria-describedby="phone-admin-inbound-help" /></label>
            <label className="field">Outbound SIP trunk ID<input name="outbound_trunk_id" defaultValue={number?.outbound_trunk_id ?? ""} pattern="[A-Za-z0-9_\-]{2,200}" minLength={2} maxLength={200} required aria-describedby="phone-admin-outbound-help" /></label>
          </div>
          <details className="phone-admin-details"><summary>SIP trunk requirements</summary><p id="phone-admin-inbound-help" className="phone-help">The trunk receiving this number must use a private, individual inbound dispatch rule. Ask the operator to confirm the routing.</p><p id="phone-admin-outbound-help" className="phone-help">The trunk used to place calls must permit this number as the caller ID.</p></details>
        </fieldset>
        <fieldset className="phone-admin-fields" disabled={busy}>
          <legend>Member assignment</legend>
          <div className="phone-admin-field-grid">
            <label className="field">Assigned member<AssignedMemberSelect initialUserId={number?.user_id} members={eligibleUsers} /></label>
            <label className="field">Extension<input name="extension" inputMode="numeric" defaultValue={number?.extension ?? ""} pattern="[0-9]{2,8}" minLength={2} maxLength={8} required aria-describedby="phone-admin-extension-help" /></label>
          </div>
          <p id="phone-admin-extension-help" className="phone-help">Use 2–8 digits. The extension labels this line; it does not enable internal extension dialing.</p>
          <p className="phone-help">This member receives incoming calls unless an enabled queue or shared line policy selects another eligible member. Past call history stays with its answering member.</p>
        </fieldset>
        <label className="field">Reason for this change<textarea ref={reasonRef} name="reason" required minLength={3} maxLength={500} disabled={busy} aria-describedby="phone-admin-reason-help" /></label>
        <p id="phone-admin-reason-help" className="phone-help">Explain the change for the audit record. Saving requires password verification; carrier connectivity must be verified separately.</p>
        <div className="form-actions"><button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save phone line"}</button></div>
      </form>}
    </div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-routing`} aria-labelledby={`${tabId}-tab-routing`} hidden={section !== "routing"} tabIndex={0}>{configuration && <PhoneRoutingPanel />}</div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-voicemail`} aria-labelledby={`${tabId}-tab-voicemail`} hidden={section !== "voicemail"} tabIndex={0}>{configuration && <VoicemailAdminPanel />}</div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-queues`} aria-labelledby={`${tabId}-tab-queues`} hidden={section !== "queues"} tabIndex={0}>{configuration && <QueueSupervisorPanel />}</div>
    <div className="phone-admin-tab-panel" role="tabpanel" id={`${tabId}-panel-menu`} aria-labelledby={`${tabId}-tab-menu`} hidden={section !== "menu"} tabIndex={0}>{configuration?.number ? <IvrAdminPanel /> : <p>Save a carrier number in Numbers before configuring a caller menu.</p>}</div>
  </section>;
}
