import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import { phoneNumberInputError } from "./types";
import type { PhoneProvisioningCommand, PhoneProvisioningInput, PhoneProvisioningState } from "./provisioning-types";

export function PhoneProvisioningPanel({ onApplied, onManagementMode }: { onApplied: () => Promise<void>; onManagementMode: (enabled: boolean) => void }) {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const [state, setState] = useState<PhoneProvisioningState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const generation = useRef(0);
  const mounted = useRef(false);
  const ownerEpoch = useRef(0);
  const uncertainInspection = useRef<PhoneProvisioningInput | null>(null);
  const eligible = users.filter((user) => user.status === "active" && user.account_type === "human" && user.access_scope === "workspace");
  const load = useCallback(async () => {
    const serial = ++generation.current;
    try {
      const next = await api.phoneProvisioningState();
      if (mounted.current && serial === generation.current) {
        setState(next); onManagementMode(next.provider.enabled);
        if (next.commands.some((command) => command.request_id === uncertainInspection.current?.idempotency_key)) uncertainInspection.current = null;
      }
    } catch (reason: unknown) { if (mounted.current && serial === generation.current) setError(errorText(reason)); }
  }, [api, onManagementMode]);
  useEffect(() => {
    mounted.current = true;
    ownerEpoch.current += 1; setBusy(false);
    setState(null); uncertainInspection.current = null;
    void load();
    return () => { mounted.current = false; generation.current += 1; ownerEpoch.current += 1; };
  }, [load]);

  async function inspect(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!state || busy) return;
    const form = new FormData(event.currentTarget);
    const values = Object.fromEntries(["phone_number", "extension", "user_id", "inbound_trunk_id", "outbound_trunk_id", "reason"].map((name) => [name, String(form.get(name) ?? "").trim()]));
    const input = { ...values, assignment_version: state.assignment_version, idempotency_key: crypto.randomUUID() } as unknown as PhoneProvisioningInput;
    const invalid = phoneNumberInputError(input, eligible.map(({ id }) => id));
    if (invalid) { setError(invalid); return; }
    if (uncertainInspection.current) {
      const previous = uncertainInspection.current;
      if (JSON.stringify({ ...input, idempotency_key: previous.idempotency_key }) !== JSON.stringify(previous)) {
        setError("The previous inspection result is uncertain. Refresh receipts before changing these details."); return;
      }
      input.idempotency_key = previous.idempotency_key;
    }
    const serial = generation.current;
    const epoch = ownerEpoch.current;
    setBusy(true); setError(null); setNotice(null);
    try {
      uncertainInspection.current = input;
      const receipt = await runWithStepUp(() => api.inspectPhoneProvisioning(input));
      if (!mounted.current || serial !== generation.current) return;
      uncertainInspection.current = null;
      setNotice(receipt.status === "verified" ? "Provider resources inspected. Review and apply the setup separately." : "Inspection could not verify this setup. Review the receipt before retrying.");
      await load();
    } catch (reason: unknown) {
      if (mounted.current && serial === generation.current) {
        if (stepUpWasCancelled(reason)) uncertainInspection.current = null;
        else setError(errorText(reason));
      }
    }
    finally { if (mounted.current && epoch === ownerEpoch.current) setBusy(false); }
  }

  async function action(command: PhoneProvisioningCommand, mode: "apply" | "reconcile", form: HTMLFormElement) {
    if (busy) return;
    const reason = String(new FormData(form).get("reason") ?? "").trim();
    if (reason.length < 3 || reason.length > 500) { setError("Enter a reason of 3–500 characters."); return; }
    const serial = generation.current;
    const epoch = ownerEpoch.current;
    setBusy(true); setError(null); setNotice(null);
    try {
      const receipt = await runWithStepUp(() => mode === "apply"
        ? api.applyPhoneProvisioning(command.id, { version: command.version, reason })
        : api.reconcilePhoneProvisioning(command.id, { version: command.version, reason }));
      if (!mounted.current || serial !== generation.current) return;
      setNotice(receipt.status === "applied" ? "Provider binding and assignment saved. Carrier and two-way audio qualification remain separate." : "Outcome remains uncertain. Reconcile the original receipt; creating another rule is blocked.");
      await load();
      if (receipt.status === "applied" && mounted.current && serial + 1 === generation.current) await onApplied();
    } catch (reason: unknown) {
      if (mounted.current && serial === generation.current && !stepUpWasCancelled(reason)) {
        setError(errorText(reason));
        setNotice("The server may retain an effect receipt. Refresh and reconcile it before retrying Apply.");
        await load();
      }
    } finally { if (mounted.current && epoch === ownerEpoch.current) setBusy(false); }
  }

  return <section aria-labelledby="phone-provider-management-heading">
    <h3 id="phone-provider-management-heading">Inspect and manage provider bindings</h3>
    <p>Use trunks and a number already supplied by your operator. This app does not purchase or port numbers, edit SIP passwords, or enable calling.</p>
    {error && <p role="alert" className="form-error">{error}</p>}
    {notice && <p role="status">{notice}</p>}
    <button className="button ghost" disabled={busy} onClick={() => void load()}>Refresh provider receipts</button>
    {!state && <p role="status">Provider management has not been verified.</p>}
    {state && !state.provider.ready && <p>Provider management is {state.provider.enabled ? "unavailable until the operator supplies validated tenant bindings and control credentials" : "off by default"}. Manual assignment remains separate while management is off.</p>}
    {state?.provider.ready && <form onSubmit={(event) => void inspect(event)}>
      <fieldset disabled={busy}>
        <legend>Inspect an acquired number and existing trunks</legend>
        <label className="field">Phone number<input name="phone_number" type="tel" required maxLength={16} placeholder="+14155550123" /></label>
        <label className="field">Inbound trunk ID<input name="inbound_trunk_id" required maxLength={200} /></label>
        <label className="field">Outbound trunk ID<input name="outbound_trunk_id" required maxLength={200} /></label>
        <label className="field">Assigned workspace member<select name="user_id" required><option value="">Choose a member</option>{eligible.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select></label>
        <label className="field">Extension<input name="extension" inputMode="numeric" required maxLength={8} /></label>
        <label className="field">Reason<textarea name="reason" required minLength={3} maxLength={500} /></label>
        <button className="button primary" type="submit">Inspect setup</button>
      </fieldset>
    </form>}
    {state?.commands.map((command) => <form key={command.id} id={`phone-provisioning-${command.id}`} onSubmit={(event) => event.preventDefault()}>
      <h4>{command.desired.phone_number} · {command.status}</h4>
      <p>Inbound {command.desired.inbound_trunk_id} · outbound {command.desired.outbound_trunk_id} · extension {command.desired.extension}</p>
      {command.failure_reason && <p>{command.failure_reason.replaceAll("_", " ")}</p>}
      {command.status === "verified" && <p>Apply rechecks provider resources and current member eligibility. It creates a private individual dispatch rule only when none exists.</p>}
      {command.status === "unknown" && <p>An earlier create may have succeeded. Reconciliation only reads the original provider resources and never repeats Create. If it remains absent or conflicting, the operator must investigate.</p>}
      {state.provider.ready && (command.status === "verified" || command.status === "unknown") && <>
        <label className="field">Reason for {command.status === "verified" ? "applying" : "reconciling"}<textarea name="reason" required minLength={3} maxLength={500} disabled={busy} /></label>
        <button className="button ghost" type="button" disabled={busy || command.effect_in_progress}
          onClick={(event) => { const form = event.currentTarget.form; if (form) void action(command, command.status === "verified" ? "apply" : "reconcile", form); }}>{command.status === "verified" ? "Apply verified setup" : "Reconcile original effect"}</button>
      </>}
    </form>)}
  </section>;
}
