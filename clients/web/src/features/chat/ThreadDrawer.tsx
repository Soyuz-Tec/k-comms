import { useEffect, useRef, useState } from "react";
import type { ApiClient, SendMessageInput } from "../../api";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { AppIcon } from "../../components/AppIcon";
import { errorText, formatBytes, formatTime } from "../../lib/format";
import type {
  Attachment,
  ConversationMembership,
  Message,
  RetainedSenderLabel,
  User
} from "../../types";
import { MentionPicker } from "./MentionPicker";
import {
  attachmentLabel,
  useThreadAttachments
} from "./useThreadAttachments";
import { useThreadComposer } from "./useThreadComposer";
import { useThreadSenderIdentities } from "./useThreadSenderIdentities";

export function ThreadDrawer({
  api,
  tenantId,
  conversationId,
  targetMessageId,
  currentUserId,
  maxAttachmentBytes,
  members,
  users,
  retainedSenderLabels,
  liveMessages,
  onClose,
  onSend
}: {
  api: ApiClient;
  tenantId: string;
  conversationId: string;
  targetMessageId: string;
  currentUserId: string;
  maxAttachmentBytes?: number;
  members: ConversationMembership[];
  users: User[];
  retainedSenderLabels?: ReadonlyMap<string, RetainedSenderLabel>;
  liveMessages: Message[];
  onClose: () => void;
  onSend: (input: SendMessageInput) => Promise<Message>;
}) {
  const [root, setRoot] = useState<Message | null>(null);
  const [replies, setReplies] = useState<Message[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [beforeSequence, setBeforeSequence] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const activeThreadKeyRef = useRef(`${conversationId}:${targetMessageId}`);
  activeThreadKeyRef.current = `${conversationId}:${targetMessageId}`;
  const requestGenerationRef = useRef(0);
  const dialogRef = useModalDialog(onClose);
  const {
    attachmentAnnouncement,
    attachmentsReady,
    clearPending,
    filesSelected,
    openAttachment,
    pendingAttachments,
    removePendingAttachment,
    reserveForSend,
    reset: resetAttachments,
    uploading
  } = useThreadAttachments({
    activeThreadKeyRef,
    api,
    conversationId,
    maxAttachmentBytes,
    requestGenerationRef,
    setError,
    targetMessageId
  });
  const {
    mergeSenderLabels,
    resetSenderLabels,
    senderIdentifier
  } = useThreadSenderIdentities({
    api,
    conversationId,
    currentUserId,
    members,
    replies,
    retainedSenderLabels,
    root,
    targetMessageId,
    users
  });
  const {
    composer,
    composerChanged,
    failedSend,
    initializeDraft,
    mentionedUserIds,
    retrySend,
    send,
    sending,
    setMentionedUserIds
  } = useThreadComposer({
    activeThreadKeyRef,
    attachmentsReady,
    clearPendingAttachments: clearPending,
    conversationId,
    currentUserId,
    mergeReply: (reply) =>
      setReplies((current) => mergeMessages(current, [reply])),
    onSend,
    pendingAttachments,
    requestGenerationRef,
    reserveAttachmentsForSend: reserveForSend,
    root,
    setError,
    targetMessageId,
    tenantId
  });

  useEffect(() => {
    let current = true;
    const requestGeneration = ++requestGenerationRef.current;
    setLoading(true);
    setLoadingOlder(false);
    setRoot(null);
    setReplies([]);
    resetAttachments();
    setError(null);
    resetSenderLabels();
    void api
      .messageThread(conversationId, targetMessageId)
      .then((thread) => {
        if (!current || requestGenerationRef.current !== requestGeneration) return;
        initializeDraft(thread.data.root.id);
        setRoot(thread.data.root);
        setReplies(thread.data.replies);
        setHasMore(thread.page.has_more);
        setBeforeSequence(thread.page.next_before_sequence);
        resetSenderLabels(thread.included?.sender_labels);
      })
      .catch((reason: unknown) => {
        if (current && requestGenerationRef.current === requestGeneration) {
          setError(errorText(reason));
        }
      })
      .finally(() => {
        if (current && requestGenerationRef.current === requestGeneration) {
          setLoading(false);
        }
      });
    return () => {
      current = false;
    };
  }, [
    api,
    conversationId,
    initializeDraft,
    resetAttachments,
    resetSenderLabels,
    targetMessageId
  ]);

  useEffect(() => {
    if (!root) return;
    const relevant = liveMessages.filter(
      (message) => message.id === root.id || message.thread_root_message_id === root.id
    );
    const rootUpdate = relevant.find((message) => message.id === root.id);
    if (rootUpdate) setRoot(rootUpdate);
    const incomingReplies = relevant.filter((message) => message.id !== root.id);
    if (incomingReplies.length > 0) {
      setReplies((current) => mergeMessages(current, incomingReplies));
    }
  }, [liveMessages, root?.id]);

  async function loadOlder() {
    if (!root || !hasMore || beforeSequence === null || loadingOlder) return;
    const threadKey = `${conversationId}:${targetMessageId}`;
    const requestGeneration = requestGenerationRef.current;
    const rootId = root.id;
    setLoadingOlder(true);
    setError(null);
    try {
      const thread = await api.messageThread(conversationId, rootId, beforeSequence);
      if (
        activeThreadKeyRef.current !== threadKey ||
        requestGenerationRef.current !== requestGeneration
      ) return;
      setReplies((current) => mergeMessages(thread.data.replies, current));
      mergeSenderLabels(thread.included?.sender_labels);
      setHasMore(thread.page.has_more);
      setBeforeSequence(thread.page.next_before_sequence);
    } catch (reason: unknown) {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setError(errorText(reason));
      }
    } finally {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setLoadingOlder(false);
      }
    }
  }

  return (
    <div className="drawer-backdrop thread-backdrop">
      <aside ref={dialogRef} className="thread-drawer" role="dialog" aria-modal="true" aria-labelledby="thread-title">
        <header>
          <div><span className="eyebrow">Conversation thread</span><h2 id="thread-title">Thread</h2></div>
          <AppSurfaceControlButton
            accessibleLabel="Close thread"
            kind="close"
            onClick={onClose}
          />
        </header>
        {error && <div className="form-error" role="alert">{error}</div>}
        {loading ? <div className="inline-loading" aria-busy="true"><span className="spinner" aria-hidden="true" />Loading thread…</div> : root && (
          <>
            <ThreadMessage message={root} senderName={senderIdentifier(root.sender_user_id)} onAttachment={(attachment) => void openAttachment(attachment)} root />
            <div className="thread-divider"><span>{Math.max(root.thread_reply_count || 0, replies.length)} replies</span></div>
            {hasMore && <button className="button ghost compact thread-load" type="button" disabled={loadingOlder} onClick={() => void loadOlder()}>{loadingOlder ? "Loading…" : "Load older replies"}</button>}
            <ol className="thread-replies" aria-live="polite">
              {replies.map((message) => <ThreadMessage key={message.id} message={message} senderName={senderIdentifier(message.sender_user_id)} onAttachment={(attachment) => void openAttachment(attachment)} />)}
            </ol>
            <form className="thread-composer" aria-busy={sending || uploading} onSubmit={(event) => void send(event)}>
              {failedSend && <div className="failed-send" role="alert" style={{ gridColumn: "1 / -1" }}><span>Reply not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
              {pendingAttachments.length > 0 && <div className="pending-files" aria-label="Files being attached to this thread" style={{ gridColumn: "1 / -1" }}>{pendingAttachments.map(({ attachment, localName }) => { const unsafe = ["quarantined", "scan_failed"].includes(attachment.status); const ready = attachment.status === "ready"; return <span className={`file-chip attachment-${attachment.status}`} key={attachment.id}><span aria-hidden="true"><AppIcon className={ready || unsafe ? "" : "spin"} name={ready ? "check" : unsafe ? "triangleAlert" : "loader"} /></span><span>{localName}<small>{attachmentLabel(attachment)}</small></span><button type="button" aria-label={`Remove ${localName}`} onClick={() => removePendingAttachment(attachment)}><AppIcon name="x" /></button></span>; })}</div>}
              <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{attachmentAnnouncement}</p>
              <MentionPicker members={members} currentUserId={currentUserId} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
              <label htmlFor="thread-composer">Reply in thread</label>
              <textarea id="thread-composer" rows={3} value={composer} onChange={(event) => composerChanged(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} maxLength={65_535} disabled={sending} data-initial-focus />
              <label className={`attachment-button ${uploading ? "disabled" : ""}`}><input type="file" aria-label="Attach files to this thread" multiple disabled={uploading || sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" /><AppIcon name="paperclip" />{uploading ? "Uploading…" : "Attach"}</label>
              <span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span>
              <button className="button primary compact" type="submit" disabled={sending || uploading || !attachmentsReady || !composer.trim()}>{sending ? "Sending…" : "Reply"}</button>
            </form>
          </>
        )}
      </aside>
    </div>
  );
}

function ThreadMessage({ message, senderName, onAttachment, root = false }: { message: Message; senderName: string; onAttachment: (attachment: Attachment) => void; root?: boolean }) {
  return (
    <article className={`thread-message ${root ? "thread-root" : ""}`}>
      <header><strong>{senderName}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></header>
      <p className={message.status === "active" ? "" : "removed"}>{message.status === "active" ? message.body : "Message removed"}</p>
      {message.attachments.length > 0 && <div className="message-attachments">{message.attachments.map((attachment) => <ThreadAttachment key={attachment.id} attachment={attachment} onOpen={onAttachment} />)}</div>}
    </article>
  );
}

function ThreadAttachment({ attachment, onOpen }: { attachment: Attachment; onOpen: (attachment: Attachment) => void }) {
  const ready = attachment.status === "ready";
  const unsafe = attachment.status === "quarantined" || attachment.status === "scan_failed";
  return <button type="button" disabled={!ready} className={unsafe ? "unsafe-attachment" : ""} onClick={() => onOpen(attachment)}><span aria-hidden="true"><AppIcon className={ready || unsafe ? "" : "spin"} name={ready ? "file" : unsafe ? "triangleAlert" : "loader"} /></span><span><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachmentLabel(attachment)}</small></span></button>;
}

function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  const byId = new Map(current.map((message) => [message.id, message]));
  incoming.forEach((message) => byId.set(message.id, message));
  return [...byId.values()].sort(
    (left, right) => left.conversation_sequence - right.conversation_sequence
  );
}
