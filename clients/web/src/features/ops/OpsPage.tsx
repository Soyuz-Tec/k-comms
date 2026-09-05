import { useCallback, useEffect, useState } from "react";
import { Navigate } from "react-router";
import { useSession } from "../../app/session";
import type { OperationsSnapshot } from "../../types";
import { errorText, formatDateTime } from "../../lib/format";
import { canOperate } from "../../lib/roles";
import { AppIcon } from "../../components/AppIcon";
import { deriveOperationsTriage, type OperationsTriageItem } from "./triage";
import "./OpsPage.css";

export function OpsPage() {
  const { api, session } = useSession();
  const [snapshot, setSnapshot] = useState<OperationsSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const authorized = Boolean(
    session &&
      canOperate(session.user.platform_role, session.user.platform_role_expires_at)
  );

  const refresh = useCallback(async () => {
    if (!authorized) {
      setLoading(false);
      return;
    }
    setLoading(true); setError(null);
    try { setSnapshot(await api.platformOperations()); } catch (reason: unknown) { setError(errorText(reason)); } finally { setLoading(false); }
  }, [api, authorized]);

  useEffect(() => {
    if (!authorized) return;
    void refresh();
    const timer = window.setInterval(() => void refresh(), 30_000);
    return () => window.clearInterval(timer);
  }, [authorized, refresh]);

  if (!session) return null;
  if (!authorized) return <Navigate to="/app/" replace />;

  const failures = (snapshot?.notifications.failed || 0) + (snapshot?.notifications.dead_letter || 0) + (snapshot?.webhooks.failed || 0) + (snapshot?.webhooks.dead_letter || 0) + (snapshot?.attachments.failed || 0) + (snapshot?.attachments.cleanup_failed || 0);
  const triage = snapshot ? deriveOperationsTriage(snapshot) : [];
  const actionableTriage = triage.filter(({ severity }) => severity !== "healthy").length;
  const orderedTriage = [...triage].sort((left, right) => ({ critical: 0, warning: 1, healthy: 2 })[left.severity] - ({ critical: 0, warning: 1, healthy: 2 })[right.severity]);
  const evidenceState = triage.map(({ id, severity }) => `${id}:${severity}`).join("|");
  const releaseBound = /^[0-9a-f]{40}$/.test(snapshot?.release_revision || "");
  return <main className="page-shell ops-page" id="main-content">
    <header className="page-heading"><div><span className="eyebrow">Platform operations</span><h1>Service operations</h1><p>Monitor content-blind global queue, delivery, scanning, database and provider health without tenant message access.</p></div><button className="button ghost" type="button" disabled={loading} onClick={() => void refresh()}>{loading ? "Refreshing…" : "Refresh"}</button></header>
    {error && <div className="inline-notice error" role="alert">{error}</div>}
    <section className="admin-stats ops-summary" aria-label="Platform operations summary" tabIndex={0}><article><span>Scope</span><strong className="word-stat">Platform-wide</strong><small>Content-blind global health</small></article><article><span>Conditions to review</span><strong>{snapshot ? actionableTriage : "—"}</strong><small>{snapshot ? `${triage.length - actionableTriage} healthy checks` : "Awaiting current evidence"}</small></article><article><span>Outbox pending</span><strong>{snapshot?.outbox.pending ?? "—"}</strong><small>{snapshot?.outbox.published ?? 0} published</small></article><article><span>Delivery failures</span><strong>{snapshot ? failures : "—"}</strong><small>Notifications, webhooks and scans</small></article></section>
    {snapshot && <>
      <nav className="ops-section-nav" aria-label="Operations sections">
        <a href="#ops-triage"><AppIcon name="activity" />Triage</a>
        <a href="#ops-queues" onClick={() => openEvidenceSection("ops-queues")}><AppIcon name="clock" />Queues</a>
        <a href="#ops-pipelines" onClick={() => openEvidenceSection("ops-pipelines")}><AppIcon name="sliders" />Pipelines &amp; providers</a>
      </nav>
      <section className="data-card" id="ops-triage" aria-labelledby="ops-triage-heading">
        <div className="card-heading"><div><span className="eyebrow">Guided response</span><h2 id="ops-triage-heading">Operations triage</h2></div><span className={`status-pill ${actionableTriage === 0 ? "success" : "neutral"}`}>{actionableTriage === 0 ? "No action required" : `${actionableTriage} conditions need review`}</span></div>
        <p className="muted-copy ops-evidence-time">Updated {formatDateTime(snapshot.generated_at)}. Expand a check for response guidance.</p>
        <ul className="security-list ops-triage-list">{orderedTriage.map((item) => <TriageCard key={`${item.id}:${item.severity}`} item={item} />)}</ul>
        <p className="muted-copy ops-runbook-note">{releaseBound ? `Runbooks are bound to release ${snapshot.release_revision.slice(0, 12)}.` : "Versioned runbooks are unavailable for this unbound development build."} Provider and backup authority comes from the approved environment receipt.</p>
      </section>
      <details key={`queues:${evidenceState}`} className="data-card ops-evidence-section" id="ops-queues" open={actionableTriage > 0}>
        <summary><h2>Queues</h2><span className="muted-copy">{snapshot.queues.reduce((count, queue) => count + queue.count, 0)} recorded jobs</span><AppIcon name="chevronDown" /></summary>
        {snapshot.queues.length === 0 ? <p className="empty-copy">No platform queue jobs.</p> : <div className="responsive-table" role="region" aria-label="Worker queues" tabIndex={0}><table><thead><tr><th>Queue</th><th>State</th><th>Count</th><th>Oldest scheduled</th></tr></thead><tbody>{snapshot.queues.map((queue) => <tr key={`${queue.queue}-${queue.state}`}><td>{queue.queue}</td><td><span className={`status-pill ${queue.state === "completed" ? "success" : "neutral"}`}>{queue.state}</span></td><td>{queue.count}</td><td>{formatDateTime(queue.oldest_scheduled_at)}</td></tr>)}</tbody></table></div>}
      </details>
      <details key={`pipelines:${evidenceState}`} className="data-card ops-evidence-section" id="ops-pipelines" open={actionableTriage > 0}>
        <summary><h2>Pipelines &amp; providers</h2><span className="muted-copy">{failures} failures</span><AppIcon name="chevronDown" /></summary>
        <div className="settings-grid ops-grid"><StatusCounts title="Notifications" values={snapshot.notifications} /><StatusCounts title="Webhooks" values={snapshot.webhooks} /><StatusCounts title="Attachment scans" values={snapshot.attachments} /><article className="settings-card"><div className="card-heading"><h2>Providers</h2><span className="status-pill neutral">Configured state</span></div><dl className="definition-list compact-list">{Object.entries(snapshot.providers).map(([name, value]) => <div key={name}><dt>{name.replace("_", " ")}</dt><dd>{typeof value === "string" ? value : value.status || value.reason || "configured"}</dd></div>)}</dl></article></div>
      </details>
    </>}
  </main>;
}

