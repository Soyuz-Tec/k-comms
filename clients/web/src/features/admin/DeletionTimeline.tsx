import { useCallback, useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { StepUpCancelledError, stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { formatDateTime } from "../../lib/format";
import type { DeletionHistoryEvent, DeletionHistoryPage, DeletionHistoryQuery } from "../../types/deletionHistory";
import "./DeletionTimeline.css";

const proofLabels = {
  derived_erasure_version: "Derived content erasure",
  media_erasure_version: "Media erasure",
  meeting_erasure_version: "Meeting erasure",
  writer_fence_erasure_version: "Write admission fence"
} as const;
const countLabels = {
  messages_tombstoned: "Messages tombstoned",
  attachments_deleted: "Attachments deleted",
  deleted_object_count: "Objects deleted"
} as const;
const errorLabels = { provider_failure: "Provider failure", verification_pending: "Verification pending", unavailable: "Processing detail unavailable" };
const actionLabels = {
  "deletion_request.create": "Requested", "deletion_request.approved": "Approved", "deletion_request.rejected": "Rejected",
  "deletion_request.cancelled": "Cancelled", "deletion_request.claim": "Processing started", "deletion_request.failure": "Processing attempt failed",
  "deletion_request.writer_fence_repair_queued": "Verification repair queued", "deletion_request.completed": "Completed",
  "deletion_request.derived_content_repaired": "Derived content repaired"
};

export function DeletionTimeline({ api, requestId }: { api: ApiClient; requestId: string }) {
  const { session } = useSession();
  const scope = `${requestId}:${session?.tenant.id || ""}:${session?.user.id || ""}:${session?.device?.id || ""}:${session?.user.role || ""}:${session?.access_token || ""}`;
  const identity = useRef({ scope, serial: 0 });
  if (identity.current.scope !== scope) identity.current = { scope, serial: identity.current.serial + 1 };
  return <DeletionTimelineContent key={identity.current.serial} api={api} requestId={requestId} />;
}

function DeletionTimelineContent({ api, requestId }: { api: ApiClient; requestId: string }) {
  const { runWithStepUp } = useStepUp();
  const [open, setOpen] = useState(false);
  const [page, setPage] = useState<DeletionHistoryPage | null>(null);
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [denied, setDenied] = useState(false);
  const [expired, setExpired] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const generation = useRef(0);
  const busy = useRef(false);
  const lastQuery = useRef<{ input: DeletionHistoryQuery; append: boolean }>({ input: { limit: 25 }, append: false });
  const pageRef = useRef(page);
  pageRef.current = page;

  const fail = useCallback((reason: unknown) => {
    if (stepUpWasCancelled(reason)) return;
    if (reason instanceof ApiError && ([401, 403, 404].includes(reason.status) || reason.code === "session_changed")) {
      setPage(null);
      pageRef.current = null;
      lastQuery.current = { input: { limit: 25 }, append: false };
      setNotice(null);
      setDenied(true);
      setExpired(false);
      setError("Deletion history is unavailable with your current access. Verify your account or ask an authorized workspace owner.");
    } else if (reason instanceof ApiError && reason.code === "invalid_history_cursor") {
      setExpired(true);
      setNotice(null);
      setError("This history snapshot has expired or is invalid. Capture current history to continue; it may contain different retained events.");
    } else {
      setError("Deletion history could not be retrieved or verified. Retry the same snapshot.");
    }
  }, []);

  const load = useCallback(async (input: DeletionHistoryQuery, append = false) => {
    if (busy.current) return;
    busy.current = true;
    const request = ++generation.current;
    lastQuery.current = { input, append };
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await runWithStepUp(() => {
        if (request !== generation.current) throw new StepUpCancelledError();
        return api.deletionHistory(requestId, input).catch((reason: unknown) => {
          if (request === generation.current && reason instanceof ApiError && [401, 403, 404].includes(reason.status)) fail(reason);
          throw reason;
        });
      });
      if (request !== generation.current) return;
      const current = pageRef.current;
      if (result.request.id !== requestId || (input.snapshot && input.snapshot !== result.snapshot) || (append && current && current.snapshot !== result.snapshot)) {
        throw new ApiError(502, "invalid_history_page", "The history page could not be verified.");
      }
      const next = append && current ? { ...result, events: [...new Map([...current.events, ...result.events].map((event) => [event.id, event])).values()] } : result;
      pageRef.current = next;
      setPage(next);
      setDenied(false);
      setExpired(false);
    } catch (reason: unknown) {
      if (request === generation.current) fail(reason);
    } finally {
      if (request === generation.current) { busy.current = false; setLoading(false); }
    }
  }, [api, fail, requestId, runWithStepUp]);

  useEffect(() => () => { generation.current += 1; }, []);
  useEffect(() => {
    if (!open) return;
    const revalidate = () => {
      const current = pageRef.current;
      if (document.visibilityState !== "hidden" && current && !busy.current && !expired && !denied) {
        void load({ snapshot: current.snapshot, limit: current.limit });
      }
    };
    window.addEventListener("focus", revalidate);
    document.addEventListener("visibilitychange", revalidate);
    return () => { window.removeEventListener("focus", revalidate); document.removeEventListener("visibilitychange", revalidate); };
  }, [denied, expired, load, open]);

  function captureCurrent() {
    if (busy.current) return;
    setPage(null);
    pageRef.current = null;
    setExpired(false);
    setDenied(false);
    void load({ limit: 25 });
  }

  async function exportCsv() {
    const current = pageRef.current;
    if (!current || busy.current || expired || denied) return;
    busy.current = true;
    const request = ++generation.current;
    setExporting(true);
    setError(null);
    setNotice(null);
    try {
      const file = await runWithStepUp(() => {
        if (request !== generation.current) throw new StepUpCancelledError();
        return api.exportDeletionHistory(requestId, current.snapshot, 5000).catch((reason: unknown) => {
          if (request === generation.current && reason instanceof ApiError && [401, 403, 404].includes(reason.status)) fail(reason);
          throw reason;
        });
      });
      if (request !== generation.current) return;
      if (file.history.snapshot !== current.snapshot || !file.history.retainedOnly || file.history.maximumRows !== 5000) {
        throw new ApiError(502, "invalid_history_export", "The history export receipt could not be verified.");
      }
      const url = URL.createObjectURL(file.blob);
      try {
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = file.filename;
        document.body.append(anchor);
        anchor.click();
        anchor.remove();
      } finally { URL.revokeObjectURL(url); }
      setNotice(`Downloaded ${file.count} retained history events from this snapshot. Coverage: ${file.history.coverage}.${file.truncated ? " The export or captured snapshot is truncated at its published limit." : ""} Receipt observed ${formatDateTime(file.history.observedAt)}. This is retained history, not proof of a complete lifetime record.`);
    } catch (reason: unknown) {
      if (request === generation.current) fail(reason);
    } finally {
      if (request === generation.current) { busy.current = false; setExporting(false); }
    }
  }

  return <details className="admin-evidence-detail evidence-panel-content deletion-history" open={open}
    onToggle={(event) => {
      const expanded = event.currentTarget.open;
      setOpen(expanded);
      if (expanded && !denied && !expired && !busy.current) void load(page ? { snapshot: page.snapshot, limit: page.limit } : { limit: 25 });
    }}>
    <summary>Request details and history</summary>
    {open && <section aria-label="Deletion request history">
      <h3>Retained deletion history</h3>
      <p>Pages and CSV use the same fixed snapshot for up to one hour. New or backdated events require a deliberate new capture. Audit retention can remove captured events.</p>
      <div className="deletion-history-actions">
        <button type="button" className="button ghost compact" disabled={loading || exporting} onClick={captureCurrent}>Capture current history</button>
        <button type="button" className="button secondary compact" disabled={!page || loading || exporting || denied || expired} onClick={() => void exportCsv()}>{exporting ? "Exporting history…" : "Export this history CSV"}</button>
      </div>
      {error && <div role="alert"><p>{error}</p>{!expired && <button type="button" disabled={loading || exporting} onClick={() => void load(lastQuery.current.input, lastQuery.current.append)}>Retry history access</button>}</div>}
      {notice && <p role="status">{notice}</p>}
      {(loading || exporting) && <p role="status">{exporting ? "Retrieving history CSV…" : "Loading retained history…"}</p>}
      {page && !denied && <>
        <div className="deletion-history-coverage" role="note">
          <p>Coverage: {page.coverage.state}. Only currently retained events are included; this does not establish a complete lifetime history.</p>
          <p>Version lineage is unproven. Retained events do not establish every historical request version.</p>
          <p>{page.coverage.captured_count} events captured · {page.coverage.retained_count} captured events still retained · {page.events.length} events loaded.</p>
          {!page.coverage.origin_present && <p>The original request event is absent from this retained snapshot.</p>}
          {page.coverage.snapshot_truncated && <p>The captured snapshot is truncated at {page.coverage.maximum_events} events. Events outside the captured set are not included.</p>}
          <p>Snapshot captured {formatDateTime(page.snapshot_observed_at)} · Page observed {formatDateTime(page.observed_at)}{page.coverage.earliest_at ? ` · Earliest retained event ${formatDateTime(page.coverage.earliest_at)}` : ""}.</p>
        </div>
        <dl className="deletion-history-current"><dt>Current request status</dt><dd>{page.request.status.replaceAll("_", " ")}</dd><dt>Current request version</dt><dd>{page.request.version}</dd><dt>Execution attempts</dt><dd>{page.request.execution_attempts ?? 0}</dd></dl>
        <p>The current request can advance after snapshot capture. Recorded events below retain their captured ordering.</p>
        {page.request.execution_error && <p role="note">{errorLabels[page.request.execution_error as keyof typeof errorLabels] || errorLabels.unavailable}</p>}
        <SafeFacts values={page.request.evidence || {}} labels={countLabels} />
        <SafeFacts values={page.request.evidence || {}} labels={proofLabels} />
        <ol className="deletion-history-events" aria-label="Chronological deletion events">{page.events.map((event) => <HistoryEvent key={event.id} event={event} />)}</ol>
        {page.events.length === 0 && <p>No retained history events are available in this snapshot. Absence does not prove that an action never occurred.</p>}
        {page.next_cursor && !expired && <button type="button" className="button ghost compact" disabled={loading || exporting} onClick={() => void load({ cursor: page.next_cursor! }, true)}>Load more history events</button>}
      </>}
    </section>}
  </details>;
}

function SafeFacts({ values, labels }: { values: Record<string, unknown>; labels: Record<string, string> }) {
  const facts = Object.entries(labels).filter(([key]) => Number.isSafeInteger(values[key]) && Number(values[key]) >= 0);
  return facts.length ? <dl className="deletion-history-facts">{facts.map(([key, label]) => <div key={key}><dt>{label}</dt><dd>{String(values[key])}</dd></div>)}</dl> : null;
}

function HistoryEvent({ event }: { event: DeletionHistoryEvent }) {
  const actor = event.actor.kind === "system" ? "System" : event.actor.kind === "unavailable" ? "Actor unavailable" : event.actor.display_name || "Actor name unavailable";
  return <li><header><time dateTime={event.inserted_at}>{formatDateTime(event.inserted_at)}</time><strong>{actionLabels[event.action] || "Recorded governance event"}</strong></header>
    <p>Actor: {actor}{event.status ? ` · Status: ${event.status.replaceAll("_", " ")}` : ""}{event.version !== null ? ` · Version ${event.version}` : ""}{event.attempt !== null ? ` · Attempt ${event.attempt}` : ""}.</p>
    {event.error_code && <p>{errorLabels[event.error_code]}</p>}
    <SafeFacts values={event.counts} labels={countLabels} /><SafeFacts values={event.proof_versions} labels={proofLabels} />
  </li>;
}
