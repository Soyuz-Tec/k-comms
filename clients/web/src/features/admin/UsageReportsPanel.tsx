import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { StepUpCancelledError, stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { formatDateTime } from "../../lib/format";
import { canAdministerTenant } from "../../lib/roles";
import type { UsageProjection, UsageQuery, UsageReport, UsageSource, UsageSourceKey } from "../../types/usage";
import "./UsageReportsPanel.css";

type UsageApi = Pick<ApiClient, "usageReport" | "exportUsageReport">;
type DateWindow = { from: string; through: string };
interface SourceDefinition { title: string; explanation: string; current: Record<string, string>; daily: Record<string, string> }
const sources: Record<UsageSourceKey, SourceDefinition> = {
  identity: { title: "Accounts", explanation: "Active humans include conversation-only accounts, not workspace seats or licenses. Active services count service identities, not valid credentials.",
    current: { active_humans: "Active human accounts", active_services: "Active service identities" }, daily: { humans_created: "Retained humans created", services_created: "Retained services created" } },
  conversations: { title: "Conversations", explanation: "Counts cover currently retained conversations. Creation cohorts do not reconstruct earlier membership or activity.",
    current: { active_conversations: "Active retained conversations" }, daily: { direct_created: "Retained direct conversations created", group_created: "Retained group conversations created", channel_created: "Retained channels created" } },
  messages: { title: "Messages", explanation: "Daily status counts show the current state of retained messages created on each day, not their state on that historical day.",
    current: { retained_messages: "Retained message records" }, daily: { created: "Retained messages created", current_active: "Currently active in creation cohort", current_deleted: "Currently deleted in creation cohort", current_moderated: "Currently moderated in creation cohort" } },
  attachments: { title: "Attachments", explanation: "Ready bytes count original retained attachments only. Variants, recordings and other media or versions are excluded; this is not total storage usage.",
    current: { ready_retained_count: "Ready retained originals", ready_retained_bytes: "Ready original bytes" }, daily: { created: "Retained attachments created", ready_count: "Currently ready in creation cohort", ready_bytes: "Current ready original bytes in creation cohort" } },
  calls: { title: "Meeting calls", explanation: "Current status rows may await cleanup. Daily statuses are the current state of retained start cohorts. Room seconds overlap each UTC day, clipped to observed lifecycle and expiry; they do not measure attendance or media activity.",
    current: { current_active: "Currently active retained rooms", current_ending: "Currently ending retained rooms" },
    daily: { started: "Retained rooms started", audio_started: "Retained audio rooms started", video_started: "Retained video rooms started", status_active: "Currently active in start cohort", status_ending: "Currently ending in start cohort", status_ended: "Currently ended in start cohort", observed_room_seconds: "Observed room lifecycle seconds overlapping day" } },
  telephony: { title: "Telephony", explanation: "Current status rows may await cleanup. Daily statuses are the current state of retained start cohorts. Answered seconds overlap each UTC day and observed lifecycle, not carrier billing; a call started before the window can contribute seconds without a start in that day.",
    current: { current_ringing: "Currently ringing retained calls", current_answered: "Currently answered retained calls" },
    daily: { started: "Retained phone calls started", inbound_started: "Retained inbound calls started", outbound_started: "Retained outbound calls started", status_ringing: "Currently ringing in start cohort", status_answered: "Currently answered in start cohort", status_declined: "Currently declined in start cohort", status_no_answer: "Currently unanswered in start cohort", status_cancelled: "Currently cancelled in start cohort", status_failed: "Currently failed in start cohort", status_ended: "Currently ended in start cohort", status_busy: "Currently busy in start cohort", observed_answered_seconds: "Observed answered lifecycle seconds overlapping day" } }
};

function utcToday() { return new Date().toISOString().slice(0, 10); }
function initialWindow(): DateWindow {
  const through = utcToday();
  return { through, from: new Date(Date.parse(`${through}T00:00:00Z`) - 29 * 86400000).toISOString().slice(0, 10) };
}
function validWindow(value: DateWindow) {
  const dates = [value.from, value.through];
  if (dates.some((date) => !/^\d{4}-\d{2}-\d{2}$/.test(date) || !Number.isFinite(Date.parse(`${date}T00:00:00Z`)) || new Date(`${date}T00:00:00Z`).toISOString().slice(0, 10) !== date)) return false;
  const days = (Date.parse(`${value.through}T00:00:00Z`) - Date.parse(`${value.from}T00:00:00Z`)) / 86400000;
  return days >= 0 && days <= 30 && value.through <= utcToday();
}

export function UsageReportsPanel({ api }: { api: UsageApi }) {
  const { session } = useSession();
  const allowed = Boolean(session && canAdministerTenant(session.user.role) &&
    (session.user.account_type || "human") === "human" && (session.user.access_scope || "workspace") === "workspace");
  const scope = `${session?.tenant.id || ""}:${session?.user.id || ""}:${session?.device?.id || ""}:${session?.user.role || ""}:${session?.user.access_scope || ""}:${session?.access_token || ""}`;
  const identity = useRef({ scope, serial: 0 });
  if (identity.current.scope !== scope) identity.current = { scope, serial: identity.current.serial + 1 };
  if (!allowed) return <p role="alert">Usage reports require a current owner or administrator account with full workspace access.</p>;
  return <UsageReportsContent key={identity.current.serial} api={api} />;
}

function UsageReportsContent({ api }: { api: UsageApi }) {
  const { runWithStepUp } = useStepUp();
  const [draft, setDraft] = useState<DateWindow>(initialWindow);
  const [applied, setApplied] = useState<UsageQuery>({});
  const [attempt, setAttempt] = useState(0);
  const [report, setReport] = useState<UsageReport | null>(null);
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [denied, setDenied] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const generation = useRef(0);
  const busy = useRef(false);
  const reportRef = useRef(report);
  reportRef.current = report;
  const initialDraft = useRef(draft);
  const fail = useCallback((reason: unknown) => {
    if (stepUpWasCancelled(reason)) return;
    if (reason instanceof ApiError && ([401, 403, 404].includes(reason.status) || reason.code === "session_changed")) {
      setReport(null); reportRef.current = null; setNotice(null); setDenied(true);
      setError("Usage details are unavailable with your current access. Verify your account or ask an authorized owner.");
    } else if (reason instanceof ApiError && reason.code === "invalid_usage_query") {
      setError("Choose a valid inclusive UTC date range of 1 to 31 days, ending today or earlier.");
    } else if (reason instanceof ApiError && reason.code === "usage_report_too_large") {
      setError("This report exceeds the export limit. Apply a shorter date range before exporting.");
    } else {
      setError("Usage reporting could not be retrieved or verified. Retry the applied date range.");
    }
  }, []);

  const load = useCallback(async (input: UsageQuery) => {
    if (busy.current) return;
    busy.current = true;
    const request = ++generation.current;
    setLoading(true); setError(null); setNotice(null);
    try {
      const value = await runWithStepUp(() => {
        if (request !== generation.current) throw new StepUpCancelledError();
        return api.usageReport(input).catch((reason: unknown) => {
          if (request === generation.current && reason instanceof ApiError && [401, 403, 404].includes(reason.status)) fail(reason);
          throw reason;
        });
      });
      if (request !== generation.current) return;
      if (value.range.time_zone !== "UTC" || value.coverage !== "currently_retained_records" || value.lifetime_complete !== false ||
          !validWindow(value.range) || (input.from && value.range.from !== input.from) || (input.through && value.range.through !== input.through)) {
        throw new ApiError(502, "invalid_usage_report", "The usage report window could not be verified.");
      }
      setReport(value); reportRef.current = value; setDenied(false);
      setDraft((current) => current.from === initialDraft.current.from && current.through === initialDraft.current.through ? { from: value.range.from, through: value.range.through } : current);
    } catch (reason: unknown) { if (request === generation.current) fail(reason); }
    finally { if (request === generation.current) { busy.current = false; setLoading(false); } }
  }, [api, fail, runWithStepUp]);

  useEffect(() => { void load(applied); return () => { generation.current += 1; busy.current = false; }; }, [applied, attempt, load]);
  useEffect(() => {
    const revalidate = () => {
      const current = reportRef.current;
      if (document.visibilityState !== "hidden" && current && !busy.current && !denied) void load({ from: current.range.from, through: current.range.through });
    };
    window.addEventListener("focus", revalidate); document.addEventListener("visibilitychange", revalidate);
    return () => { window.removeEventListener("focus", revalidate); document.removeEventListener("visibilitychange", revalidate); };
  }, [denied, load]);

  function apply(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy.current) return;
    if (!validWindow(draft)) { setError("Choose a valid inclusive UTC date range of 1 to 31 days, ending today or earlier."); return; }
    setReport(null); reportRef.current = null; setNotice(null);
    setApplied({ ...draft });
  }
  function retryApplied() {
    const current = reportRef.current;
    if (current) void load({ from: current.range.from, through: current.range.through });
    else setAttempt((value) => value + 1);
  }

  async function exportCsv() {
    const current = reportRef.current;
    if (!current || busy.current || denied) return;
    busy.current = true;
    const request = ++generation.current;
    setExporting(true); setError(null); setNotice(null);
    const input = { from: current.range.from, through: current.range.through };
    try {
      const file = await runWithStepUp(() => {
        if (request !== generation.current) throw new StepUpCancelledError();
        return api.exportUsageReport(input).catch((reason: unknown) => {
          if (request === generation.current && reason instanceof ApiError && [401, 403, 404].includes(reason.status)) fail(reason);
          throw reason;
        });
      });
      if (request !== generation.current) return;
      if (file.usage.from !== input.from || file.usage.through !== input.through || file.usage.timeZone !== "UTC") {
        throw new ApiError(502, "invalid_usage_export", "The usage export window could not be verified.");
      }
      const url = URL.createObjectURL(file.blob);
      try {
        const anchor = document.createElement("a"); anchor.href = url; anchor.download = file.filename;
        document.body.append(anchor); anchor.click(); anchor.remove();
      } finally { URL.revokeObjectURL(url); }
      setNotice(`Downloaded retained usage for ${file.usage.from} through ${file.usage.through} UTC. ${file.usage.unavailableSources} sources unavailable. Export observed ${formatDateTime(file.usage.observedAt)}; this is a new observation of the same date window, not an immutable or billing snapshot.`);
    } catch (reason: unknown) { if (request === generation.current) fail(reason); }
    finally { if (request === generation.current) { busy.current = false; setExporting(false); } }
  }

  return <section className="data-card usage-reports" aria-label="Retained usage report">
    <div className="card-heading"><div><span className="eyebrow">Workspace activity</span><h2>Usage reports</h2></div>{report && !denied && <span className="status-pill neutral">{Object.values(report.sources).filter((source) => source.status === "available" && source.data).length} of 6 sources reported</span>}</div>
    <p>Currently retained records, not complete lifetime history, license usage or carrier billing. Each source has its own observation; these totals are not an atomic snapshot across sources.</p>
    <form className="usage-window-form" onSubmit={apply} noValidate>
      <label className="field">From (UTC)<input type="date" required value={draft.from} max={utcToday()} onChange={(event) => setDraft({ ...draft, from: event.target.value })} /></label>
      <label className="field">Through (UTC, inclusive)<input type="date" required value={draft.through} max={utcToday()} onChange={(event) => setDraft({ ...draft, through: event.target.value })} /></label>
      <button type="submit" className="button primary compact" disabled={loading || exporting}>Apply date window</button>
    </form>
    <p>Choose at most 31 inclusive UTC days. Apply edited dates before exporting.</p>
    <div className="usage-report-actions"><button type="button" className="button ghost compact" disabled={loading || exporting} onClick={retryApplied}>Refresh applied window</button><button type="button" className="button secondary compact" disabled={!report || denied || loading || exporting} onClick={() => void exportCsv()}>{exporting ? "Exporting usage…" : "Export applied usage CSV"}</button></div>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    {loading && <p role="status">Loading retained usage…</p>}
    {report && !denied && <>
      <p className="usage-applied-window">Applied window: {report.range.from} through {report.range.through} UTC · Report observed {formatDateTime(report.observed_at)}.</p>
      <p className="support-note">Current totals include all retained records at each source observation. The selected window filters daily creation/start cohorts; duration overlaps each day even when a call started earlier.</p>
      <div className="usage-source-grid">{(Object.keys(sources) as UsageSourceKey[]).map((key) => <UsageSourceCard key={key} source={report.sources[key] as UsageSource} definition={sources[key]} />)}</div>
    </>}
  </section>;
}

