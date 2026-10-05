import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import { createPortal } from "react-dom";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import type { User, UserRole } from "../../types";
import type { RoleCapability, RoleCapabilityCondition, RoleCapabilityFact, UserRoleChangePreview } from "../../types/rolePermissions";
import { StepUpCancelledError, stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { useSession } from "../../app/session";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText } from "../../lib/format";
import { roleLabel } from "../../lib/roles";
import "./RoleChangeDialog.css";

const capabilityLabels: Record<RoleCapability, string> = {
  administer_users: "View and administer people",
  manage_user_lifecycle: "Change account roles and status",
  manage_sessions: "Manage people's sign-in sessions",
  manage_tenant_settings: "Manage workspace settings",
  manage_invitations: "Manage workspace invitations",
  audit_tenant: "Read workspace audit records",
  govern_tenant: "Manage retention, legal holds and erasure"
};

const conditionLabels: Record<RoleCapabilityCondition, string> = {
  active_tenant: "Active workspace",
  active_identity: "Active account",
  current_session: "Current sign-in session",
  workspace_access: "Full workspace access",
  recent_step_up: "Recent privileged verification"
};

interface RoleChangeDialogProps {
  api: Pick<ApiClient, "previewAdminUserRole">;
  user: User;
  identifier: string;
  requestedRole: UserRole;
  busy: boolean;
  error: string | null;
  onCancel: () => void;
  onReviewAgain: () => void;
  onConfirm: (reason: string) => void;
}

