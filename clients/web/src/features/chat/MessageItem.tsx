import { useState } from "react";
import type { FormEvent } from "react";
import { ConfirmDialog } from "../../components/ActionDialog";
import type { Attachment, Message, User } from "../../types";
import { errorText, formatBytes, formatTime, initials } from "../../lib/format";

const quickReactions = ["👍", "❤️", "🎉", "👀"];

export function MessageItem({
  message,
  currentUserId,
  sender,
  replySender,
  replyPreview,
  seenCount,
  focused,
  onReaction,
  onAttachment,
  onReply,
  onThread,
  onEdit,
  onDelete,
  onReport
}: {
  message: Message;
  currentUserId: string;
  sender?: User;
  replySender?: User;
  replyPreview?: Message;
  seenCount: number;
  focused: boolean;
  onReaction: (emoji: string) => void;
  onAttachment: (attachment: Attachment) => void;
  onReply: () => void;
  onThread?: () => void;
  onEdit: (body: string) => Promise<void>;
  onDelete: () => Promise<void>;
  onReport: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [editBody, setEditBody] = useState(message.body || "");
  const [busy, setBusy] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const mine = message.sender_user_id === currentUserId;
  const groups = groupReactions(message, currentUserId);

  async function saveEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editBody.trim() || editBody.trim() === message.body) {
      setEditing(false);
      return;
    }
    setBusy(true);
    try {
      await onEdit(editBody.trim());
      setEditing(false);
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    setDeleteError(null);
    try {
      await onDelete();
      setDeleteOpen(false);
    } catch (reason: unknown) {
      setDeleteError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
    <li id={`message-${message.id}`} className={`message ${mine ? "mine" : ""} ${focused ? "focused" : ""}`}>
      {!mine && <span className="avatar small" aria-hidden="true">{initials(sender?.display_name || "Unknown")}</span>}
      <article className="message-content">
        <header>
          <strong>{mine ? "You" : sender?.display_name || "Unknown user"}</strong>
          <time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time>
          {message.edited_at && <span>edited</span>}
        </header>
        {replyPreview && <div className="reply-preview"><strong>{replyPreview.sender_user_id === currentUserId ? "You" : replySender?.display_name || "Unknown user"}</strong><span>{replyPreview.body || "Message removed"}</span></div>}
        {editing ? (
          <form className="inline-edit" onSubmit={(event) => void saveEdit(event)}>
            <label className="sr-only" htmlFor={`edit-${message.id}`}>Edit message</label>
            <textarea id={`edit-${message.id}`} value={editBody} onChange={(event) => setEditBody(event.target.value)} rows={3} autoFocus maxLength={65_535} />
            <div className="form-actions"><button className="button ghost compact" type="button" onClick={() => { setEditing(false); setEditBody(message.body || ""); }}>Cancel</button><button className="button primary compact" type="submit" disabled={busy || !editBody.trim()}>Save</button></div>
          </form>
        ) : <div className={`message-bubble ${message.status !== "active" ? "removed" : ""}`}>{message.status === "active" ? message.body : "Message removed"}</div>}

        {message.attachments.length > 0 && <div className="message-attachments">{message.attachments.map((attachment) => <AttachmentButton attachment={attachment} key={attachment.id} onOpen={onAttachment} />)}</div>}

        <div className="message-tools">
          <div className="reaction-row">
            {groups.map(({ emoji, count, mine: reacted }) => <button type="button" key={emoji} className={reacted ? "reacted" : ""} aria-pressed={reacted} aria-label={`${reacted ? "Remove" : "Add"} ${emoji} reaction; ${count} total`} onClick={() => onReaction(emoji)}>{emoji} <span>{count}</span></button>)}
            {message.status === "active" && <span className="quick-reactions" aria-label="Quick reactions">{quickReactions.filter((emoji) => !groups.some((group) => group.emoji === emoji)).map((emoji) => <button type="button" key={emoji} aria-label={`React with ${emoji}`} onClick={() => onReaction(emoji)}>{emoji}</button>)}</span>}
          </div>
          <div className="message-actions">{onThread && <button type="button" onClick={onThread}>{threadLabel(message)}</button>}{message.status === "active" && <><button type="button" onClick={onReply}>Reply</button><button type="button" onClick={onReport}>Report</button>{mine && <button type="button" onClick={() => setEditing(true)}>Edit</button>}{mine && <button className="danger-text" type="button" disabled={busy} onClick={() => { setDeleteError(null); setDeleteOpen(true); }}>Delete</button>}</>}</div>
        </div>
        {mine && seenCount > 0 && <small className="seen-copy">Seen by {seenCount}</small>}
      </article>
    </li>
    {deleteOpen && <ConfirmDialog title="Delete this message?" description="This removes the message body from the conversation." impact="Conversation members will see that a message was removed. Retention and audit records remain subject to workspace policy." confirmLabel="Delete message" tone="danger" busy={busy} error={deleteError} onCancel={() => { if (!busy) setDeleteOpen(false); }} onConfirm={() => void remove()} />}
    </>
  );
}

function threadLabel(message: Message): string {
  const count = message.thread_reply_count || 0;
  if (count > 0) return `Thread (${count})`;
  return message.thread_root_message_id ? "View thread" : "Start thread";
}

function AttachmentButton({ attachment, onOpen }: { attachment: Attachment; onOpen: (attachment: Attachment) => void }) {
  const ready = attachment.status === "ready";
  const unsafe = attachment.status === "quarantined" || attachment.status === "scan_failed";
  return <button type="button" disabled={!ready} className={unsafe ? "unsafe-attachment" : ""} onClick={() => onOpen(attachment)}><span aria-hidden="true">{ready ? "▤" : unsafe ? "!" : "…"}</span><span><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachmentState(attachment)}</small></span></button>;
}

function attachmentState(attachment: Attachment): string {
  if (attachment.status === "ready") return "Safety scan passed";
  if (attachment.status === "quarantined") return "Quarantined";
  if (attachment.status === "scan_failed") return "Scan failed";
  if (attachment.status === "deleted") return "Deleted";
  return "Safety scan pending";
}

function groupReactions(message: Message, currentUserId: string) {
  const grouped = new Map<string, { emoji: string; count: number; mine: boolean }>();
  for (const reaction of message.reactions) {
    const value = grouped.get(reaction.emoji) || { emoji: reaction.emoji, count: 0, mine: false };
    value.count += 1;
    value.mine ||= reaction.user_id === currentUserId;
    grouped.set(reaction.emoji, value);
  }
  return [...grouped.values()];
}
