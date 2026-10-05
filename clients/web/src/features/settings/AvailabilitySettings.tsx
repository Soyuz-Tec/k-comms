import { useEffect, useState, type FormEvent } from "react";
import { useSession } from "../../app/session";
import { errorText } from "../../lib/format";
import type { Availability } from "../../types/enterpriseIdentity";

export function AvailabilitySettings() {
  const { api } = useSession();
  const [availability, setAvailability] = useState<Availability | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let current = true;
    if (typeof api.availability !== "function") return;
    api.availability().then((value) => current && setAvailability(value)).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget);
    setBusy(true); setError(null);
    try {
      const minutes = Number(data.get("duration") || "0");
      const until = minutes > 0 ? new Date(Date.now() + minutes * 60_000).toISOString() : null;
      const days = data.getAll("days").map(Number);
      const scheduled = data.get("schedule_enabled") === "on";
      const result = await api.updateAvailability({ presence_state: String(data.get("presence_state")) as Availability["presence_state"],
        presence_expires_at: until, dnd_until: null,
        dnd_schedule: scheduled ? { days, start: String(data.get("start")), end: String(data.get("end")) } : {} });
      setAvailability(result); setNotice("Availability saved. Do not disturb pauses email, push, and incoming ringing while keeping messages in your inbox.");
    } catch (reason: unknown) { setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <section className="settings-card enterprise-settings" aria-labelledby="availability-title"><h2 id="availability-title">Availability and do not disturb</h2>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    {availability && <form key={JSON.stringify(availability)} onSubmit={save}>
      <p>Current availability: {availability.status}. Schedules use {availability.timezone}.</p>
      <label className="field">Availability<select aria-label="Availability" name="presence_state" defaultValue={availability.presence_state}>{["available", "away", "busy", "dnd", "offline"].map((state) => <option key={state} value={state}>{state === "dnd" ? "Do not disturb" : state}</option>)}</select></label>
      <label className="field">Duration<select aria-label="Duration" name="duration" defaultValue="0"><option value="0">Until I change it</option><option value="30">30 minutes</option><option value="60">1 hour</option><option value="240">4 hours</option></select></label>
      <label><input name="schedule_enabled" type="checkbox" defaultChecked={!!availability.dnd_schedule.days?.length} />Enable weekly do not disturb schedule</label>
      <fieldset><legend>Days</legend>{["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((day, index) => <label key={day}><input name="days" type="checkbox" value={index + 1} defaultChecked={availability.dnd_schedule.days?.includes(index + 1)} />{day}</label>)}</fieldset>
      <label className="field">Start<input name="start" type="time" defaultValue={availability.dnd_schedule.start || "22:00"} /></label>
      <label className="field">End<input name="end" type="time" defaultValue={availability.dnd_schedule.end || "08:00"} /></label>
      <button className="button primary" disabled={busy}>Save availability</button>
    </form>}
  </section>;
}
