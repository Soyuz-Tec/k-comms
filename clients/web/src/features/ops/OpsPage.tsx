import { useCallback, useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { useSession } from "../../app/session";
import type { OperationsSnapshot } from "../../types";
import { errorText, formatDateTime } from "../../lib/format";
import { canOperate } from "../../lib/roles";

export function OpsPage() {
  const { api, session } = useSession();
  const [snapshot, setSnapshot] = useState<OperationsSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true); setError(null);
    try { setSnapshot(await api.platformOperations()); } catch (reason: unknown) { setError(errorText(reason)); } finally { setLoading(false); }
  }, [api]);

  useEffect(() => { void refresh(); const timer = window.setInterval(() => void refresh(), 30_000); return () => window.clearInterval(timer); }, [refresh]);

  if (!session) return null;
  if (!canOperate(session.user.platform_role, session.user.platform_role_expires_at)) return <Navigate to="/app" replace />;

  const failures = (snapshot?.notifications.failed || 0) + (snapshot?.notifications.dead_letter || 0) + (snapshot?.webhooks.failed || 0) + (snapshot?.webhooks.dead_letter || 0) + (snapshot?.attachments.failed || 0);
  return <main className="page-shell" id="main-content">
    <header className="page-heading"><div><span className="eyebrow">Platform operations</span><h1>Service operations</h1><p>Monitor content-blind global queue, delivery, scanning, database and provider health without tenant message access.</p></div><button className="button ghost" type="button" disabled={loading} onClick={() => void refresh()}>{loading ? "Refreshing…" : "Refresh"}</button></header>
    {error && <div className="inline-notice error" role="alert">{error}</div>}
    <section className="admin-stats"><article><span>Scope</span><strong className="word-stat">Platform-wide</strong><small>Content-blind global health</small></article><article><span>Outbox pending</span><strong>{snapshot?.outbox.pending ?? "—"}</strong><small>{snapshot?.outbox.published ?? 0} published</small></article><article><span>Delivery failures</span><strong>{snapshot ? failures : "—"}</strong><small>Notifications, webhooks and scans</small></article></section>
    {snapshot && <>
      <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Worker execution</span><h2>Queues</h2></div><span className="status-pill success">Generated {formatDateTime(snapshot.generated_at)}</span></div>{snapshot.queues.length === 0 ? <p className="empty-copy">No platform queue jobs.</p> : <div className="responsive-table"><table><thead><tr><th>Queue</th><th>State</th><th>Count</th><th>Oldest scheduled</th></tr></thead><tbody>{snapshot.queues.map((queue) => <tr key={`${queue.queue}-${queue.state}`}><td>{queue.queue}</td><td><span className={`status-pill ${queue.state === "completed" ? "success" : "neutral"}`}>{queue.state}</span></td><td>{queue.count}</td><td>{formatDateTime(queue.oldest_scheduled_at)}</td></tr>)}</tbody></table></div>}</section>
      <div className="settings-grid ops-grid"><StatusCounts title="Notifications" values={snapshot.notifications} /><StatusCounts title="Webhooks" values={snapshot.webhooks} /><StatusCounts title="Attachment scans" values={snapshot.attachments} /><article className="settings-card"><div className="card-heading"><h2>Providers</h2><span className="status-pill success">Configured state</span></div><dl className="definition-list compact-list">{Object.entries(snapshot.providers).map(([name, value]) => <div key={name}><dt>{name.replace("_", " ")}</dt><dd>{typeof value === "string" ? value : value.status || value.reason || "configured"}</dd></div>)}</dl></article></div>
    </>}
  </main>;
}

function StatusCounts({ title, values }: { title: string; values: Record<string, number> }) {
  return <article className="settings-card"><div className="card-heading"><h2>{title}</h2><span className="status-pill neutral">Pipeline</span></div><dl className="definition-list compact-list">{Object.keys(values).length === 0 ? <div><dt>Status</dt><dd>No records</dd></div> : Object.entries(values).map(([status, count]) => <div key={status}><dt>{status.replace("_", " ")}</dt><dd>{count}</dd></div>)}</dl></article>;
}
