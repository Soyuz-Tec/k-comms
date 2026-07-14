import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { Conversation, DeletionRequest, LegalHold, Message, RetentionPolicy, User } from "../../types";
import { conversationTitle, errorText, formatDateTime, stringValue } from "../../lib/format";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";

type PendingGovernanceAction =
  | { kind: "policy"; policy: RetentionPolicy; nextStatus: "active" | "disabled" }
  | { kind: "hold"; hold: LegalHold }
  | { kind: "deletion"; request: DeletionRequest; status: string };

export function GovernancePanel({ api, users, conversations }: { api: ApiClient; users: User[]; conversations: Conversation[] }) {
  const [policies, setPolicies] = useState<RetentionPolicy[]>([]);
  const [holds, setHolds] = useState<LegalHold[]>([]);
  const [requests, setRequests] = useState<DeletionRequest[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [holdScope, setHoldScope] = useState<"tenant" | "user" | "conversation">("tenant");
  const [deletionTargetType, setDeletionTargetType] = useState<"user" | "conversation" | "message">("user");
  const [messageConversationId, setMessageConversationId] = useState("");
  const [availableMessages, setAvailableMessages] = useState<Message[]>([]);
  const [loadingMessages, setLoadingMessages] = useState(false);
  const [pendingAction, setPendingAction] = useState<PendingGovernanceAction | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();
  const selectableUsers = users.filter(({ status }) => status !== "deleted");
  const selectableConversations = conversations.filter(({ archived_at: archivedAt }) => !archivedAt);

  useEffect(() => {
    let current = true;
    void runWithStepUp(() => Promise.all([api.retentionPolicies(), api.legalHolds(), api.deletionRequests()])).then(([nextPolicies, nextHolds, nextRequests]) => {
      if (!current) return;
      setPolicies(nextPolicies); setHolds(nextHolds); setRequests(nextRequests);
    }).catch((reason: unknown) => { if (current && !stepUpWasCancelled(reason)) setError(errorText(reason)); });
    return () => { current = false; };
  }, [api, runWithStepUp]);

  useEffect(() => {
    let current = true;
    if (deletionTargetType !== "message" || !messageConversationId) {
      setAvailableMessages([]);
      return () => { current = false; };
    }
    setLoadingMessages(true);
    void api.messages(messageConversationId, 0, 200)
      .then((page) => { if (current) setAvailableMessages(page.data.filter(({ status }) => status !== "deleted")); })
      .catch((reason: unknown) => { if (current) setError(errorText(reason)); })
      .finally(() => { if (current) setLoadingMessages(false); });
    return () => { current = false; };
  }, [api, deletionTargetType, messageConversationId]);

  async function createPolicy(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const form = event.currentTarget; const values = new FormData(form); setBusy("policy"); setError(null);
    try { const policy = await runWithStepUp(() => api.createRetentionPolicy({ name: stringValue(values, "name"), retention_days: Number(values.get("retention_days")), delete_attachments: values.get("delete_attachments") === "on" })); setPolicies((current) => [...current, policy]); form.reset(); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  async function createHold(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const form = event.currentTarget; const values = new FormData(form); setBusy("hold"); setError(null);
    try { const hold = await runWithStepUp(() => api.createLegalHold({ name: stringValue(values, "name"), reason: stringValue(values, "reason"), scope_type: holdScope, target_id: holdScope === "tenant" ? undefined : stringValue(values, "hold_target_id") })); setHolds((current) => [hold, ...current]); form.reset(); setHoldScope("tenant"); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  async function createDeletion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const form = event.currentTarget; const values = new FormData(form); setBusy("deletion"); setError(null);
    try { const request = await runWithStepUp(() => api.createDeletionRequest({ target_type: deletionTargetType, target_id: stringValue(values, "target_id"), reason: stringValue(values, "reason") })); setRequests((current) => [request, ...current]); form.reset(); setDeletionTargetType("user"); setMessageConversationId(""); } catch (reason: unknown) { if (!stepUpWasCancelled(reason)) setError(errorText(reason)); } finally { setBusy(null); }
  }

  async function confirmAction(reason: string) {
    if (!pendingAction) return;
    const action = pendingAction;
    const busyKey = action.kind === "policy" ? `policy-${action.policy.id}` : action.kind === "hold" ? `hold-${action.hold.id}` : `deletion-${action.request.id}`;
    setBusy(busyKey);
    setActionError(null);
    try {
      if (action.kind === "policy") {
        const updated = await runWithStepUp(() => api.updateRetentionPolicy(action.policy.id, { status: action.nextStatus, version: action.policy.version, reason }));
        setPolicies((current) => current.map((value) => value.id === updated.id ? updated : value));
      } else if (action.kind === "hold") {
        const updated = await runWithStepUp(() => api.releaseLegalHold(action.hold.id, action.hold.version, reason));
        setHolds((current) => current.map((value) => value.id === updated.id ? updated : value));
      } else {
        const updated = await runWithStepUp(() => api.updateDeletionRequest(action.request.id, { status: action.status, version: action.request.version, transition_reason: reason }));
        setRequests((current) => current.map((value) => value.id === updated.id ? updated : value));
      }
      setPendingAction(null);
    } catch (cause: unknown) {
      if (!stepUpWasCancelled(cause)) setActionError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }

  const dialog = pendingAction ? governanceDialog(pendingAction) : null;

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}
    {dialog && <ActionDialog {...dialog} auditReason={{ helpText: "This reason is retained in the audit record.", minimumLength: 3 }} busy={busy !== null} error={actionError} onCancel={() => { if (!busy) { setPendingAction(null); setActionError(null); } }} onConfirm={(reason) => void confirmAction(reason)} />}
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Lifecycle policy</span><h2>Retention policies</h2></div><span className="status-pill success">Live API</span></div><form className="inline-admin-form" onSubmit={(event) => void createPolicy(event)}><label className="field">Policy name<input name="name" required maxLength={120} /></label><label className="field">Retention days<input name="retention_days" type="number" min={1} max={36500} required /></label><label className="checkbox-field inline-checkbox"><input name="delete_attachments" type="checkbox" defaultChecked />Delete attachments</label><button className="button primary" type="submit" disabled={busy === "policy"}>Create policy</button></form><ul className="security-list">{policies.map((policy) => <li key={policy.id}><div><strong>{policy.name}</strong><small>{policy.scope_type} · {policy.retention_days} days · {policy.delete_attachments ? "attachments included" : "attachments retained"}</small></div><span className={`status-pill ${policy.status === "active" ? "success" : "neutral"}`}>{policy.status}</span><button className="button ghost compact" type="button" disabled={busy === `policy-${policy.id}`} onClick={() => { setActionError(null); setPendingAction({ kind: "policy", policy, nextStatus: policy.status === "active" ? "disabled" : "active" }); }}>{policy.status === "active" ? "Disable" : "Enable"}</button></li>)}</ul></section>
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Preservation</span><h2>Legal holds</h2></div><span className="status-pill success">Live API</span></div><form className="inline-admin-form" onSubmit={(event) => void createHold(event)}><label className="field">Hold name<input name="name" required /></label><label className="field">Hold scope<select name="scope_type" value={holdScope} onChange={(event) => setHoldScope(event.target.value as typeof holdScope)}><option value="tenant">Entire workspace</option><option value="user">Person</option><option value="conversation">Conversation</option></select></label>{holdScope === "user" && <UserTargetSelect name="hold_target_id" label="Hold user" users={selectableUsers} />}{holdScope === "conversation" && <ConversationTargetSelect name="hold_target_id" label="Hold conversation" conversations={selectableConversations} />}<label className="field grow-field">Reason<input name="reason" required /></label><button className="button primary" type="submit" disabled={busy === "hold"}>Create legal hold</button></form><ul className="security-list">{holds.map((hold) => <li key={hold.id}><div><strong>{hold.name}</strong><small>{holdTargetLabel(hold, users, conversations)} · {hold.reason} · Started {formatDateTime(hold.starts_at)}</small></div><span className={`status-pill ${hold.status === "active" ? "success" : "neutral"}`}>{hold.status}</span>{hold.status === "active" && <button className="button danger compact" type="button" disabled={busy === `hold-${hold.id}`} onClick={() => { setActionError(null); setPendingAction({ kind: "hold", hold }); }}>Release</button>}</li>)}</ul></section>
    <section className="data-card"><div className="card-heading"><div><span className="eyebrow">Auditable erasure</span><h2>Deletion requests</h2></div><span className="status-pill success">Live API</span></div><form className="inline-admin-form deletion-form" onSubmit={(event) => void createDeletion(event)}><label className="field">Target type<select name="target_type" value={deletionTargetType} onChange={(event) => { setDeletionTargetType(event.target.value as typeof deletionTargetType); setMessageConversationId(""); }}><option value="user">Person</option><option value="conversation">Conversation</option><option value="message">Message</option></select></label>{deletionTargetType === "user" && <UserTargetSelect name="target_id" label="Deletion user" users={selectableUsers} />}{deletionTargetType === "conversation" && <ConversationTargetSelect name="target_id" label="Deletion conversation" conversations={selectableConversations} />}{deletionTargetType === "message" && <><label className="field">Message conversation<select aria-label="Message conversation" value={messageConversationId} onChange={(event) => setMessageConversationId(event.target.value)} required><option value="">Select conversation</option>{selectableConversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationTitle(conversation)}</option>)}</select></label><label className="field grow-field">Deletion message<select name="target_id" required disabled={!messageConversationId || loadingMessages}><option value="">{loadingMessages ? "Loading messages…" : "Select message"}</option>{availableMessages.map((message) => <option key={message.id} value={message.id}>{messageLabel(message, users)}</option>)}</select></label></>}<label className="field grow-field">Reason<input name="reason" required /></label><button className="button primary" type="submit" disabled={busy === "deletion"}>Request deletion</button></form><ul className="security-list">{requests.map((request) => <li key={request.id}><div><strong>{request.target_type} · {deletionTargetLabel(request, users, conversations)}</strong><small>{request.reason} · {formatDateTime(request.inserted_at)}</small></div><span className={`status-pill ${["pending", "approved", "in_progress"].includes(request.status) ? "success" : "neutral"}`}>{request.status}</span>{nextStatuses(request.status).map((status) => <button className="button ghost compact" type="button" key={status} disabled={busy === `deletion-${request.id}`} onClick={() => { setActionError(null); setPendingAction({ kind: "deletion", request, status }); }}>{status.replace("_", " ")}</button>)}</li>)}</ul></section>
  </>;
}

function governanceDialog(action: PendingGovernanceAction) {
  if (action.kind === "policy") {
    const verb = action.nextStatus === "active" ? "Enable" : "Disable";
    return { title: `${verb} retention policy?`, description: action.policy.name, impact: action.nextStatus === "active" ? "The policy will begin governing eligible retained data." : "The policy will stop governing new lifecycle processing until re-enabled.", confirmLabel: `${verb} policy`, tone: "default" as const };
  }
  if (action.kind === "hold") return { title: "Release legal hold?", description: action.hold.name, impact: "The preserved scope will no longer be protected by this hold. Existing retention and deletion policies may apply.", confirmLabel: "Release hold", tone: "danger" as const };
  const label = action.status.replaceAll("_", " ");
  return { title: `${label[0]?.toUpperCase()}${label.slice(1)} deletion request?`, description: `${action.request.target_type} deletion request`, impact: `The request will move from ${action.request.status.replaceAll("_", " ")} to ${label}.`, confirmLabel: `Confirm ${label}`, tone: ["rejected", "cancelled"].includes(action.status) ? "danger" as const : "default" as const };
}

function UserTargetSelect({ name, label, users }: { name: string; label: string; users: User[] }) { return <label className="field grow-field">{label}<select name={name} required><option value="">Select person</option>{users.map((user) => <option key={user.id} value={user.id}>{user.display_name}{user.account_type === "service" ? " (Bot)" : ""}</option>)}</select></label>; }
function ConversationTargetSelect({ name, label, conversations }: { name: string; label: string; conversations: Conversation[] }) { return <label className="field grow-field">{label}<select name={name} required><option value="">Select conversation</option>{conversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationTitle(conversation)}</option>)}</select></label>; }
function holdTargetLabel(hold: LegalHold, users: User[], conversations: Conversation[]): string { if (hold.scope_type === "tenant") return "Entire workspace"; if (hold.scope_type === "user") return users.find(({ id }) => id === hold.subject_user_id)?.display_name || hold.subject_user_id || "Unknown person"; const conversation = conversations.find(({ id }) => id === hold.conversation_id); return conversation ? conversationTitle(conversation) : hold.conversation_id || "Unknown conversation"; }
function deletionTargetLabel(request: DeletionRequest, users: User[], conversations: Conversation[]): string { if (request.target_type === "user") return users.find(({ id }) => id === request.subject_user_id)?.display_name || request.subject_user_id || "Unknown person"; if (request.target_type === "conversation") return conversations.find(({ id }) => id === request.conversation_id)?.title || request.conversation_id || "Unknown conversation"; return request.message_id || "Unknown message"; }
function messageLabel(message: Message, users: User[]): string { const sender = users.find(({ id }) => id === message.sender_user_id)?.display_name || "Unknown sender"; const body = (message.body || "Deleted message").replace(/\s+/g, " ").slice(0, 80); return `#${message.conversation_sequence} · ${sender} · ${body}`; }
function nextStatuses(status: DeletionRequest["status"]): string[] { return ({ pending: ["approved", "rejected", "cancelled"], approved: ["cancelled"], in_progress: [], completed: [], rejected: [], cancelled: [] } as Record<DeletionRequest["status"], string[]>)[status]; }
