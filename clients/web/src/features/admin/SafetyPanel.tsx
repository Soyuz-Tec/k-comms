import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import type { AttachmentSafety, ModerationCase } from "../../types";
import { errorText, formatBytes, formatDateTime } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";

export function SafetyPanel({ api, canManageAttachments }: { api: ApiClient; canManageAttachments: boolean }) {
  const [cases, setCases] = useState<ModerationCase[]>([]);
  const [attachments, setAttachments] = useState<AttachmentSafety[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();

  useEffect(() => {
    let current = true;
    api.moderationCases().then((nextCases) => current && setCases(nextCases)).catch((reason: unknown) => current && setError(errorText(reason)));
    if (canManageAttachments) {
      api.attachmentSafety().then((nextAttachments) => current && setAttachments(nextAttachments)).catch((reason: unknown) => current && setError(errorText(reason)));
    }
    return () => { current = false; };
  }, [api, canManageAttachments]);

  async function act(value: ModerationCase, actionType: string) {
    const note = window.prompt(`Reason or note for ${actionType.replace("_", " ")}`); if (!note?.trim()) return;
    setBusy(`case-${value.id}`); try { const updated = await runWithStepUp(() => api.addModerationAction(value.id, { action_type: actionType, note: note.trim(), version: value.version })); setCases((current) => current.map((item) => item.id === updated.id ? updated : item)); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  async function retryScan(attachment: AttachmentSafety) {
    setBusy(`scan-${attachment.id}`); try { const updated = await runWithStepUp(() => api.retryAttachmentScan(attachment.id)); setAttachments((current) => current.map((value) => value.id === updated.id ? updated : value)); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Reports and decisions</span><h2>Moderation cases</h2></div><span className="status-pill success">Live API</span></div>{cases.length === 0 ? <p className="empty-copy">No moderation cases.</p> : <ul className="case-list">{cases.map((value) => <li key={value.id}><div className="case-summary"><span className={`priority priority-${value.priority}`}>{value.priority}</span><div><strong>{value.summary}</strong><small>{value.category} · Reported {formatDateTime(value.inserted_at)}</small><p>{value.details}</p></div><span className={`status-pill ${["open", "in_review"].includes(value.status) ? "success" : "neutral"}`}>{value.status}</span></div><div className="case-actions">{value.status === "open" && <button className="button ghost compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => void act(value, "start_review")}>Start review</button>}{["open", "in_review"].includes(value.status) && <><button className="button primary compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => void act(value, "resolve")}>Resolve</button><button className="button danger compact" type="button" disabled={busy === `case-${value.id}`} onClick={() => void act(value, "dismiss")}>Dismiss</button></>}</div></li>)}</ul>}</section>
    {canManageAttachments && <section className="data-card"><div className="card-heading"><div><span className="eyebrow">File controls</span><h2>Attachment safety</h2></div><span className="status-pill success">Live API</span></div>{attachments.length === 0 ? <p className="empty-copy">No attachment scan records.</p> : <ul className="security-list">{attachments.map((attachment) => <li key={attachment.id}><div><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachment.scan_provider || "scanner pending"} · {attachment.scan_attempts || 0} attempts · {formatDateTime(attachment.scanned_at)}</small></div><span className={`status-pill ${attachment.status === "ready" ? "success" : "neutral"}`}>{attachment.status} / {attachment.scan_status}</span>{attachment.status === "scan_failed" && <button className="button ghost compact" type="button" disabled={busy === `scan-${attachment.id}`} onClick={() => void retryScan(attachment)}>Retry scan</button>}</li>)}</ul>}</section>}
  </>;
}
