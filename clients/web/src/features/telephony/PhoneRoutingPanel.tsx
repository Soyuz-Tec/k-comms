import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { useSession } from "../../app/session";
import { useStepUp, stepUpWasCancelled } from "../../app/step-up";
import { useWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import type { PhoneCapabilities, PhoneRoute, PhoneRouteInput } from "./types";

export function PhoneRoutingPanel() {
  const { api } = useSession();
  const { users } = useWorkspaceData();
  const { runWithStepUp } = useStepUp();
  const [route, setRoute] = useState<PhoneRoute | null>(null);
  const [capabilities, setCapabilities] = useState<PhoneCapabilities>({});
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const [routes, caps] = await Promise.all([api.phoneRoutes(), api.phoneCapabilities()]);
      setRoute(routes.data[0] ?? null); setCapabilities(caps);
    } catch (reason) { setError(errorText(reason)); }
    finally { setLoading(false); }
  }, [api]);
  useEffect(() => { void load(); }, [load]);
  const members = users.filter((user) => user.status === "active" && user.account_type !== "service" && user.account_type !== "guest");
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setError(null); setSaved(false);
    const form = new FormData(event.currentTarget);
    const mode = form.get("mode") === "queue" ? "queue" : "shared_line";
    const input: PhoneRouteInput = {
      name: String(form.get("name") ?? "").trim(), mode,
      policy: mode === "queue" ? "round_robin" : form.get("policy") === "round_robin" ? "round_robin" : "simultaneous",
      member_ids: form.getAll("member_ids").map(String), max_waiting: Number(form.get("max_waiting")),
      max_wait_seconds: Number(form.get("max_wait_seconds")), enabled: form.get("enabled") === "on",
      ...(route ? { version: route.version } : {}), reason: String(form.get("reason") ?? "").trim()
    };
    if (input.member_ids.length < 1 || input.member_ids.length > 25 || input.reason.length < 3) { setError("Choose 1–25 active members and enter a reason."); return; }
    setBusy(true);
    try { setRoute(await runWithStepUp(() => api.savePhoneRoute(input))); setSaved(true); }
    catch (reason) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  };
  return <section aria-labelledby="phone-routing-heading">
    <h3 id="phone-routing-heading">Queues and shared lines</h3>
    <p>Route the saved carrier number to active members. Current Do Not Disturb, access and call capacity are checked before admission.</p>
    {loading && <p role="status">Loading phone routing…</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {saved && <p role="status">Phone routing policy saved.</p>}
    {!loading && <form key={route ? `${route.id}:${route.version}` : "new"} onSubmit={(event) => void submit(event)}>
      <fieldset disabled={busy}>
        <legend>Routing policy</legend>
        <label>Route name<input name="name" defaultValue={route?.name ?? "Support"} maxLength={100} required /></label>
        <label>Route kind<select name="mode" defaultValue={route?.mode ?? "shared_line"}><option value="shared_line">Shared line</option><option value="queue">Waiting queue</option></select></label>
        <label>Shared line ring policy<select name="policy" defaultValue={route?.policy ?? "simultaneous"}><option value="simultaneous">Ring available members together</option><option value="round_robin">Offer to one member in turn</option></select></label>
        <p>Queues offer the oldest waiting call to one available member in turn. The first answering session and device own the call.</p>
        <fieldset><legend>Eligible members</legend>{members.map((member) => <label key={member.id}><input type="checkbox" name="member_ids" value={member.id} defaultChecked={route?.member_ids.includes(member.id)} />{member.display_name}</label>)}</fieldset>
        <label>Maximum waiting calls<input name="max_waiting" type="number" min={1} max={100} defaultValue={route?.max_waiting ?? 20} required /></label>
        <label>Maximum wait, seconds<input name="max_wait_seconds" type="number" min={10} max={600} defaultValue={route?.max_wait_seconds ?? 120} required /></label>
        <label><input name="enabled" type="checkbox" defaultChecked={route?.enabled ?? false} disabled={!capabilities.queues?.supported && !capabilities.shared_lines?.supported} />Enable routing</label>
        {!capabilities.queues?.supported && !capabilities.shared_lines?.supported && <p>A configured and qualified phone switch is required before enabling routing. Disabled policies can be saved for review.</p>}
        <label>Reason<textarea name="reason" minLength={3} maxLength={500} required /></label>
        <button type="submit" className="button primary" disabled={busy}>{busy ? "Saving…" : "Save routing"}</button>
      </fieldset>
    </form>}
    <button type="button" className="button ghost" disabled={busy} onClick={() => void load()}>Refresh routing</button>
  </section>;
}
