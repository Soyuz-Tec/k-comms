import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import type { VoicemailMailbox, VoicemailMailboxInput } from "./voicemailTypes";

export function VoicemailAdminPanel() {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const [box, setBox] = useState<VoicemailMailbox | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    let active = true;
    api.voicemailMailbox().then(value => { if (active) setBox(value); }).catch(reason => { if (active) setError(errorText(reason)); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [api]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const input: VoicemailMailboxInput = { user_id: String(form.get("user_id") ?? ""), enabled: form.get("enabled") === "on", retention_days: Number(form.get("retention_days")), notice_media: String(form.get("notice_media") ?? "").trim(), ...(box ? { version: box.version } : {}), reason: String(form.get("reason") ?? "").trim() };
    if (!users.some(user => user.id === input.user_id && user.status === "active" && user.account_type === "human") || !Number.isInteger(input.retention_days) || input.retention_days < 1 || input.retention_days > 90 || !/^sound:[A-Za-z0-9_/-]{1,150}$/.test(input.notice_media) || input.reason.length < 3) { setError("Choose an active member, 1–90 retention days, an installed caller notice, and a reason."); return; }
    setBusy(true); setError(null); setSaved(false);
    try { setBox(await runWithStepUp(() => api.saveVoicemailMailbox(input))); setSaved(true); }
    catch (reason) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <section aria-labelledby="voicemail-admin-heading">
    <h2 id="voicemail-admin-heading">Voicemail mailbox</h2>
    <p>Voicemail requires verified PBX recording, encrypted versioned storage, and an installed caller recording notice. The mailbox can remain off while those checks are completed.</p>
    {loading && <p role="status">Loading voicemail mailbox…</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p role="status">Mailbox settings saved.</p>}
    {!loading && <form key={box?.version ?? "new"} onSubmit={event => void submit(event)}>
      <fieldset disabled={busy}>
        <label className="field">Mailbox owner<select name="user_id" required defaultValue={box?.user_id ?? ""}><option value="">Choose a member</option>{users.filter(user => user.status === "active" && user.account_type === "human").map(user => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select></label>
        <label className="field">Retention days<input name="retention_days" type="number" min={1} max={90} required defaultValue={box?.retention_days ?? 30} /></label>
        <p>A longer workspace retention policy and active legal holds take precedence.</p>
        <label className="field">Caller recording notice<input name="notice_media" required maxLength={156} pattern="sound:[A-Za-z0-9_/-]{1,150}" placeholder="sound:custom/k-comms-recording-notice" defaultValue={box?.notice_media ?? ""} /></label>
        <p>Use the approved notice installed by your phone operator.</p>
        <label><input name="enabled" type="checkbox" defaultChecked={box?.enabled ?? false} /> Enable voicemail</label>
        <label className="field">Reason<textarea name="reason" required minLength={3} maxLength={500} /></label>
        <button className="button primary" type="submit">{busy ? "Saving mailbox…" : "Save voicemail mailbox"}</button>
      </fieldset>
    </form>}
  </section>;
}
