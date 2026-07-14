import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import type { AttachmentSafety, ModerationCase } from "../../types";
import { errorText, formatBytes, formatDateTime } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";

export function SafetyPanel({ api, canManageAttachments }: { api: ApiClient; canManageAttachments: boolean }) {
  const [cases, setCases] = useState<ModerationCase[]>([]);
  const [attachments, setAttachments] = useState<AttachmentSafety[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<{ value: ModerationCase; actionType: string } | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    api.moderationCases().then((nextCases) => current && setCases(nextCases)).catch((reason: unknown) => current && setError(errorText(reason)));
    if (canManageAttachments) {
      api.attachmentSafety().then((nextAttachments) => current && setAttachments(nextAttachments)).catch((reason: unknown) => current && setError(errorText(reason)));
    }
    return () => { current = false; };
  }, [api, canManageAttachments]);

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
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}
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
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Reports and decisions</span><h2>Moderation cases</h2></div><span className="status-pill success">Live API</span></div>{cases.length === 0 ? <p className="empty-copy">No moderation cases.</p> : <ul className="case-list">{cases.map((value) => <li key={value.id}><div className="case-summary"><span className={`priority priority-${value.priority}`}>{value.priority}</span><div><strong>{value.summary}</strong><small>{value.category} · Reported {formatDateTime(value.inserted_at)}</small><p>{value.details}</p></div><span className={`status-pill ${["open", "in_review"].includes(value.status) ? "success" : "neutral"}`}>{value.status}</span></div><div className="case-actions">{value.status === "open" && <button className="button ghost compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "start_review" }); }}>Start review</button>}{["open", "in_review"].includes(value.status) && <><button className="button primary compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "resolve" }); }}>Resolve</button><button className="button danger compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => { setActionError(null); setPendingAction({ value, actionType: "dismiss" }); }}>Dismiss</button></>}</div></li>)}</ul>}</section>
    {canManageAttachments && <section className="data-card"><div className="card-heading"><div><span className="eyebrow">File controls</span><h2>Attachment safety</h2></div><span className="status-pill success">Live API</span></div>{attachments.length === 0 ? <p className="empty-copy">No attachment scan records.</p> : <ul className="security-list">{attachments.map((attachment) => <li key={attachment.id}><div><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachment.scan_provider || "scanner pending"} · {attachment.scan_attempts || 0} attempts · {formatDateTime(attachment.scanned_at)}</small></div><span className={`status-pill ${attachment.status === "ready" ? "success" : "neutral"}`}>{attachment.status} / {attachment.scan_status}</span>{attachment.status === "scan_failed" && <button className="button ghost compact" type="button" disabled={busy === `scan-${attachment.id}`} onClick={() => void retryScan(attachment)}>Retry scan</button>}</li>)}</ul>}</section>}
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
