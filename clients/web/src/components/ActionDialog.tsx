import { useId, useRef, useState } from "react";
import type { FormEvent } from "react";
import { createPortal } from "react-dom";
import { useModalDialog } from "./useModalDialog";

export interface AuditReasonOptions {
  label?: string;
  helpText?: string;
  placeholder?: string;
  minimumLength?: number;
}

export interface ActionDialogProps {
  title: string;
  description: string;
  impact?: string;
  confirmLabel: string;
  cancelLabel?: string;
  tone?: "default" | "danger";
  auditReason?: AuditReasonOptions;
  busy?: boolean;
  error?: string | null;
  onCancel: () => void;
  onConfirm: (auditReason: string) => void;
}

export function ActionDialog({
  title,
  description,
  impact,
  confirmLabel,
  cancelLabel = "Cancel",
  tone = "default",
  auditReason,
  busy = false,
  error,
  onCancel,
  onConfirm
}: ActionDialogProps) {
  const titleId = useId();
  const descriptionId = useId();
  const impactId = useId();
  const reasonId = useId();
  const helpId = useId();
  const validationId = useId();
  const reasonRef = useRef<HTMLTextAreaElement | null>(null);
  const [reason, setReason] = useState("");
  const [validationError, setValidationError] = useState<string | null>(null);
  const dialogRef = useModalDialog(() => {
    if (!busy) onCancel();
  });
  const minimumLength = auditReason?.minimumLength ?? 3;
  const describedBy = [descriptionId, impact ? impactId : null].filter(Boolean).join(" ");

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmedReason = reason.trim();
    if (auditReason && trimmedReason.length < minimumLength) {
      setValidationError(`Enter a reason of at least ${minimumLength} characters.`);
      reasonRef.current?.focus();
      return;
    }
    setValidationError(null);
    onConfirm(trimmedReason);
  }

  return createPortal(
    <div className="modal-backdrop" data-action-dialog-backdrop>
      <section
        ref={dialogRef}
        className={`modal-dialog action-dialog action-dialog-${tone}`}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={describedBy}
        tabIndex={-1}
      >
        <h2 id={titleId}>{title}</h2>
        <p id={descriptionId}>{description}</p>
        {impact && (
          <div className="action-dialog-impact" id={impactId} role="note">
            <strong>What will happen</strong>
            <span>{impact}</span>
          </div>
        )}
        {error && <div className="form-error" role="alert">{error}</div>}
        <form onSubmit={submit} noValidate>
          {auditReason && (
            <div className="field">
              <label htmlFor={reasonId}>{auditReason.label ?? "Reason for this change"}</label>
              <textarea
                ref={reasonRef}
                id={reasonId}
                name="audit_reason"
                value={reason}
                placeholder={auditReason.placeholder}
                required
                minLength={minimumLength}
                aria-describedby={[auditReason.helpText ? helpId : null, validationError ? validationId : null].filter(Boolean).join(" ") || undefined}
                aria-invalid={validationError ? "true" : undefined}
                onChange={(event) => {
                  setReason(event.target.value);
                  if (validationError) setValidationError(null);
                }}
              />
              {auditReason.helpText && <small id={helpId}>{auditReason.helpText}</small>}
              {validationError && <small className="field-error" id={validationId} role="alert">{validationError}</small>}
            </div>
          )}
          <div className="form-actions">
            <button className="button ghost" type="button" data-initial-focus disabled={busy} onClick={onCancel}>{cancelLabel}</button>
            <button className={`button ${tone === "danger" ? "danger" : "primary"}`} type="submit" disabled={busy}>{busy ? "Working…" : confirmLabel}</button>
          </div>
        </form>
      </section>
    </div>,
    document.body
  );
}

export type ConfirmDialogProps = Omit<ActionDialogProps, "auditReason" | "onConfirm"> & {
  onConfirm: () => void;
};

export function ConfirmDialog({ onConfirm, ...props }: ConfirmDialogProps) {
  return <ActionDialog {...props} onConfirm={onConfirm} />;
}
