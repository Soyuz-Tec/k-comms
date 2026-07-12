import { useEffect, useMemo, useState } from "react";
import type { ApiClient } from "../../api";
import type { AuditEvent, User } from "../../types";
import { errorText, formatDateTime } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";

export function AuditPanel({ api, users }: { api: ApiClient; users: User[] }) {
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [exportNotice, setExportNotice] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  useEffect(() => {
    let current = true;
    void runWithStepUp(() => api.auditEvents())
      .then((values) => current && setEvents(values))
      .catch((reason: unknown) => { if (current && !stepUpWasCancelled(reason)) setError(errorText(reason)); });
    return () => { current = false; };
  }, [api, runWithStepUp]);
  const visible = events.filter((event) => `${event.action} ${event.resource_type} ${event.resource_id} ${event.actor_user_id || ""}`.toLowerCase().includes(query.trim().toLowerCase()));

  async function exportCsv() {
    setExporting(true);
    setError(null);
    setExportNotice(null);
    try {
      const trimmedQuery = query.trim();
      const file = await runWithStepUp(() => api.exportAuditEvents({
        ...(trimmedQuery ? { q: trimmedQuery } : {}),
        limit: 5_000
      }));
      const url = URL.createObjectURL(file.blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = file.filename;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);
      setExportNotice(file.truncated
        ? `Downloaded ${file.count} audit events. Refine the filter to export events beyond the 5,000-row limit.`
        : `Downloaded ${file.count} audit events.`);
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setExporting(false);
    }
  }

  return <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Privileged evidence</span><h2>Audit explorer</h2></div><div className="card-actions"><span className="status-pill success">Live API</span><button className="button secondary compact" type="button" disabled={exporting} onClick={() => void exportCsv()}>{exporting ? "Exporting…" : "Export audit CSV"}</button></div></div>{error && <div className="form-error" role="alert">{error}</div>}{exportNotice && <div className="inline-notice" role="status">{exportNotice}</div>}<label className="field audit-filter">Filter loaded events<input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Action, resource or actor ID" /></label><div className="responsive-table"><table><thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Resource</th><th>Request</th></tr></thead><tbody>{visible.map((event) => <tr key={event.id}><td>{formatDateTime(event.inserted_at)}</td><td>{event.actor_user_id ? usersById.get(event.actor_user_id)?.display_name || event.actor_user_id.slice(0, 8) : "System"}</td><td><code>{event.action}</code></td><td>{event.resource_type} · {event.resource_id.slice(0, 8)}</td><td>{event.request_id?.slice(0, 12) || "—"}</td></tr>)}</tbody></table></div>{visible.length === 0 && <p className="empty-copy">No matching audit events.</p>}</section>;
}