function metricValue(value: number | undefined) { return value !== undefined && Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString() : "Not reported"; }
function UsageSourceCard({ source, definition }: { source: UsageSource; definition: SourceDefinition }) {
  return <section className="usage-source" aria-label={`${definition.title} usage`}><div className="card-heading"><h3>{definition.title}</h3><span className="status-pill neutral">{source.status === "unavailable" || !source.data ? "Unavailable" : "Observed"}</span></div>
    {source.status === "unavailable" || !source.data ? <p role="note">Source unavailable. Current totals and daily metrics are unknown.</p> : <>
      <h4>Current retained totals</h4><dl className="usage-current-metrics">{Object.entries(definition.current).map(([key, label]) => <div key={key}><dt>{label}</dt><dd>{metricValue(source.data?.current[key])}</dd></div>)}</dl>
      <p className="support-note">{definition.explanation}</p><details className="usage-daily"><summary>Source observation and coverage</summary><p>Source observed {formatDateTime(source.data.observed_at)} · {source.data.earliest_retained_at ? `Earliest retained timestamp ${formatDateTime(source.data.earliest_retained_at)}` : "No retained timestamp reported"}.</p></details><UsageDaily data={source.data} definition={definition} />
    </>}
  </section>;
}
function UsageDaily({ data, definition }: { data: UsageProjection; definition: SourceDefinition }) {
  const [metric, setMetric] = useState(Object.keys(definition.daily)[0] || "");
  return <details className="usage-daily"><summary>Daily retained records for {definition.title.toLocaleLowerCase()}</summary>
    <label className="field">Daily {definition.title.toLocaleLowerCase()} metric<select value={metric} onChange={(event) => setMetric(event.target.value)}>{Object.entries(definition.daily).map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select></label>
    <div className="usage-daily-table" role="region" aria-label={`${definition.title} daily retained metrics`} tabIndex={0}><table><caption>{definition.daily[metric]} · UTC day</caption><thead><tr><th scope="col">UTC date</th><th scope="col">Value</th></tr></thead><tbody>{data.daily.map((day) => <tr key={day.date}><th scope="row">{day.date}</th><td>{metricValue(day.metrics[metric])}</td></tr>)}</tbody></table></div>
    {data.daily.length === 0 && <p>No daily rows were reported.</p>}
  </details>;
}
