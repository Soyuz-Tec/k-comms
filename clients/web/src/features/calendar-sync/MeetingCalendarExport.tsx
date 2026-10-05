import { useEffect, useState } from "react";
import { useSession } from "../../app/session";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { errorText } from "../../lib/format";
import type { CalendarConnection, CalendarExport } from "../../types/calendarSync";
import type { Meeting } from "../../types/meetings";
import "./calendar-sync.css";

function MeetingCalendarExportBody({ meeting }: { meeting: Meeting }) {
  const { api } = useSession(); const { runWithStepUp } = useStepUp();
  const [connections, setConnections] = useState<CalendarConnection[]>([]);
  const [exports, setExports] = useState<CalendarExport[]>([]);
  const [error, setError] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const [refresh, setRefresh] = useState(0);
  useEffect(() => { let alive = true;
    void Promise.all([api.calendarConnections(), api.calendarExports(meeting.id)]).then(([connections, exports]) => {
      if (alive) { setConnections(connections.data); setExports(exports.data); }
    }).catch(reason => { if (alive) setError(errorText(reason)); }); return () => { alive = false; };
  }, [api, meeting.id, meeting.version, refresh]);
  async function act(action: () => Promise<unknown>) {
    setBusy(true); setError(null);
    try { await runWithStepUp(action); setRefresh(value => value + 1); }
    catch (reason) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <div>
    <p>Export this hosted meeting’s current occurrences. Existing calendar edits require your explicit decision.</p>
    {error && <p role="alert">{error}</p>}
    {connections.filter(connection => connection.new_exports_allowed).map(connection => {
      const item = exports.find(item => item.connection_id === connection.id);
      return <div key={connection.id}>
        <p>{connection.provider}: {item?.status ?? "Not exported"}</p>
        {!item && meeting.status === "scheduled" && <button className="button ghost compact" disabled={busy}
          onClick={() => void act(() => api.createCalendarExport(connection.id, meeting.id, meeting.version))}>Export to {connection.provider}</button>}
      </div>;
    })}
    {exports.map(item => <div key={item.id}><p>{item.status.replaceAll("_", " ")}{item.safe_reason ? ` · ${item.safe_reason.replaceAll("_", " ")}` : ""}</p>
      {["conflict", "blocked", "failed", "uncertain"].includes(item.status) && meeting.status === "scheduled" && <button className="button ghost compact" disabled={busy}
        onClick={() => void act(() => api.resolveCalendarExport(item.id, item.version, "reexport_current", meeting.version))}>Re-export current meeting</button>}
      {!["stopping", "removed"].includes(item.status) && <button className="button ghost compact" disabled={busy}
        onClick={() => void act(() => api.resolveCalendarExport(item.id, item.version, "stop_syncing", meeting.version))}>Stop syncing and remove managed events</button>}
    </div>)}
    {connections.length === 0 && <p>Connect a calendar from your profile to enable export.</p>}
    <button className="button ghost compact" disabled={busy} onClick={() => setRefresh(value => value + 1)}>Refresh export status</button>
  </div>;
}

export function MeetingCalendarExport({ meeting }: { meeting: Meeting }) {
  const [open, setOpen] = useState(false);
  return <details className="calendar-sync-meeting" open={open} onToggle={event => setOpen(event.currentTarget.open)}>
    <summary>External calendar export</summary>{open && <MeetingCalendarExportBody meeting={meeting} />}
  </details>;
}
