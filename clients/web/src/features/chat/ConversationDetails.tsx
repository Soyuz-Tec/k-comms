import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { ApiError } from "../../api";
import type { ApiClient } from "../../api";
import { ConfirmDialog } from "../../components/ActionDialog";
import { useModalDialog } from "../../components/useModalDialog";
import type { Conversation, ConversationMembership, User } from "../../types";
import { conversationTitle, errorText, formatDateTime, initials } from "../../lib/format";

type PendingAction =
  | { kind: "remove"; member: ConversationMembership }
  | { kind: "archive" }
  | { kind: "leave" };

export function ConversationDetails({
  api,
  conversation,
  currentUserId,
  users,
  onClose,
  onLeft,
  onUpdated
}: {
  api: ApiClient;
  conversation: Conversation;
  currentUserId: string;
  users: User[];
  onClose: () => void;
  onLeft: () => void;
  onUpdated: (conversation: Conversation) => void;
}) {
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [actionBusy, setActionBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [restoreActionKey, setRestoreActionKey] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setMembers(await api.conversationMembers(conversation.id));
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setLoading(false);
    }
  }, [api, conversation.id]);

  useEffect(() => { void load(); }, [load]);
  const currentMembership = members.find(({ user }) => user.id === currentUserId);
  const canManage = currentMembership?.role === "owner" || currentMembership?.role === "moderator";
  const membershipMutable = canManage && conversation.kind !== "direct";
  const availableUsers = useMemo(() => users.filter((user) => !members.some((member) => member.user.id === user.id)), [members, users]);

  async function add(userId: string) {
    if (!userId) return;
    setBusyUserId(userId);
    setError(null);
    try {
      await api.addConversationMember(conversation.id, userId);
      await load();
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusyUserId(null);
    }
  }

  async function changeRole(member: ConversationMembership, role: ConversationMembership["role"]) {
    if (!member.version) return setError("Reload member details before changing this role.");
    setBusyUserId(member.user.id);
    setError(null);
    try {
      await api.updateConversationMember(conversation.id, member.user.id, role, member.version);
      await load();
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusyUserId(null);
    }
  }

  async function updateConversation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!conversation.version) return setError("Reload this conversation before editing it.");
    const values = new FormData(event.currentTarget);
    setError(null);
    try {
      onUpdated(await api.updateConversation(conversation.id, {
        title: String(values.get("title") || "").trim(),
        visibility: String(values.get("visibility")) as "private" | "tenant",
        version: conversation.version
      }));
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  function requestRemove(member: ConversationMembership) {
    if (!member.version) return setError("Reload member details before removing this person.");
    setRestoreActionKey(`remove:${member.id}`);
    setActionError(null);
    setPendingAction({ kind: "remove", member });
  }

  function requestArchive() {
    if (!conversation.version) return setError("Reload this conversation before archiving it.");
    setRestoreActionKey("archive");
    setActionError(null);
    setPendingAction({ kind: "archive" });
  }

  function requestLeave() {
    if (!currentMembership?.version) return setError("Reload membership details before leaving this channel.");
    setRestoreActionKey("leave");
    setActionError(null);
    setPendingAction({ kind: "leave" });
  }

  async function confirmPendingAction() {
    const action = pendingAction;
    if (!action || actionBusy) return;
    setActionBusy(true);
    setActionError(null);
    setError(null);
    try {
      if (action.kind === "remove") {
        if (!action.member.version) throw new Error("Reload member details before removing this person.");
        setBusyUserId(action.member.user.id);
        await api.removeConversationMember(conversation.id, action.member.user.id, action.member.version);
        await load();
        setPendingAction(null);
      } else if (action.kind === "archive") {
        if (!conversation.version) throw new Error("Reload this conversation before archiving it.");
        onUpdated(await api.archiveConversation(conversation.id, conversation.version));
        setPendingAction(null);
        onClose();
      } else {
        if (!currentMembership?.version) throw new Error("Reload membership details before leaving this channel.");
        setBusyUserId("self-leave");
        await api.leavePublicChannel(conversation.id, currentMembership.version);
        setPendingAction(null);
        onLeft();
      }
    } catch (reason: unknown) {
      if (action.kind === "leave" && reason instanceof ApiError && (reason.code === "cannot_remove_owner" || reason.code === "last_owner_required")) {
        setActionError("Assign another channel owner before leaving this channel.");
      } else if (action.kind === "leave" && reason instanceof ApiError && reason.code === "stale_version") {
        setActionError("Your membership changed. Reloading channel details; try again afterward.");
        await load();
      } else {
        setActionError(errorText(reason));
      }
    } finally {
      setBusyUserId(null);
      setActionBusy(false);
    }
  }

  if (pendingAction) {
    const copy = actionDialogCopy(pendingAction, conversation);
    return <ConfirmDialog {...copy} tone="danger" busy={actionBusy} error={actionError} onCancel={() => { if (!actionBusy) setPendingAction(null); }} onConfirm={() => void confirmPendingAction()} />;
  }

  return <ConversationDetailsPanel
    conversation={conversation}
    members={members}
    currentMembership={currentMembership}
    availableUsers={availableUsers}
    loading={loading}
    busyUserId={busyUserId}
    error={error}
    canManage={canManage}
    membershipMutable={membershipMutable}
    restoreActionKey={restoreActionKey}
    onClose={onClose}
    onAdd={(userId) => void add(userId)}
    onRemove={requestRemove}
    onRoleChange={(member, role) => void changeRole(member, role)}
    onUpdateConversation={(event) => void updateConversation(event)}
    onArchive={requestArchive}
    onLeave={requestLeave}
  />;
}

