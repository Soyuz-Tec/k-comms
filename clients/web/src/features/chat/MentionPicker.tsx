import { useId, useMemo, useState } from "react";
import type { ConversationMembership } from "../../types";

const maxMentions = 50;

export function MentionPicker({
  members,
  currentUserId,
  selectedUserIds,
  disabled,
  onChange
}: {
  members: ConversationMembership[];
  currentUserId: string;
  selectedUserIds: string[];
  disabled?: boolean;
  onChange: (userIds: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const listId = useId();
  const available = useMemo(
    () =>
      members
        .filter(
          ({ user }) =>
            user.id !== currentUserId && user.status === "active" && user.account_type !== "service"
        )
        .sort((left, right) => left.user.display_name.localeCompare(right.user.display_name)),
    [currentUserId, members]
  );
  const byId = useMemo(
    () => new Map(available.map(({ user }) => [user.id, user])),
    [available]
  );

  function toggle(userId: string) {
    if (selectedUserIds.includes(userId)) {
      onChange(selectedUserIds.filter((id) => id !== userId));
    } else if (selectedUserIds.length < maxMentions) {
      onChange([...selectedUserIds, userId]);
    }
  }

  return (
    <div className="mention-picker">
      <button
        className="button ghost compact mention-trigger"
        type="button"
        aria-expanded={open}
        aria-controls={listId}
        disabled={disabled || available.length === 0}
        onClick={() => setOpen((visible) => !visible)}
      >
        <span aria-hidden="true">@</span>
        Mention{selectedUserIds.length > 0 ? ` (${selectedUserIds.length})` : ""}
      </button>
      {open && (
        <div id={listId} className="mention-menu" role="group" aria-label="Mention conversation members">
          <p>Select active people in this conversation.</p>
          <div className="mention-options">
            {available.map(({ user }) => {
              const selected = selectedUserIds.includes(user.id);
              return (
                <label key={user.id}>
                  <input
                    type="checkbox"
                    checked={selected}
                    disabled={!selected && selectedUserIds.length >= maxMentions}
                    onChange={() => toggle(user.id)}
                  />
                  <span>{user.display_name}</span>
                </label>
              );
            })}
          </div>
        </div>
      )}
      {selectedUserIds.length > 0 && (
        <div className="mention-chips" aria-label="People mentioned">
          {selectedUserIds.map((userId) => (
            <span key={userId}>
              @{byId.get(userId)?.display_name || "Member"}
              <button type="button" aria-label={`Remove mention ${byId.get(userId)?.display_name || "member"}`} onClick={() => toggle(userId)}>×</button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
