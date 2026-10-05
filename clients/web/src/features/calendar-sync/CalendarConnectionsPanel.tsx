import { useCallback, useEffect, useState } from "react";
import { useSession } from "../../app/session";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { errorText } from "../../lib/format";
import type { CalendarConnectionsResponse, CalendarProvider } from "../../types/calendarSync";
import "./calendar-sync.css";

function CalendarConnectionsBody() {
  const { api, session } = useSession();
  const canExport = session?.user.account_type === "human" && session.user.access_scope === "workspace";
  const { runWithStepUp } = useStepUp();
  const [result, setResult] = useState<CalendarConnectionsResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => { setError(null); try { setResult(await api.calendarConnections()); }
    catch (reason) { setError(errorText(reason)); } }, [api]);
  useEffect(() => { let alive = true; void api.calendarConnections().then(next => { if (alive) setResult(next); })
    .catch(reason => { if (alive) setError(errorText(reason)); }); return () => { alive = false; }; }, [api]);
  async function authorize(provider: CalendarProvider, purpose: "export" | "cleanup") {
    if (!result) return; setBusy(true); setError(null);
    try {
      const next = await runWithStepUp(() => api.authorizeCalendar(provider, result.meta.policy.version, purpose));
      const url = new URL(next.authorization_url);
      if (url.protocol !== "https:" || url.username || url.password || url.hash || (url.port && url.port !== "443") ||
        url.hostname !== (provider === "google" ? "accounts.google.com" : "login.microsoftonline.com")) {
        throw new Error("The calendar provider authorization address is invalid.");
      }
      window.location.assign(url.href);
    } catch (reason) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  async function unlink(id: string, version: number) {
    setBusy(true); setError(null);
    try { await runWithStepUp(() => api.unlinkCalendar(id, version)); await load(); }
    catch (reason) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <section className="calendar-sync-panel" aria-labelledby="calendar-connections-heading">
    <h2 id="calendar-connections-heading">Connected calendars</h2>
    <p>Choose a calendar for meetings you host. Export is optional for each meeting. It sends the title, time, time zone and a member sign-in link. Invitations are never sent to attendees.</p>
    <p>Google requests access to events you own. Microsoft requests calendar read and write access and offline access. Existing external events are never imported.</p>
    {error && <p role="alert">{error}</p>}
    {!result && !error && <p role="status">Loading calendar connections…</p>}
    {result && <>
      {!canExport && <p>New exports require an active workspace member. Existing cleanup remains available.</p>}
      {!result.meta.policy.export_allowed && <p>Calendar export is disabled by workspace policy. Existing cleanup remains pending until verified.</p>}
      {result.meta.providers.map(provider => {
        const connection = result.data.find(item => item.provider === provider.provider);
        const pending = connection && ["removing", "held_cleanup_blocked", "reauthorization_required"].includes(connection.status);
        return <div className="calendar-sync-provider" key={provider.provider}>
          <h3>{provider.provider === "google" ? "Google Calendar" : "Microsoft Calendar"}</h3>
          <p>{connection ? connection.status.replaceAll("_", " ") : "Not connected"} · {connection?.managed_events_pending_removal ?? 0} managed events pending removal</p>
          {!provider.configured && <p>Unavailable in this deployment.</p>}
          {provider.configured && !provider.qualified && <p>Provider qualification is pending.</p>}
          {connection?.provider_grant_revocation === "external_unconfirmed" && <p>Local credentials were destroyed. Microsoft grant revocation is unconfirmed; remove the app grant in Microsoft account permissions. This does not establish a verified erasure receipt.</p>}
          {provider.configured && (!connection || (connection.status === "removed" && connection.provider_grant_revocation === "confirmed")) && <button className="button ghost" disabled={busy || !canExport || !result.meta.policy.export_allowed} onClick={() => void authorize(provider.provider, "export")}>Connect {provider.provider === "google" ? "Google" : "Microsoft"}</button>}
          {connection?.status === "ready" && <button className="button ghost" disabled={busy} onClick={() => void unlink(connection.id, connection.version)}>Disconnect and remove managed events</button>}
          {provider.configured && pending && <button className="button ghost" disabled={busy} onClick={() => void authorize(provider.provider, "cleanup")}>Authorize the same account for cleanup</button>}
        </div>;
      })}
    </>}
    <button className="button ghost" disabled={busy} onClick={() => void load()}>Refresh calendar status</button>
  </section>;
}

export function CalendarConnectionsPanel() {
  const [open, setOpen] = useState(() => new URLSearchParams(window.location.search).get("section") === "calendar");
  return <details className="calendar-sync-panel" open={open} onToggle={event => setOpen(event.currentTarget.open)}>
    <summary>Connected calendars</summary>{open && <CalendarConnectionsBody />}
  </details>;
}