function ConversationDetailsPanel({
  conversation,
  members,
  currentMembership,
  availableUsers,
  loading,
  busyUserId,
  error,
  canManage,
  membershipMutable,
  restoreActionKey,
  onClose,
  onAdd,
  onRemove,
  onRoleChange,
  onUpdateConversation,
  onArchive,
  onLeave
}: {
  conversation: Conversation;
  members: ConversationMembership[];
  currentMembership?: ConversationMembership;
  availableUsers: User[];
  loading: boolean;
  busyUserId: string | null;
  error: string | null;
  canManage: boolean;
  membershipMutable: boolean;
  restoreActionKey: string | null;
  onClose: () => void;
  onAdd: (userId: string) => void;
  onRemove: (member: ConversationMembership) => void;
  onRoleChange: (member: ConversationMembership, role: ConversationMembership["role"]) => void;
  onUpdateConversation: (event: FormEvent<HTMLFormElement>) => void;
  onArchive: () => void;
  onLeave: () => void;
}) {
  const dialogRef = useModalDialog(onClose);
  return (
    <div className="drawer-backdrop">
      <aside ref={dialogRef} className="details-panel" role="dialog" aria-modal="true" aria-labelledby="conversation-details-title">
        <header><div><span className="eyebrow">Conversation details</span><h2 id="conversation-details-title">{conversationTitle(conversation)}</h2></div><button className="icon-button" type="button" aria-label="Close details" onClick={onClose}>×</button></header>
        <dl className="definition-list compact-list"><div><dt>Type</dt><dd>{conversation.kind}</dd></div><div><dt>Visibility</dt><dd>{conversation.visibility}</dd></div><div><dt>Created</dt><dd>{formatDateTime(conversation.inserted_at)}</dd></div></dl>
        {error && <div className="form-error" role="alert">{error}</div>}
        {conversation.kind === "channel" && conversation.visibility === "tenant" && currentMembership && <div className="channel-membership-actions"><button className="button danger compact" type="button" data-initial-focus={restoreActionKey === "leave" ? true : undefined} disabled={busyUserId === "self-leave"} onClick={onLeave}>{busyUserId === "self-leave" ? "Leaving…" : "Leave channel"}</button></div>}
        {canManage && conversation.kind !== "direct" && <form className="details-settings" onSubmit={onUpdateConversation}><label className="field">Title<input name="title" defaultValue={conversation.title || ""} maxLength={160} required /></label><label className="field">Visibility<select name="visibility" defaultValue={conversation.visibility}><option value="private">Private</option><option value="tenant">Workspace</option></select></label><div className="form-actions"><button className="button primary compact" type="submit">Save details</button><button className="button danger compact" type="button" data-initial-focus={restoreActionKey === "archive" ? true : undefined} onClick={onArchive}>Archive</button></div></form>}
        <section aria-labelledby="members-title">
          <div className="card-heading"><h3 id="members-title">Members</h3><span className="status-pill neutral">{members.length}</span></div>
          {loading ? <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading members…</div> : <ul className="member-list">{members.map((member) => <li key={member.id}><span className="avatar" aria-hidden="true">{initials(member.user.display_name)}</span><span><strong>{member.user.display_name} {member.user.account_type === "service" && <span className="role-chip">Bot</span>}</strong><small>{member.user.account_type === "service" ? "Non-login service identity" : member.user.email}</small></span>{membershipMutable && member.role !== "owner" ? <select aria-label={`Role for ${member.user.display_name}`} value={member.role} disabled={busyUserId === member.user.id} onChange={(event) => onRoleChange(member, event.target.value as ConversationMembership["role"])}><option value="member">Member</option><option value="moderator">Moderator</option></select> : <span className="role-chip">{member.role}</span>}{membershipMutable && member.role !== "owner" && <button className="text-button danger-text" type="button" data-initial-focus={restoreActionKey === `remove:${member.id}` ? true : undefined} disabled={busyUserId === member.user.id} onClick={() => onRemove(member)}>Remove</button>}</li>)}</ul>}
        </section>
        {membershipMutable && availableUsers.length > 0 && <label className="field add-member-field">Add a person<select defaultValue="" disabled={Boolean(busyUserId)} onChange={(event) => { const id = event.target.value; event.target.value = ""; onAdd(id); }}><option value="" disabled>Select teammate</option>{availableUsers.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select></label>}
        {conversation.kind === "direct" ? <p className="support-note">Direct-message membership is immutable. Start a new direct message for a different participant.</p> : !canManage && <p className="support-note">Only conversation owners and moderators can change membership.</p>}
      </aside>
    </div>
  );
}

function actionDialogCopy(action: PendingAction, conversation: Conversation) {
  if (action.kind === "remove") {
    return {
      title: `Remove ${action.member.user.display_name}?`,
      description: `Remove this person from ${conversationTitle(conversation)}?`,
      impact: "They will stop receiving new activity in this conversation. Durable history remains subject to workspace policy.",
      confirmLabel: "Remove member"
    };
  }
  if (action.kind === "archive") {
    return {
      title: `Archive ${conversationTitle(conversation)}?`,
      description: "Archive this conversation for everyone.",
      impact: "Members retain its durable history, but the conversation stops accepting normal activity.",
      confirmLabel: "Archive conversation"
    };
  }
  return {
    title: `Leave ${conversationTitle(conversation)}?`,
    description: "Leave this workspace channel.",
    impact: "You will stop receiving new messages and must join again to resume participation.",
    confirmLabel: "Leave channel"
  };
}