function TriageCard({ item }: { item: OperationsTriageItem }) {
  return <li className={`ops-triage-item ${item.severity}`}>
    <details open={item.severity !== "healthy"}>
      <summary>
        <div className="ops-check-heading"><strong>{item.title}</strong><span className={`status-pill ${item.severity === "healthy" ? "success" : item.severity === "critical" ? "danger" : "neutral"}`}>{item.severity}</span><AppIcon name="chevronDown" /></div>
        <span className="ops-condition">{item.condition}</span>
      </summary>
      <dl className="definition-list compact-list"><div><dt>User impact</dt><dd>{item.userImpact}</dd></div><div><dt>Owner</dt><dd>{item.owner}</dd></div><div><dt>Safe first action</dt><dd>{item.firstAction}</dd></div><div><dt>Stop condition</dt><dd>{item.stopCondition}</dd></div><div><dt>Escalation</dt><dd>{item.escalation}</dd></div></dl>
    </details>
    {item.runbookUrl ? <a href={item.runbookUrl} target="_blank" rel="noreferrer" aria-label={`Open versioned runbook for ${item.title}`}>Runbook <AppIcon name="externalLink" /></a> : <span className="muted-copy">Runbook unavailable</span>}
  </li>;
}

function openEvidenceSection(id: string) {
  const section = document.getElementById(id);
  if (section instanceof HTMLDetailsElement) section.open = true;
}

function StatusCounts({ title, values }: { title: string; values: Record<string, number> }) {
  return <article className="settings-card"><div className="card-heading"><h2>{title}</h2><span className="status-pill neutral">Pipeline</span></div><dl className="definition-list compact-list">{Object.keys(values).length === 0 ? <div><dt>Status</dt><dd>No records</dd></div> : Object.entries(values).map(([status, count]) => <div key={status}><dt>{status.replace("_", " ")}</dt><dd>{count}</dd></div>)}</dl></article>;
}
