import type { Attachment } from "../../types";
import { AppIcon } from "../../components/AppIcon";

export type AttachmentUploadPhase =
  | "hashing"
  | "requesting"
  | "uploading"
  | "finalizing"
  | "scanning"
  | "cancelling"
  | "ready"
  | "retryable_error"
  | "blocked"
  | "scan_delayed";

export interface PendingAttachmentUpload {
  clientId: string;
  file: File;
  localName: string;
  attachment?: Attachment;
  phase: AttachmentUploadPhase;
  error?: string;
  cancelRequested?: boolean;
  /**
   * Transferred fraction, 0-1, present only while the bytes are in flight and
   * the browser can report a total. Absent means indeterminate rather than
   * zero, so phases without measurable work keep an unfilled bar.
   */
  progress?: number;
}

export function AttachmentUploadList({
  items,
  onCancel,
  onRetry
}: {
  items: PendingAttachmentUpload[];
  onCancel: (clientId: string) => void;
  onRetry: (clientId: string) => void;
}) {
  return (
    <div className="attachment-queue" aria-label="Files being attached" aria-live="polite">
      {items.map((item) => {
        const busy = attachmentUploadBusy(item);
        const retryable = item.phase === "retryable_error";
        const label = attachmentUploadLabel(item);
        return (
          <article className={`attachment-queue-item phase-${item.phase}`} key={item.clientId}>
            <span className="attachment-queue-mark" aria-hidden="true">
              <AppIcon
                className={item.phase === "ready" ? "" : ["blocked", "retryable_error", "scan_delayed"].includes(item.phase) ? "" : "spin"}
                name={item.phase === "ready" ? "check" : ["blocked", "retryable_error", "scan_delayed"].includes(item.phase) ? "triangleAlert" : "loader"}
              />
            </span>
            <span className="attachment-queue-copy">
              <strong>{item.localName}</strong>
              <small>{label}</small>
              {busy && (
                <progress
                  max={100}
                  {...(determinateProgress(item) === undefined
                    ? {}
                    : { value: determinateProgress(item) })}
                  aria-label={`${item.localName}: ${label}`}
                />
              )}
              {item.phase === "ready" && <progress max={100} value={100} aria-label={`${item.localName}: ready`} />}
            </span>
            <span className="attachment-queue-actions">
              {retryable && (
                <button className="button ghost compact" type="button" onClick={() => onRetry(item.clientId)}>
                  Retry
                </button>
              )}
              <button
                className="attachment-queue-remove"
                type="button"
                aria-label={`${busy ? "Cancel attaching" : "Remove"} ${item.localName}`}
                onClick={() => onCancel(item.clientId)}
              >
                <AppIcon name="x" />
              </button>
            </span>
          </article>
        );
      })}
    </div>
  );
}

export function attachmentUploadBusy(item: PendingAttachmentUpload): boolean {
  return ["hashing", "requesting", "uploading", "finalizing", "scanning", "cancelling"].includes(item.phase);
}

export function attachmentUploadReady(item: PendingAttachmentUpload): boolean {
  return item.phase === "ready" && item.attachment?.status === "ready";
}

/**
 * Omitting `value` leaves the element indeterminate, which is the honest
 * rendering for phases whose duration cannot be measured.
 */
function determinateProgress(item: PendingAttachmentUpload): number | undefined {
  if (item.phase !== "uploading" || item.progress === undefined) return undefined;
  if (!Number.isFinite(item.progress)) return undefined;
  return Math.round(Math.min(1, Math.max(0, item.progress)) * 100);
}

function attachmentUploadLabel(item: PendingAttachmentUpload): string {
  if (item.phase === "hashing") return "Preparing securely";
  if (item.phase === "requesting") return "Creating secure upload";
  if (item.phase === "uploading") {
    const percent = determinateProgress(item);
    return percent === undefined ? "Uploading" : `Uploading · ${percent}%`;
  }
  if (item.phase === "finalizing") return "Finalizing upload";
  if (item.phase === "scanning") return "Safety scan in progress";
  if (item.phase === "cancelling") return "Removing secure upload";
  if (item.phase === "ready") return "Ready to send · Safety scan passed";
  if (item.phase === "blocked") return item.error || "Blocked by the safety scan";
  if (item.phase === "scan_delayed") return item.error || "Safety scan is taking longer than expected";
  return item.error || "Upload failed";
}
