import { useEffect, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { errorText, formatDateTime } from "../../lib/format";
import type { QueueSnapshot } from "./ivrTypes";

export function QueueSupervisorPanel() {
  const { api } = useSession();
  const { runWithStepUp } = useStepUp();
  const [snapshot, setSnapshot] = useState<QueueSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const generation = useRef(0);
  useEffect(() => { generation.current += 1; setSnapshot(null); setBusy(false); setError(null); return () => { generation.current += 1; }; }, [api]);
  async function load() {
    const current = generation.current;
    setBusy(true); setError(null);
    try {
      const value = await runWithStepUp(() => api.phoneQueueSnapshot());
      if (current === generation.current) setSnapshot(value);
    } catch (reason) { if (current === generation.current && !stepUpWasCancelled(reason)) setError(errorText(reason)); }
    finally { if (current === generation.current) setBusy(false); }
  }
  return <section className="phone-queue-supervision" aria-labelledby="phone-queue-supervision-heading">
    <h2 id="phone-queue-supervision-heading">Current queues</h2>
    <p>Review current waiting, offered, and answered calls with administrator verification. Counts do not show online agents or historical service levels.</p>
    <button className="button ghost" type="button" disabled={busy} onClick={() => void load()}>{busy ? "Loading current queues…" : snapshot ? "Refresh current queues" : "Load current queues"}</button>
    {error && <p className="form-error" role="alert">{error}</p>}
    {snapshot && <>
      <p>Observed {formatDateTime(snapshot.observed_at)}. Oldest wait is measured from the call’s original start.</p>
      {snapshot.routes.length === 0 ? <p>No queue or shared line configured.</p> : <div className="phone-queue-table"><table>
        <caption>Current retained calls by configured route</caption>
        <thead><tr><th scope="col">Route</th><th scope="col">Waiting</th><th scope="col">Offered</th><th scope="col">Answered</th><th scope="col">Oldest wait</th><th scope="col">Configured members</th></tr></thead>
        <tbody>{snapshot.routes.map(route => <tr key={route.id}><th scope="row">{route.name}{!route.enabled ? " (off)" : ""}</th><td>{route.waiting_calls} / {route.max_waiting}</td><td>{route.offered_calls}</td><td>{route.answered_calls}</td><td>{route.oldest_observed_wait_seconds === null ? "—" : `${route.oldest_observed_wait_seconds}s`}</td><td>{route.configured_members}</td></tr>)}</tbody>
      </table></div>}
    </>}
  </section>;
}
