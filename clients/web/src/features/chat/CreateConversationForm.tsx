import { useMemo, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import type { CreateConversationInput } from "../../api";
import { Field } from "../../components/Field";
import { AppIcon } from "../../components/AppIcon";
import { errorText, stringValue } from "../../lib/format";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import type { User } from "../../types";

export function CreateConversationForm({
  users,
  allowPublicChannels = true,
  emptyDirectAction,
  onCancel,
  onCreate,
  onStartDirect
}: {
  users: User[];
  allowPublicChannels?: boolean;
  emptyDirectAction?: ReactNode;
  onCancel: () => void;
  onCreate: (input: CreateConversationInput) => Promise<void>;
  onStartDirect: (userId: string) => Promise<void>;
}) {
  const [kind, setKind] = useState<CreateConversationInput["kind"]>("direct");
  const [selectedUsers, setSelectedUsers] = useState<string[]>([]);
  const [recipientQuery, setRecipientQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    if (kind === "direct" && selectedUsers.length !== 1) {
      setError("Choose exactly one teammate for a direct message.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (kind === "direct") {
        await onStartDirect(selectedUsers[0]!);
      } else {
        await onCreate({
          title: stringValue(values, "title"),
          kind,
          visibility: stringValue(values, "visibility") as "private" | "tenant",
          member_ids: selectedUsers
        });
      }
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  function toggleUser(userId: string, checked: boolean) {
    setSelectedUsers((current) => {
      if (kind === "direct") return checked ? [userId] : [];
      return checked ? [...new Set([...current, userId])] : current.filter((id) => id !== userId);
    });
  }

  const selectableUsers = useMemo(
    () =>
      kind === "direct"
        ? users.filter(({ account_type: accountType }) => accountType !== "service")
        : users,
    [kind, users]
  );
  const duplicateDisplayNames = useMemo(
    () => duplicateParticipantNames(selectableUsers),
    [selectableUsers]
  );
  const recipientIdentifier = (user: User) => participantIdentifier(user, duplicateDisplayNames);
  const filteredUsers = selectableUsers.filter((user) =>
    recipientIdentifier(user).toLocaleLowerCase().includes(recipientQuery.trim().toLocaleLowerCase())
  );
  const selectedPeople = selectableUsers.filter((user) => selectedUsers.includes(user.id));

  return (
    <form className="create-conversation" onSubmit={(event) => void submit(event)}>
      <h2>New conversation</h2>
      {error && <div className="form-error" role="alert">{error}</div>}
      <label className="field">Type<select name="kind" value={kind} disabled={busy} onChange={(event) => { setKind(event.target.value as CreateConversationInput["kind"]); setSelectedUsers([]); setRecipientQuery(""); }}><option value="direct">Direct message</option><option value="group">Group</option><option value="channel">Channel</option></select></label>
      {kind !== "direct" && <Field label="Title" name="title" maxLength={160} required />}
      {kind !== "direct" && <label className="field">Visibility<select name="visibility" defaultValue="private"><option value="private">Private</option>{allowPublicChannels && <option value="tenant">Workspace</option>}</select>{!allowPublicChannels && <small>Workspace-visible channels are disabled by policy.</small>}</label>}
      {selectableUsers.length > 0 && <label className="field">Find a teammate<input type="search" value={recipientQuery} onChange={(event) => setRecipientQuery(event.target.value)} disabled={busy} placeholder="Search people by name" /></label>}
      {selectedPeople.length > 0 && <section className="recipient-selection" aria-label="Selected people">
        <p>{selectedPeople.length} {selectedPeople.length === 1 ? "person" : "people"} selected</p>
        <div className="recipient-chips">{selectedPeople.map((user) => <span key={user.id}>{recipientIdentifier(user)}<button type="button" disabled={busy} aria-label={`Remove ${recipientIdentifier(user)}`} onClick={() => toggleUser(user.id, false)}><AppIcon name="x" /></button></span>)}</div>
      </section>}
      <fieldset className="member-picker" disabled={busy}>
        <legend>{kind === "direct" ? "Choose a teammate" : "Add people"}</legend>
        {selectableUsers.length === 0 ? <div className="empty-copy"><p>Create another account before starting a conversation.</p>{kind === "direct" && emptyDirectAction}</div> : filteredUsers.length === 0 ? <p className="empty-copy" role="status">No people match this name. Your selections are kept.</p> : filteredUsers.map((user) => (
          <label key={user.id}>
            <input type={kind === "direct" ? "radio" : "checkbox"} name={kind === "direct" ? "direct-member" : undefined} checked={selectedUsers.includes(user.id)} onChange={(event) => toggleUser(user.id, event.target.checked)} />
            <span>{recipientIdentifier(user)}{user.account_type === "service" && <span className="role-chip">Bot</span>}</span>
          </label>
        ))}
      </fieldset>
      <div className="form-actions">
        <button className="button ghost compact" type="button" onClick={onCancel}>Cancel</button>
        <button className="button primary compact" type="submit" disabled={busy}>{busy ? "Creating…" : kind === "direct" ? "Start message" : "Create"}</button>
      </div>
    </form>
  );
}
