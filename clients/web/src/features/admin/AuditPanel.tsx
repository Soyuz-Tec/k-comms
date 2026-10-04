import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { AuditExportInput } from "../../api/contracts";
import type { AuditEvent, User } from "../../types";
import { errorText, formatDateTime } from "../../lib/format";
import { duplicateParticipantNames, participantIdentifier } from "../../lib/participantIdentity";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import "./EvidencePanels.css";

const emptyFilters = { q: "", action: "", resource_type: "", actor_user_id: "", request_id: "", after: "", before: "" };

export function AuditPanel({ api, users }: { api: ApiClient; users: User[] }) {
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [draft, setDraft] = useState(emptyFilters);
  const [applied, setApplied] = useState<AuditExportInput>({});
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [exportNotice, setExportNotice] = useState<string | null>(null);
  const requestGeneration = useRef(0);
  const exportInFlight = useRef(false);
  const { runWithStepUp } = useStepUp();
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const duplicateUserNames = useMemo(() => duplicateParticipantNames(users), [users]);

  const load = useCallback(async (cursor?: string) => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    try {
      const result = await runWithStepUp(() => api.auditEventsPage({ ...applied, limit: 100 }, cursor));
      if (generation !== requestGeneration.current) return;
      setEvents((current) => cursor
        ? [...new Map([...current, ...result.data].map((event) => [event.id, event])).values()]
        : result.data);
      setNextCursor(result.page.next_cursor);
    } catch (reason: unknown) {
      if (generation === requestGeneration.current && !stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [api, applied, runWithStepUp]);

  useEffect(() => {
    void load();
    return () => { requestGeneration.current += 1; };
  }, [load]);

  function applyFilters(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (exportInFlight.current || loading) return;
    const filters: AuditExportInput = {};
    for (const [key, value] of Object.entries(draft)) {
      const trimmed = value.trim();
      if (trimmed) Object.assign(filters, { [key]: key === "after" || key === "before" ? new Date(trimmed).toISOString() : trimmed });
    }
    if (filters.after && filters.before && Date.parse(filters.after) >= Date.parse(filters.before)) {
      setError("The end of the time window must follow its start.");
      return;
    }
    setEvents([]);
    setNextCursor(null);
    setExportNotice(null);
    setApplied(filters);
  }

  async function exportCsv() {
    if (exportInFlight.current || loading) return;
    exportInFlight.current = true;
    setExporting(true);
    setError(null);
    setExportNotice(null);
    try {
      const file = await runWithStepUp(() => api.exportAuditEvents({ ...applied, limit: 5_000 }));
      const url = URL.createObjectURL(file.blob);
      try {
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = file.filename;
        document.body.append(anchor);
        anchor.click();
        anchor.remove();
      } finally { URL.revokeObjectURL(url); }
      setExportNotice(file.truncated
        ? `Downloaded ${file.count} audit events. Refine the filter to export events beyond the 5,000-row limit.`
        : `Downloaded ${file.count} audit events.`);
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally { exportInFlight.current = false; setExporting(false); }
  }

  return <section className="data-card">
    <div className="card-heading"><div><span className="eyebrow">Privileged evidence</span><h2>Audit explorer</h2></div><button className="button secondary compact" type="button" disabled={exporting || loading} onClick={() => void exportCsv()}>{exporting ? "Exporting…" : "Export audit CSV"}</button></div>
    {error && <div className="form-error" role="alert">{error}<button className="button ghost compact" type="button" disabled={loading || exporting} onClick={() => void load()}>Retry audit load</button></div>}
    {exportNotice && <div className="inline-notice" role="status">{exportNotice}</div>}
    <form className="evidence-filter-grid" onSubmit={applyFilters}>
      <label className="field">Search audit events<input type="search" maxLength={200} value={draft.q} onChange={(event) => setDraft({ ...draft, q: event.target.value })} placeholder="Action, resource or identifier" /></label>
      <label className="field">Actor<select value={draft.actor_user_id} onChange={(event) => setDraft({ ...draft, actor_user_id: event.target.value })}><option value="">All actors</option>{users.map((user) => <option key={user.id} value={user.id}>{participantIdentifier(user, duplicateUserNames)}</option>)}</select></label>
      {([ ["action", "Action"], ["resource_type", "Resource type"], ["request_id", "Request ID"] ] as const).map(([key, label]) => <label key={key} className="field">{label}<input value={draft[key]} onChange={(event) => setDraft({ ...draft, [key]: event.target.value })} maxLength={200} /></label>)}
      <label className="field">From<input type="datetime-local" value={draft.after} onChange={(event) => setDraft({ ...draft, after: event.target.value })} /></label>
      <label className="field">Before<input type="datetime-local" value={draft.before} onChange={(event) => setDraft({ ...draft, before: event.target.value })} /></label>
      <div className="form-actions"><button className="button primary compact" type="submit" disabled={loading || exporting}>Apply filters</button><button className="button ghost compact" type="button" disabled={loading || exporting} onClick={() => { if (exportInFlight.current || loading) return; setDraft(emptyFilters); setEvents([]); setNextCursor(null); setExportNotice(null); setApplied({}); }}>Reset filters</button></div>
    </form>
    <p className="support-note">{events.length} matching events loaded{nextCursor ? " · More results available" : ""}. CSV uses the applied server filters across all matching events, up to 5,000 rows. Apply edited filters before exporting.</p>
    <div className="responsive-table" role="region" aria-label="Audit events" tabIndex={0}><table><thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Resource</th><th>Details</th></tr></thead><tbody>{events.map((event) => {
      const actor = event.actor_user_id ? usersById.get(event.actor_user_id) : undefined;
      const actorIdentifier = actor ? participantIdentifier(actor, duplicateUserNames) : event.actor_user_id?.slice(0, 8) || "System";
      return <tr key={event.id}><td>{formatDateTime(event.inserted_at)}</td><td>{actorIdentifier}</td><td><code>{event.action}</code></td><td>{event.resource_type} · {event.resource_id.slice(0, 8)}</td><td><details className="admin-evidence-detail"><summary>Event details</summary><dl><dt>Event ID</dt><dd>{event.id}</dd><dt>Actor ID</dt><dd>{event.actor_user_id || "System"}</dd><dt>Resource ID</dt><dd>{event.resource_id}</dd><dt>Request ID</dt><dd>{event.request_id || "—"}</dd></dl><pre>{JSON.stringify(event.metadata, null, 2)}</pre></details></td></tr>;
    })}</tbody></table></div>
    {loading && <p aria-live="polite">Loading audit events…</p>}
    {!loading && !error && events.length === 0 && <p className="empty-copy">No matching audit events.</p>}
    {nextCursor && <button className="button ghost" type="button" disabled={loading || exporting} onClick={() => void load(nextCursor)}>{loading ? "Loading…" : "Load more audit events"}</button>}
  </section>;
}