export function RoleChangeDialog({ api, user, identifier, requestedRole, busy, error, onCancel, onReviewAgain, onConfirm }: RoleChangeDialogProps) {
  const { runWithStepUp } = useStepUp();
  const { session } = useSession();
  // Keep the request bound to the current actor in memory. A new credential or
  // role must be reviewed again even when the selected target has not changed.
  const actorBinding = useMemo(() => ({
    tenantId: session?.tenant.id,
    userId: session?.user?.id,
    role: session?.user?.role,
    status: session?.user?.status,
    version: session?.user?.version,
    deviceId: session?.device?.id,
    credential: session?.access_token
  }), [session?.tenant.id, session?.user?.id, session?.user?.role, session?.user?.status, session?.user?.version, session?.device?.id, session?.access_token]);
  const [review, setReview] = useState<{ preview: UserRoleChangePreview; actorBinding: object } | null>(null);
  const preview = review?.actorBinding === actorBinding && !error ? review.preview : null;
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [retryAllowed, setRetryAllowed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [reason, setReason] = useState("");
  const [reasonError, setReasonError] = useState<string | null>(null);
  const titleId = useId();
  const descriptionId = useId();
  const reasonId = useId();
  const reasonHelpId = useId();
  const reasonErrorId = useId();
  const reasonRef = useRef<HTMLTextAreaElement>(null);
  const dialogRef = useModalDialog(() => { if (!busy) onCancel(); });

  useEffect(() => {
    let current = true;
    setReview(null);
    setPreviewError(null);
    setLoading(true);
    setRetryAllowed(false);
    if (!user.version) {
      setPreviewError("Reload the people list before reviewing this account's role.");
      setLoading(false);
      return () => { current = false; };
    }
    runWithStepUp(async () => {
      if (!current) throw new StepUpCancelledError();
      try {
        const value = await api.previewAdminUserRole(user.id, { role: requestedRole, version: user.version! });
        if (!current) throw new StepUpCancelledError();
        return value;
      } catch (failure: unknown) {
        // StrictMode's obsolete request can finish after the active request's
        // 428. It must neither replace the proof gate nor retry the old review.
        if (!current) throw new StepUpCancelledError();
        throw failure;
      }
    })
      .then((value) => {
        if (!current) return;
        if (!matchesChange(value, user, requestedRole)) {
          setPreviewError("This permission preview no longer matches the selected account. Reload the people list and review again.");
          return;
        }
        setReview({ preview: value, actorBinding });
      })
      .catch((failure: unknown) => {
        if (!current) return;
        const stale = failure instanceof ApiError && ["stale_version", "version_required", "not_found", "forbidden", "unauthenticated"].includes(failure.code);
        setRetryAllowed(!stale);
        setPreviewError(stepUpWasCancelled(failure)
          ? "Privileged verification was cancelled. Review permissions again to continue."
          : stale
            ? `${errorText(failure)} Cancel this review and reload the people list before trying again.`
            : errorText(failure));
      })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [api, user, requestedRole, attempt, runWithStepUp, actorBinding]);

  useEffect(() => { if (error) setReview(null); }, [error]);

  const blocked = Boolean(preview && (!preview.role_policy_allows || preview.blockers.length));
  const canConfirm = Boolean(preview && !blocked && !loading && !previewError && !error && matchesChange(preview, user, requestedRole));

  function reviewAgain() {
    setReview(null);
    setPreviewError(null);
    setLoading(true);
    setRetryAllowed(false);
    onReviewAgain();
    setAttempt((value) => value + 1);
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || !canConfirm) return;
    const trimmed = reason.trim();
    if (trimmed.length < 3) {
      setReasonError("Enter a reason of at least 3 characters.");
      reasonRef.current?.focus();
      return;
    }
    setReasonError(null);
    onConfirm(trimmed);
  }

  return createPortal(<div className="modal-backdrop" data-action-dialog-backdrop>
    <section ref={dialogRef} className="modal-dialog action-dialog role-change-dialog" role="alertdialog" aria-modal="true" aria-labelledby={titleId} aria-describedby={descriptionId} tabIndex={-1}>
      <header className="app-dialog-heading"><h2 id={titleId}>Review this role change</h2><AppSurfaceControlButton accessibleLabel="Close role change review" disabled={busy} kind="close" onClick={onCancel} /></header>
      <p id={descriptionId}>Change {identifier}'s role from {roleLabel(user.role)} to {roleLabel(requestedRole)} ({user.email}).</p>
      {loading && <p role="status">Loading current permissions…</p>}
      {previewError && <div className="form-error" role="alert">{previewError}{retryAllowed && <button className="button ghost compact" type="button" disabled={busy} onClick={reviewAgain}>Review permissions again</button>}</div>}
      {preview && <div className="role-change-preview" aria-label="Role permission impact">
        {preview.target_access_scope === "conversation_only" && <p className="inline-notice">This account has conversation-only access. Changing its role does not enroll it in the workspace.</p>}
        {preview.target_status === "suspended" && <p className="inline-notice">This account is suspended. Permissions require an active account before they can be used.</p>}
        {!preview.role_policy_allows && <p className="form-error" role="alert">This role change is not permitted for this account and your current role.</p>}
        {preview.blockers.includes("last_owner_required") && <p className="form-error" role="alert">An active owner must remain in the workspace. Choose another owner before making this change.</p>}
        <CapabilityChanges title="Permissions added" facts={preview.added} empty="No workspace permissions are added." />
        <CapabilityChanges title="Permissions removed" facts={preview.removed} empty="No workspace permissions are removed." />
        <p className="role-change-advisory" role="note">This is a preview. Current authority, account version, ownership and governance checks run again when you confirm.</p>
      </div>}
      {error && <div className="form-error" role="alert">{error} Review current permissions before confirming again.<button className="button ghost compact" type="button" disabled={busy} onClick={reviewAgain}>Review permissions again</button></div>}
      <form onSubmit={submit} noValidate>
        <div className="field"><label htmlFor={reasonId}>Audit reason</label><textarea ref={reasonRef} id={reasonId} name="audit_reason" value={reason} required minLength={3} disabled={busy} aria-describedby={[reasonHelpId, reasonError ? reasonErrorId : null].filter(Boolean).join(" ")} aria-invalid={reasonError ? "true" : undefined} onChange={(event) => { setReason(event.target.value); setReasonError(null); }} /><small id={reasonHelpId}>Required for the audit log.</small>{reasonError && <small className="field-error" id={reasonErrorId} role="alert">{reasonError}</small>}</div>
        <div className="form-actions"><button className="button ghost" type="button" data-initial-focus disabled={busy} onClick={onCancel}>Cancel</button><button className="button primary" type="submit" disabled={busy || !canConfirm}>{busy ? "Working…" : "Confirm change"}</button></div>
      </form>
    </section>
  </div>, document.body);
}

function matchesChange(preview: UserRoleChangePreview, user: User, requestedRole: UserRole) {
  return preview.target_id === user.id && preview.current_role === user.role && preview.requested_role === requestedRole && preview.current_version === user.version && preview.advisory === true && preview.scope === "tenant" && preview.governance_review_required === true;
}

function CapabilityChanges({ title, facts, empty }: { title: string; facts: RoleCapabilityFact[]; empty: string }) {
  return <section className="role-change-capabilities" aria-label={title}><h3>{title}</h3>{facts.length === 0 ? <p>{empty}</p> : <ul>{facts.map((fact) => <li key={fact.capability}><strong>{capabilityLabels[fact.capability]}</strong><small>Requires {fact.conditions.map((condition) => conditionLabels[condition]).join(", ").toLocaleLowerCase()}.</small></li>)}</ul>}</section>;
}
