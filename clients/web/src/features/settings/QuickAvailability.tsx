import { useId, useState } from "react";
import { Link } from "react-router";
import type { Availability } from "../../types/enterpriseIdentity";
import { availabilityLabels, useAvailability, type AvailabilityController } from "./useAvailability";
import "./quick-availability.css";

export function PersonalAvailability() {
  const controller = useAvailability();
  return <QuickAvailability controller={controller} />;
}

export function QuickAvailability({ controller, onSettings }: { controller: AvailabilityController; onSettings?: () => void }) {
  const id = useId();
  const { data, loading, error, busy, supported, generation, save, refresh } = controller;
  if (!supported) return null;
  return <section className="quick-availability" aria-labelledby={id}>
    <h2 id={id}>Your availability</h2>
    {loading && <p role="status">Checking availability…</p>}
    {error && <p role="alert">{error} <button type="button" className="button ghost compact" disabled={busy} onClick={() => void refresh()}>Retry availability</button></p>}
    {data && <QuickAvailabilityForm key={generation} data={data} busy={busy} save={save} />}
    <Link to="/app/you?section=notifications" onClick={onSettings}>Schedule and notification settings</Link>
  </section>;
}

function QuickAvailabilityForm({ data, busy, save }: { data: Availability; busy: boolean; save: AvailabilityController["save"] }) {
  const [notice, setNotice] = useState("");
  const [duration, setDuration] = useState("60");
  const deadline = data.dnd_active ? data.retry_at : data.presence_expires_at;
  const currentDeadline = deadline && Date.parse(deadline) > Date.now() ? deadline : null;
  async function change(presence: Availability["presence_state"], clear = false) {
    setNotice("");
    const result = await save((fresh) => ({
      presence_state: presence,
      presence_expires_at: clear || duration === "0" ? null : new Date(Date.now() + Number(duration) * 60_000).toISOString(),
      dnd_until: null,
      dnd_schedule: fresh.dnd_schedule
    }));
    if (result) setNotice(result.dnd_active && presence !== "dnd"
      ? `${clear ? "Manual status cleared." : `${availabilityLabels[presence]} saved.`} Your weekly do not disturb schedule is still active.`
      : `${availabilityLabels[result.status]} saved.`);
  }
  return <>
    <p className="quick-availability-current"><strong>{availabilityLabels[data.status]}</strong>{currentDeadline
      ? <span>Until <time dateTime={currentDeadline}>{new Intl.DateTimeFormat(undefined, { dateStyle: "short", timeStyle: "short", timeZone: data.timezone }).format(new Date(currentDeadline))}</time> · {data.timezone}</span>
      : <span>{data.status === "available" ? "Ready to connect" : "Until you change it"}</span>}</p>
    <div className="quick-availability-fields">
      <label className="field">Set status<select aria-label="Set status" value={data.status} disabled={busy} onChange={(event) => void change(event.currentTarget.value as Availability["presence_state"])}>{Object.entries(availabilityLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      <label className="field">For<select aria-label="Status duration" value={duration} disabled={busy} onChange={(event) => setDuration(event.currentTarget.value)}><option value="30">30 minutes</option><option value="60">1 hour</option><option value="240">4 hours</option><option value="0">Until I change it</option></select></label>
    </div>
    <div className="quick-availability-actions">
      <button type="button" className="button ghost compact" disabled={busy} onClick={() => void change("dnd")}>Pause notifications</button>
      {(data.presence_state !== "available" || data.presence_expires_at || data.dnd_until) && <button type="button" className="button ghost compact" disabled={busy} onClick={() => void change("available", true)}>Clear manual status</button>}
    </div>
    <p className="quick-availability-help">Do not disturb pauses email and push. Messages remain in your inbox.{data.dnd_schedule.days?.length ? " Your weekly schedule still applies." : ""}</p>
    {notice && <p role="status">{notice}</p>}
  </>;
}
