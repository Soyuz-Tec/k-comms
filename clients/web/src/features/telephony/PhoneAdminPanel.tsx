import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import { useTelephony } from "./TelephonyProvider";
import type { PhoneNumberAssignment, PhoneNumberInput } from "./types";

export function PhoneAdminPanel() {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const { refresh } = useTelephony();
  const [number, setNumber] = useState<PhoneNumberAssignment | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const reasonRef = useRef<HTMLTextAreaElement | null>(null);
  useEffect(() => {
    let current = true;
    void api.phoneNumberAssignment().then((assignment) => { if (current) setNumber(assignment); }).catch((reason: unknown) => { if (current) setError(errorText(reason)); }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [api]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const input = Object.fromEntries(["phone_number", "extension", "user_id", "inbound_trunk_id", "outbound_trunk_id", "reason"].map((name) => [name, String(form.get(name) ?? "").trim()])) as unknown as PhoneNumberInput;
    setBusy(true);
    setError(null);
    setSaved(false);
    try {
      const result = await runWithStepUp(() => api.updatePhoneNumber(input));
      setNumber(result);
      if (reasonRef.current) reasonRef.current.value = "";
      setSaved(true);
      await refresh();
    } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }

  return <section className="phone-admin-panel" aria-labelledby="phone-admin-heading">
    <h2 id="phone-admin-heading">Workspace phone line</h2>
    <p>Assign one carrier number to a workspace member and extension. Create the phone number and SIP trunks with your provider first. Provider credentials belong in secure environment settings.</p>
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p role="status">Phone line saved.</p>}
    {loading ? <p role="status">Loading phone settings…</p> : <form key={number?.id ?? "new"} onSubmit={(event) => void submit(event)}>
      <label className="field">Phone number<input name="phone_number" type="tel" defaultValue={number?.phone_number ?? ""} placeholder="+14155550123" pattern="\+[1-9][0-9]{7,14}" required disabled={busy} /></label>
      <label className="field">Extension<input name="extension" inputMode="numeric" defaultValue={number?.extension ?? ""} pattern="[0-9]{2,8}" required disabled={busy} /></label>
      <label className="field">Assigned member<select name="user_id" defaultValue={number?.user_id ?? ""} required disabled={busy}><option value="">Choose a member</option>{users.filter((user) => user.status === "active" && user.account_type !== "service" && user.account_type !== "guest").map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select></label>
      <label className="field">Inbound SIP trunk ID<input name="inbound_trunk_id" defaultValue={number?.inbound_trunk_id ?? ""} required disabled={busy} /></label>
      <label className="field">Outbound SIP trunk ID<input name="outbound_trunk_id" defaultValue={number?.outbound_trunk_id ?? ""} required disabled={busy} /></label>
      <label className="field">Reason for this change<textarea ref={reasonRef} name="reason" required minLength={3} maxLength={500} disabled={busy} /></label>
      <button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save phone line"}</button>
    </form>}
  </section>;
}
