import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useModalDialog } from "../../components/useModalDialog";
import type { ModerationCaseDetail } from "../../types/administration";
import type { ApiClient } from "../../api";
import type { AttachmentSafety, ModerationCase } from "../../types";
import { errorText, formatBytes, formatDateTime } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import "./EvidencePanels.css";

export function SafetyPanel({ api, canManageAttachments }: { api: ApiClient; canManageAttachments: boolean }) {
  const [cases, setCases] = useState<ModerationCase[]>([]);
  const [attachments, setAttachments] = useState<AttachmentSafety[]>([]);
  const [caseStatus, setCaseStatus] = useState<ModerationCase["status"] | "">("");
  const [casePriority, setCasePriority] = useState<ModerationCase["priority"] | "">("");
  const [casesLoading, setCasesLoading] = useState(false);
  const [caseQuery, setCaseQuery] = useState("");
  const [scanFilter, setScanFilter] = useState<NonNullable<AttachmentSafety["scan_status"]> | "">("");
  const [scansLoading, setScansLoading] = useState(false);
  const [selectedCaseId, setSelectedCaseId] = useState<string | null>(null);
  const [detail, setDetail] = useState<ModerationCaseDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const detailGeneration = useRef(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<{ value: ModerationCase; actionType: string } | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    setCasesLoading(true);
    setCases([]);
    void runWithStepUp(() => api.moderationCases({ ...(caseStatus ? { status: caseStatus } : {}), ...(casePriority ? { priority: casePriority } : {}), limit: 100 }))
      .then((nextCases) => { if (current) setCases(nextCases); })
      .catch((reason: unknown) => { if (current && !stepUpWasCancelled(reason)) setError(errorText(reason)); })
      .finally(() => { if (current) setCasesLoading(false); });
    return () => { current = false; };
  }, [api, caseStatus, casePriority, runWithStepUp]);

  useEffect(() => {
    let current = true;
    if (canManageAttachments) {
      setScansLoading(true);
      setAttachments([]);
      void runWithStepUp(() => api.attachmentSafety({ ...(scanFilter ? { scan_status: scanFilter } : {}), limit: 100 }))
        .then((nextAttachments) => { if (current) setAttachments(nextAttachments); })
        .catch((reason: unknown) => { if (current && !stepUpWasCancelled(reason)) setError(errorText(reason)); })
        .finally(() => { if (current) setScansLoading(false); });
    }
    return () => { current = false; detailGeneration.current += 1; };
  }, [api, canManageAttachments, scanFilter, runWithStepUp]);

  async function openCase(id: string) {
    const generation = ++detailGeneration.current;
    setSelectedCaseId(id);
    setDetail(null);
    setDetailError(null);
    setDetailLoading(true);
    try {
      const result = await runWithStepUp(() => api.moderationCase(id));
      if (generation === detailGeneration.current) setDetail(result);
    } catch (reason: unknown) { if (generation === detailGeneration.current && !stepUpWasCancelled(reason)) setDetailError(errorText(reason)); }
    finally { if (generation === detailGeneration.current) setDetailLoading(false); }
  }

  const visibleCases = cases.filter((value) => (!caseStatus || value.status === caseStatus) && (!casePriority || value.priority === casePriority) && `${value.summary} ${value.category} ${value.details || ""}`.toLocaleLowerCase().includes(caseQuery.trim().toLocaleLowerCase()));
  const visibleAttachments = attachments.filter((attachment) => !scanFilter || attachment.scan_status === scanFilter);

  async function confirmAction(note: string) {
    if (!pendingAction) return;
    const action = pendingAction;
    setBusy(`case-${action.value.id}`);
    setActionError(null);
    try {
      const updated = await runWithStepUp(() => api.addModerationAction(action.value.id, { action_type: action.actionType, note, version: action.value.version }));
      setCases((current) => current.map((item) => item.id === updated.id ? updated : item));
      setPendingAction(null);
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setActionError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function retryScan(attachment: AttachmentSafety) {
    setBusy(`scan-${attachment.id}`); try { const updated = await runWithStepUp(() => api.retryAttachmentScan(attachment.id)); setAttachments((current) => current.map((value) => value.id === updated.id ? updated : value)); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" aria-label="Dismiss safety error" onClick={() => setError(null)}><AppIcon name="x" /></button></div>}
    {selectedCaseId && <CaseDetailDialog detail={detail} loading={detailLoading} error={detailError} onRetry={() => void openCase(selectedCaseId)} onClose={() => { detailGeneration.current += 1; setSelectedCaseId(null); }} />}
    {pendingAction && <ActionDialog
      title={`${moderationActionLabel(pendingAction.actionType)} case?`}
      description={pendingAction.value.summary}
      impact={moderationActionImpact(pendingAction.actionType)}
      confirmLabel={moderationActionLabel(pendingAction.actionType)}
      tone={pendingAction.actionType === "dismiss" ? "danger" : "default"}
      auditReason={{ label: "Decision note", helpText: "Explain the evidence and reason for this audited moderation decision.", minimumLength: 3 }}
      busy={busy !== null}
      error={actionError}
      onCancel={() => { if (!busy) { setPendingAction(null); setActionError(null); } }}
      onConfirm={(note) => void confirmAction(note)}
    />}
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Reports and decisions</span><h2>Moderation cases</h2></div><span className="status-pill neutral">{visibleCases.length} cases shown</span></div><div className="evidence-filter-grid"><label className="field">Search loaded cases<input type="search" value={caseQuery} onChange={(event) => setCaseQuery(event.target.value)} /></label><label className="field">Case status<select value={caseStatus} onChange={(event) => setCaseStatus(event.target.value as typeof caseStatus)}><option value="">All statuses</option>{["open", "in_review", "resolved", "dismissed"].map((status) => <option key={status} value={status}>{status.replaceAll("_", " ")}</option>)}</select></label><label className="field">Priority<select value={casePriority} onChange={(event) => setCasePriority(event.target.value as typeof casePriority)}><option value="">All priorities</option>{["low", "normal", "high", "urgent"].map((priority) => <option key={priority} value={priority}>{priority}</option>)}</select></label></div><p className="support-note">Status and priority filter the server inventory. Up to 100 cases are loaded per filter; text search applies to these loaded cases.</p>{casesLoading ? <p role="status">Loading moderation cases…</p> : visibleCases.length === 0 ? <p className="empty-copy">No moderation cases match these filters.</p> : <ul className="case-list">{visibleCases.map((value) => <li key={value.id}><div className="case-summary"><span className={`priority priority-${value.priority}`}>{value.priority}</span><div><strong>{value.summary}</strong><small>{value.category} · Reported {formatDateTime(value.inserted_at)}</small><p>{value.details}</p></div><span className={`status-pill ${["open", "in_review"].includes(value.status) ? "success" : "neutral"}`}>{value.status}</span></div><div className="case-actions"><button className="button ghost compact" type="button" onClick={() => void openCase(value.id)}>Case details</button>{value.status === "open" && <button className="button ghost compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "start_review" }); }}>Start review</button>}{["open", "in_review"].includes(value.status) && <><button className="button primary compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "resolve" }); }}>Resolve</button><button className="button danger compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "dismiss" }); }}>Dismiss</button></>}</div></li>)}</ul>}</section>
    {canManageAttachments && <section className="data-card"><div className="card-heading"><div><span className="eyebrow">File controls</span><h2>Attachment safety</h2></div><span className="status-pill neutral">Scan inventory</span></div><label className="field">Scan status<select value={scanFilter} onChange={(event) => setScanFilter(event.target.value as typeof scanFilter)}><option value="">All scan statuses</option>{["pending", "scanning", "clean", "blocked", "failed"].map((status) => <option key={status} value={status}>{status.replaceAll("_", " ")}</option>)}</select></label><p className="support-note">Scan status filters the server inventory. Up to 100 scan records are loaded per filter.</p>{scansLoading ? <p role="status">Loading attachment safety…</p> : visibleAttachments.length === 0 ? <p className="empty-copy">No attachment scan records match this filter.</p> : <ul className="security-list">{visibleAttachments.map((attachment) => <li key={attachment.id}><div><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachment.scan_provider || "scanner pending"} · {attachment.scan_attempts || 0} attempts · {formatDateTime(attachment.scanned_at)}</small></div><span className={`status-pill ${attachment.status === "ready" ? "success" : "neutral"}`}>{attachment.status} / {attachment.scan_status}</span><details className="admin-evidence-detail"><summary>Scan details</summary><p>{attachment.scan_error_code || "No scan error reported"}</p><p>Attachment ID: {attachment.id}</p><p>Verdict: {attachment.scan_verdict || "No verdict recorded"} · Quarantined {formatDateTime(attachment.quarantined_at)}</p>{attachment.attempts?.map((attempt) => <div key={attempt.id}><p>Attempt {attempt.attempt_number} · {attempt.status} · {attempt.provider}{attempt.error_code ? ` · ${attempt.error_code}` : ""}</p><p>Started {formatDateTime(attempt.started_at)} · Completed {formatDateTime(attempt.completed_at)} · Verdict {attempt.verdict || "Pending"}</p>{attempt.provider_reference && <p>Provider reference: {attempt.provider_reference}</p>}</div>)}<p>Files stay unavailable until a clean verdict is bound to the uploaded object. Retry failed scanning after the provider has recovered.</p></details>{attachment.status === "scan_failed" && <button className="button ghost compact" type="button" disabled={busy === `scan-${attachment.id}`} onClick={() => void retryScan(attachment)}>Retry scan</button>}</li>)}</ul>}</section>}
  </>;
}

function moderationActionLabel(actionType: string): string {
  if (actionType === "start_review") return "Start review";
  if (actionType === "resolve") return "Resolve";
  if (actionType === "dismiss") return "Dismiss";
  return actionType.replaceAll("_", " ");
}

function moderationActionImpact(actionType: string): string {
  if (actionType === "start_review") return "The case will move into active review and remain open for a final decision.";
  if (actionType === "resolve") return "The case will be marked resolved with this decision note retained in its audit trail.";
  return "The case will be closed as dismissed with this decision note retained in its audit trail.";
}

function CaseDetailDialog({ detail, loading, error, onRetry, onClose }: { detail: ModerationCaseDetail | null; loading: boolean; error: string | null; onRetry: () => void; onClose: () => void }) {
  const dialogRef = useModalDialog(onClose);
  return createPortal(<div className="modal-backdrop"><section ref={dialogRef} className="modal-dialog admin-evidence-detail" role="dialog" aria-modal="true" aria-labelledby="moderation-case-detail-title">
    <div className="card-heading"><h2 id="moderation-case-detail-title">Moderation case details</h2><button className="button ghost compact" type="button" onClick={onClose}>Close case details</button></div>
    {loading && <p role="status">Loading case history…</p>}
    {error && <div role="alert">{error}<button className="button ghost compact" type="button" onClick={onRetry}>Retry case details</button></div>}
    {detail && <><h3>{detail.data.summary}</h3><p>{detail.data.details}</p><dl><dt>Case ID</dt><dd>{detail.data.id}</dd><dt>Reporter</dt><dd>{detail.data.reporter_user_id}</dd><dt>Subject</dt><dd>{detail.data.subject_user_id || "Not supplied"}</dd><dt>Category</dt><dd>{detail.data.category}</dd><dt>Priority</dt><dd>{detail.data.priority}</dd><dt>Status</dt><dd>{detail.data.status.replaceAll("_", " ")}</dd><dt>Assigned reviewer</dt><dd>{detail.data.assigned_to_user_id || "Unassigned"}</dd><dt>Conversation ID</dt><dd>{detail.data.conversation_id || "Not supplied"}</dd><dt>Message ID</dt><dd>{detail.data.message_id || "Not supplied"}</dd><dt>Reported</dt><dd>{formatDateTime(detail.data.inserted_at)}</dd><dt>Updated</dt><dd>{formatDateTime(detail.data.updated_at)}</dd>{detail.data.resolved_at && <><dt>Resolved</dt><dd>{formatDateTime(detail.data.resolved_at)}</dd></>}</dl>
      {detail.data.conversation_id && <a href={`/app/?conversation=${encodeURIComponent(detail.data.conversation_id)}${detail.data.message_id ? `&message=${encodeURIComponent(detail.data.message_id)}` : ""}`}>Open source conversation</a>}
      <h3>Decision history</h3>{detail.actions.length === 0 ? <p>No decisions recorded.</p> : <ol>{detail.actions.map((action) => <li key={action.id}><strong>{moderationActionLabel(action.action_type)}</strong><p>{action.note || "No note"}</p><small>{formatDateTime(action.inserted_at)} · Actor {action.actor_user_id}</small><details className="admin-evidence-detail"><summary>Action evidence</summary><p>Action ID: {action.id}</p><pre>{JSON.stringify(action.metadata || {}, null, 2)}</pre></details></li>)}</ol>}
    </>}
  </section></div>, document.body);
}
