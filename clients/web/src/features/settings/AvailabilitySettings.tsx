import { useEffect, useState, type FormEvent } from "react";
import type { Availability } from "../../types/enterpriseIdentity";
import { useAvailability } from "./useAvailability";

type AvailabilityDraft = { presence: string; duration: string; days: number[]; start: string; end: string };

export function AvailabilitySettings() {
  const controller = useAvailability();
  return <AvailabilityEditor key={controller.generation} controller={controller} />;
}

function AvailabilityEditor({ controller }: { controller: ReturnType<typeof useAvailability> }) {
  const { data, denied, error, busy, loading, refresh } = controller;
  const [availability, setAvailability] = useState<Availability | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [scheduled, setScheduled] = useState(false);
  const [draft, setDraft] = useState<AvailabilityDraft | null>(null);
  useEffect(() => {
    if (denied) { setAvailability(null); setDraft(null); setDirty(false); setScheduled(false); }
  }, [denied]);
  useEffect(() => {
    if (data && !dirty) { setAvailability(data); setScheduled(!!data.dnd_schedule.days?.length); }
  }, [data, dirty]);
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget);
    setNotice(null);
    const duration = data.get("duration") || "0";
    const minutes = Number(duration);
    const until = duration === "keep" ? activeExpiry(availability) : minutes > 0 ? new Date(Date.now() + minutes * 60_000).toISOString() : null;
    const days = data.getAll("days").map(Number);
    const result = await controller.save({ presence_state: duration === "keep" && !until ? "available" : String(data.get("presence_state")) as Availability["presence_state"],
      presence_expires_at: until, dnd_until: null,
      dnd_schedule: scheduled ? { days, start: String(data.get("start")), end: String(data.get("end")) } : {} });
    if (result) { setAvailability(result); setDirty(false); setDraft(null); setNotice("Availability saved. Do not disturb pauses email and push while keeping messages in your inbox."); }
  }
  return <section className="settings-card enterprise-settings" aria-labelledby="availability-title"><h2 id="availability-title">Availability and do not disturb</h2>
    {loading && <p role="status">Checking availability…</p>}
    {error && <p role="alert">{error} <button type="button" className="button ghost compact" disabled={busy} onClick={() => void refresh()}>Retry availability</button></p>}{notice && data && <p role="status">{notice}</p>}
    {availability && data && <form key={JSON.stringify(availability)} onSubmit={save} onChange={(event) => {
      const values = new FormData(event.currentTarget);
      setDirty(true);
      setDraft({ presence: String(values.get("presence_state")), duration: String(values.get("duration")), days: values.getAll("days").map(Number), start: String(values.get("start") || "22:00"), end: String(values.get("end") || "08:00") });
    }}>
      <p>Current availability: {data.status}. Schedules use {data.timezone}.</p>
      <label className="field">Availability<select aria-label="Availability" name="presence_state" defaultValue={draft?.presence ?? (availability.presence_expires_at && !activeExpiry(availability) ? "available" : availability.presence_state)}>{["available", "away", "busy", "dnd", "offline"].map((state) => <option key={state} value={state}>{state === "dnd" ? "Do not disturb" : state}</option>)}</select></label>
      <label className="field">Duration<select aria-label="Duration" name="duration" defaultValue={draft?.duration ?? (activeExpiry(availability) ? "keep" : "0")}>{(activeExpiry(availability) || draft?.duration === "keep") && <option value="keep">Keep current expiry</option>}<option value="0">Until I change it</option><option value="30">30 minutes</option><option value="60">1 hour</option><option value="240">4 hours</option></select></label>
      <label><input name="schedule_enabled" type="checkbox" checked={scheduled} onChange={(event) => setScheduled(event.currentTarget.checked)} />Enable weekly do not disturb schedule</label>
      {scheduled && <><fieldset><legend>Days</legend>{["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((day, index) => <label key={day}><input name="days" type="checkbox" value={index + 1} defaultChecked={(draft?.days ?? availability.dnd_schedule.days)?.includes(index + 1)} />{day}</label>)}</fieldset>
      <label className="field">Start<input name="start" type="time" defaultValue={draft?.start ?? (availability.dnd_schedule.start || "22:00")} /></label>
      <label className="field">End<input name="end" type="time" defaultValue={draft?.end ?? (availability.dnd_schedule.end || "08:00")} /></label></>}
      <button className="button primary" disabled={busy}>Save availability</button>
    </form>}
  </section>;
}

function activeExpiry(value: Availability | null) {
  return value?.presence_expires_at && Date.parse(value.presence_expires_at) > Date.now() ? value.presence_expires_at : null;
}
