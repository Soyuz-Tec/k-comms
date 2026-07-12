import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { ApiError } from "../../api";
import type { ApiClient } from "../../api";
import type { Conversation, ConversationMembership, User } from "../../types";
import { conversationTitle, errorText, formatDateTime, initials } from "../../lib/format";
import { useModalDialog } from "../../components/useModalDialog";

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
  const dialogRef = useModalDialog(onClose);

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

  async function remove(member: ConversationMembership) {
    if (!member.version) return setError("Reload member details before removing this person.");
    if (!window.confirm(`Remove ${member.user.display_name} from this conversation?`)) return;
    setBusyUserId(member.user.id);
    setError(null);
    try {
      await api.removeConversationMember(conversation.id, member.user.id, member.version);
      await load();
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusyUserId(null);
    }
  }

  async function changeRole(member: ConversationMembership, role: ConversationMembership["role"]) {
    if (!member.version) return setError("Reload member details before changing this role.");
    setBusyUserId(member.user.id); setError(null);
    try { await api.updateConversationMember(conversation.id, member.user.id, role, member.version); await load(); } catch (reason: unknown) { setError(errorText(reason)); } finally { setBusyUserId(null); }
  }

  async function updateConversation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!conversation.version) return setError("Reload this conversation before editing it.");
    const values = new FormData(event.currentTarget); setError(null);
    try { onUpdated(await api.updateConversation(conversation.id, { title: String(values.get("title") || "").trim(), visibility: String(values.get("visibility")) as "private" | "tenant", version: conversation.version })); } catch (reason: unknown) { setError(errorText(reason)); }
  }

  async function archive() {
    if (!conversation.version || !window.confirm("Archive this conversation? Members will retain its durable history, but it will stop accepting normal activity.")) return;
    try { onUpdated(await api.archiveConversation(conversation.id, conversation.version)); onClose(); } catch (reason: unknown) { setError(errorText(reason)); }
  }

  async function leavePublicChannel() {
    if (!currentMembership?.version) return setError("Reload membership details before leaving this channel.");
    if (!window.confirm(`Leave ${conversationTitle(conversation)}? You will need to join again to receive new messages.`)) return;
    setBusyUserId("self-leave");
    setError(null);
    try {
      await api.leavePublicChannel(conversation.id, currentMembership.version);
      onLeft();
    } catch (reason: unknown) {
      if (reason instanceof ApiError && (reason.code === "cannot_remove_owner" || reason.code === "last_owner_required")) {
        setError("Assign another channel owner before leaving this channel.");
      } else if (reason instanceof ApiError && reason.code === "stale_version") {
        setError("Your membership changed. Reloading channel details; try again afterward.");
        await load();
      } else {
        setError(errorText(reason));
      }
    } finally {
      setBusyUserId(null);
    }
  }

  return (
    <div className="drawer-backdrop">
    <aside ref={dialogRef} className="details-panel" role="dialog" aria-modal="true" aria-labelledby="conversation-details-title">
      <header><div><span className="eyebrow">Conversation details</span><h2 id="conversation-details-title">{conversationTitle(conversation)}</h2></div><button className="icon-button" type="button" aria-label="Close details" onClick={onClose}>×</button></header>
      <dl className="definition-list compact-list"><div><dt>Type</dt><dd>{conversation.kind}</dd></div><div><dt>Visibility</dt><dd>{conversation.visibility}</dd></div><div><dt>Created</dt><dd>{formatDateTime(conversation.inserted_at)}</dd></div></dl>
      {error && <div className="form-error" role="alert">{error}</div>}
      {conversation.kind === "channel" && conversation.visibility === "tenant" && currentMembership && <div className="channel-membership-actions"><button className="button danger compact" type="button" disabled={busyUserId === "self-leave"} onClick={() => void leavePublicChannel()}>{busyUserId === "self-leave" ? "Leaving…" : "Leave channel"}</button></div>}
      {canManage && conversation.kind !== "direct" && <form className="details-settings" onSubmit={(event) => void updateConversation(event)}><label className="field">Title<input name="title" defaultValue={conversation.title || ""} maxLength={160} required /></label><label className="field">Visibility<select name="visibility" defaultValue={conversation.visibility}><option value="private">Private</option><option value="tenant">Workspace</option></select></label><div className="form-actions"><button className="button primary compact" type="submit">Save details</button><button className="button danger compact" type="button" onClick={() => void archive()}>Archive</button></div></form>}
      <section aria-labelledby="members-title">
        <div className="card-heading"><h3 id="members-title">Members</h3><span className="status-pill neutral">{members.length}</span></div>
        {loading ? <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading members…</div> : <ul className="member-list">{members.map((member) => <li key={member.id}><span className="avatar" aria-hidden="true">{initials(member.user.display_name)}</span><span><strong>{member.user.display_name} {member.user.account_type === "service" && <span className="role-chip">Bot</span>}</strong><small>{member.user.account_type === "service" ? "Non-login service identity" : member.user.email}</small></span>{membershipMutable && member.role !== "owner" ? <select aria-label={`Role for ${member.user.display_name}`} value={member.role} disabled={busyUserId === member.user.id} onChange={(event) => void changeRole(member, event.target.value as ConversationMembership["role"])}><option value="member">Member</option><option value="moderator">Moderator</option></select> : <span className="role-chip">{member.role}</span>}{membershipMutable && member.role !== "owner" && <button className="text-button danger-text" type="button" disabled={busyUserId === member.user.id} onClick={() => void remove(member)}>Remove</button>}</li>)}</ul>}
      </section>
      {membershipMutable && availableUsers.length > 0 && <label className="field add-member-field">Add a person<select defaultValue="" disabled={Boolean(busyUserId)} onChange={(event) => { const id = event.target.value; event.target.value = ""; void add(id); }}><option value="" disabled>Select teammate</option>{availableUsers.map((user) => <option key={user.id} value={user.id}>{user.display_name}</option>)}</select></label>}
      {conversation.kind === "direct" ? <p className="support-note">Direct-message membership is immutable. Start a new direct message for a different participant.</p> : !canManage && <p className="support-note">Only conversation owners and moderators can change membership.</p>}
    </aside>
    </div>
  );
}
