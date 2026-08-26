import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { ConfirmDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import type { Attachment, Message } from "../../types";
import { errorText, formatBytes, formatTime, initials } from "../../lib/format";

const quickReactions = ["👍", "❤️", "🎉", "👀"];

export function MessageItem({
  message,
  currentUserId,
  senderName,
  replySenderName,
  replyPreview,
  seenCount,
  deliveredDeviceCount = 0,
  focused,
  onReaction,
  onAttachment,
  onRequestThumbnail,
  onReply,
  onThread,
  onEdit,
  onDelete,
  onReport
}: {
  message: Message;
  currentUserId: string;
  senderName?: string;
  replySenderName?: string;
  replyPreview?: Message;
  seenCount: number;
  deliveredDeviceCount?: number;
  focused: boolean;
  onReaction: (emoji: string) => void;
  onAttachment: (attachment: Attachment) => void;
  /**
   * Resolves a short-lived preview URL, or null when none can be served.
   * Optional so a surface without previews renders exactly as before.
   */
  onRequestThumbnail?: (attachmentId: string) => Promise<string | null>;
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
  const [actionsOpen, setActionsOpen] = useState(false);
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
      {/*
        * Every message carries its sender's avatar, your own included. The
        * desktop transcript is a flat list rather than two facing columns of
        * bubbles, so the avatar gutter is what aligns the rows — skipping it on
        * your own messages left them hanging in an empty column.
        */}
      <span className="avatar small" aria-hidden="true">{initials(senderName || "Unknown")}</span>
      <article className="message-content">
        {/*
          * The sender label sits above the bubble and the timestamp below it,
          * matching the reference design: the name is what you scan when
          * following a thread, the time is reference detail you consult.
          */}
        <header>
          <strong>{mine ? selfIdentifier(senderName) : senderName || "Unknown user"}</strong>
        </header>
        {replyPreview && <div className="reply-preview"><strong>{replyPreview.sender_user_id === currentUserId ? selfIdentifier(replySenderName) : replySenderName || "Unknown user"}</strong><span>{replyPreview.body || "Message removed"}</span></div>}
        {editing ? (
          <form className="inline-edit" onSubmit={(event) => void saveEdit(event)}>
            <label className="sr-only" htmlFor={`edit-${message.id}`}>Edit message</label>
            <textarea id={`edit-${message.id}`} value={editBody} onChange={(event) => setEditBody(event.target.value)} rows={3} autoFocus maxLength={65_535} />
            <div className="form-actions"><button className="button ghost compact" type="button" onClick={() => { setEditing(false); setEditBody(message.body || ""); }}>Cancel</button><button className="button primary compact" type="submit" disabled={busy || !editBody.trim()}>Save</button></div>
          </form>
        ) : <div className={`message-bubble ${message.status !== "active" ? "removed" : ""}`}>{message.status === "active" ? message.body : "Message removed"}</div>}

        {message.attachments.length > 0 && <div className="message-attachments">{message.attachments.map((attachment) => <AttachmentButton attachment={attachment} key={attachment.id} onOpen={onAttachment} onRequestThumbnail={onRequestThumbnail} />)}</div>}

        {message.status === "active" && message.metadata.whiteboard_reference && (
          <a className="message-reference-card" href={`/app/whiteboard?conversation=${encodeURIComponent(message.conversation_id)}&focus_elements=${encodeURIComponent(message.metadata.whiteboard_reference.element_ids.join(","))}`}>
            <AppIcon name="whiteboard" />
            <span><strong>{message.metadata.whiteboard_reference.label || "Whiteboard selection"}</strong><small>Open referenced objects on the shared canvas</small></span>
          </a>
        )}
        {message.status === "active" && (message.metadata.links?.length || 0) > 0 && (
          <div className="message-link-cards" aria-label="Links in this message">
            {message.metadata.links?.map((link) => <a key={link.url} href={link.url} target="_blank" rel="noopener noreferrer nofollow"><AppIcon name="externalLink" /><span><strong>{link.label || linkHost(link.url)}</strong><small>{link.url}</small></span></a>)}
          </div>
        )}

        <div className="message-meta">
          <time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time>
          {message.edited_at && <span>edited</span>}
          {/* Decorative: "Seen by N" below already carries this to assistive tech. */}
          {mine && seenCount > 0 && <AppIcon className="message-seen-mark" name="check" />}
        </div>

        <div className="message-tools">
          <div className="reaction-row">
            {groups.map(({ emoji, count, mine: reacted }) => <button type="button" key={emoji} className={reacted ? "reacted" : ""} aria-pressed={reacted} aria-label={`${reacted ? "Remove" : "Add"} ${emoji} reaction; ${count} total`} onClick={() => onReaction(emoji)}>{emoji} <span>{count}</span></button>)}
            {message.status === "active" && <span className="quick-reactions" aria-label="Quick reactions">{quickReactions.filter((emoji) => !groups.some((group) => group.emoji === emoji)).map((emoji) => <button type="button" key={emoji} aria-label={`React with ${emoji}`} onClick={() => onReaction(emoji)}>{emoji}</button>)}</span>}
          </div>
          <button
            className="mobile-message-actions-trigger"
            type="button"
            aria-label="More message actions"
            aria-expanded={actionsOpen}
            onClick={() => setActionsOpen((open) => !open)}
          >
            <AppIcon name="more" />
          </button>
          <div className={`message-actions ${actionsOpen ? "mobile-open" : ""}`}>{onThread && <button type="button" onClick={() => { setActionsOpen(false); onThread(); }}>{threadLabel(message)}</button>}{message.status === "active" && <><button type="button" onClick={() => { setActionsOpen(false); onReply(); }}>Reply</button><button type="button" onClick={() => { setActionsOpen(false); onReport(); }}>Report</button>{mine && <button type="button" onClick={() => { setActionsOpen(false); setEditing(true); }}>Edit</button>}{mine && <button className="danger-text" type="button" disabled={busy} onClick={() => { setActionsOpen(false); setDeleteError(null); setDeleteOpen(true); }}>Delete</button>}</>}</div>
        </div>
        {mine && (seenCount > 0 || deliveredDeviceCount > 0) && <small className="seen-copy">{deliveredDeviceCount > 0 ? `Delivered to ${deliveredDeviceCount} ${deliveredDeviceCount === 1 ? "device" : "devices"}` : "Sent"}{seenCount > 0 ? ` · Read by ${seenCount}` : ""}</small>}
      </article>
    </li>
    {deleteOpen && <ConfirmDialog title="Delete this message?" description="This removes the message body from the conversation." impact="Conversation members will see that a message was removed. Retention and audit records remain subject to workspace policy." confirmLabel="Delete message" tone="danger" busy={busy} error={deleteError} onCancel={() => { if (!busy) setDeleteOpen(false); }} onConfirm={() => void remove()} />}
    </>
  );
}

function selfIdentifier(senderName?: string): string {
  return senderName ? `${senderName} (you)` : "You";
}

function threadLabel(message: Message): string {
  const count = message.thread_reply_count || 0;
  if (count > 0) return `Thread (${count})`;
  return message.thread_root_message_id ? "View thread" : "Start thread";
}

function AttachmentButton({
  attachment,
  onOpen,
  onRequestThumbnail
}: {
  attachment: Attachment;
  onOpen: (attachment: Attachment) => void;
  onRequestThumbnail?: (attachmentId: string) => Promise<string | null>;
}) {
  const ready = attachment.status === "ready";
  const unsafe = attachment.status === "quarantined" || attachment.status === "scan_failed";
  const preview = useAttachmentThumbnail(attachment, onRequestThumbnail);
  return <button type="button" disabled={!ready} className={`${unsafe ? "unsafe-attachment" : ""}${preview ? " has-thumbnail" : ""}`} onClick={() => onOpen(attachment)}>{preview ? <img className="attachment-thumbnail" src={preview} alt="" width={64} height={64} loading="lazy" decoding="async" /> : <span aria-hidden="true"><AppIcon className={ready || unsafe ? "" : "spin"} name={ready ? "file" : unsafe ? "triangleAlert" : "loader"} /></span>}<span><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachmentState(attachment)}</small></span></button>;
}

/**
 * Resolves a preview URL once per attachment.
 *
 * The preview is decorative: the file name and state remain the accessible
 * content, so the image carries an empty alt and the icon is simply replaced.
 * A failure leaves the icon in place rather than surfacing an error, because a
 * missing preview is not a missing attachment.
 */
function useAttachmentThumbnail(
  attachment: Attachment,
  onRequestThumbnail?: (attachmentId: string) => Promise<string | null>
): string | null {
  const [url, setUrl] = useState<string | null>(null);
  const hasThumbnail = attachment.status === "ready" && !!attachment.variant_kinds?.includes("thumbnail");

  useEffect(() => {
    if (!hasThumbnail || !onRequestThumbnail) return;
    let active = true;
    void onRequestThumbnail(attachment.id)
      .then((resolved) => {
        if (active) setUrl(resolved);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [attachment.id, hasThumbnail, onRequestThumbnail]);

  return hasThumbnail ? url : null;
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

function linkHost(value: string): string {
  try { return new URL(value).hostname; } catch { return "Secure link"; }
}
