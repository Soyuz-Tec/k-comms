import { useEffect, useRef, useState } from "react";
import type { ApiClient, SendMessageInput } from "../../api";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { AppIcon } from "../../components/AppIcon";
import { errorText } from "../../lib/format";
import type {
  ConversationMembership,
  Message,
  RetainedSenderLabel,
  User
} from "../../types";
import { MentionPicker } from "./MentionPicker";
import { MessageItem } from "./MessageItem";
import "./ThreadDrawer.css";
import {
  attachmentLabel,
  useThreadAttachments
} from "./useThreadAttachments";
import { CompositionToolbar } from "./CompositionToolbar";
import { DraftSyncNotice } from "./DraftSyncNotice";
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
  onSend,
  onMessageUpdated,
  onReport
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
  onMessageUpdated?: (message: Message) => void;
  onReport?: (message: Message) => void;
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
  const messagesByIdRef = useRef(new Map<string, Message>());
  messagesByIdRef.current = new Map((root ? [root, ...replies] : replies).map((message) => [message.id, message]));
  const liveMessagesRef = useRef(liveMessages);
  liveMessagesRef.current = liveMessages;
  const pendingReactionsRef = useRef(new Set<string>());
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
    draftSync,
    failedSend,
    initializeDraft,
    mentionedUserIds,
    retrySend,
    send,
    sending,
    setMentionedUserIds
  } = useThreadComposer({
    api,
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
      requestGenerationRef.current += 1;
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

  function updateMessage(message: Message) {
    // Socket removals can arrive before an earlier active edit's HTTP response.
    // Read the latest live props as well as state, including before its effect runs.
    const updated = retainRemovedMessage(
      liveMessagesRef.current.find((entry) => entry.id === message.id),
      retainRemovedMessage(messagesByIdRef.current.get(message.id), message)
    );
    messagesByIdRef.current.set(message.id, updated);
    setRoot((current) => current?.id === message.id ? retainRemovedMessage(current, updated) : current);
    setReplies((current) => current.map((reply) => reply.id === message.id ? retainRemovedMessage(reply, updated) : reply));
    onMessageUpdated?.(updated);
  }

  async function mutateMessage(operation: () => Promise<Message>) {
    const threadKey = activeThreadKeyRef.current;
    const generation = requestGenerationRef.current;
    // The existing API enforces membership, author ownership and the edit window.
    // MessageItem keeps the edit draft or delete confirmation open on denial.
    const updated = await operation();
    if (activeThreadKeyRef.current === threadKey && requestGenerationRef.current === generation) updateMessage(updated);
  }

  async function toggleReaction(message: Message, emoji: string) {
    const threadKey = activeThreadKeyRef.current;
    const generation = requestGenerationRef.current;
    const requestKey = `${threadKey}:${message.id}:${emoji}`;
    if (pendingReactionsRef.current.has(requestKey)) return;
    pendingReactionsRef.current.add(requestKey);
    const removing = message.reactions.some((reaction) => reaction.user_id === currentUserId && reaction.emoji === emoji);
    try {
      if (removing) await api.removeReaction(conversationId, message.id, emoji);
      else await api.addReaction(conversationId, message.id, emoji);
      if (activeThreadKeyRef.current !== threadKey || requestGenerationRef.current !== generation) return;
      const current = messagesByIdRef.current.get(message.id);
      if (!current) return;
      const reactions = current.reactions.filter((reaction) => !(reaction.user_id === currentUserId && reaction.emoji === emoji));
      if (!removing) reactions.push({ user_id: currentUserId, emoji });
      updateMessage({ ...current, reactions });
    } catch (reason: unknown) {
      if (activeThreadKeyRef.current === threadKey && requestGenerationRef.current === generation) setError(errorText(reason));
    } finally {
      pendingReactionsRef.current.delete(requestKey);
    }
  }

  function threadMessage(message: Message) {
    return <MessageItem key={message.id} idPrefix="thread-message" message={message} currentUserId={currentUserId} senderName={senderIdentifier(message.sender_user_id, false)} seenCount={0} focused={false} onAttachment={(attachment) => void openAttachment(attachment)} onReaction={(emoji) => void toggleReaction(message, emoji)} onEdit={(body) => mutateMessage(() => api.editMessage(message.id, body))} onDelete={() => mutateMessage(() => api.deleteMessage(message.id))} onReport={onReport ? () => onReport(message) : undefined} onSave={typeof api.saveMessage === "function" ? () => api.saveMessage(message.id) : undefined} />;
  }

  return (
    <div className="drawer-backdrop thread-backdrop">
      <section ref={dialogRef} className="thread-drawer" role="dialog" aria-modal="true" aria-labelledby="thread-title">
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
            <div className="thread-content">
            <ol className="thread-root thread-message-list" aria-label="Thread root">{threadMessage(root)}</ol>
            <div className="thread-divider"><span>{Math.max(root.thread_reply_count || 0, replies.length)} replies</span></div>
            {hasMore && <button className="button ghost compact thread-load" type="button" disabled={loadingOlder} onClick={() => void loadOlder()}>{loadingOlder ? "Loading…" : "Load older replies"}</button>}
            <ol className="thread-replies" aria-live="polite">
              {replies.map(threadMessage)}
            </ol>
            </div>
            <form className="thread-composer" aria-busy={sending || uploading} onSubmit={(event) => void send(event)}>
              {failedSend && <div className="failed-send" role="alert" style={{ gridColumn: "1 / -1" }}><span>Reply not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
              {pendingAttachments.length > 0 && <div className="pending-files" aria-label="Files being attached to this thread" style={{ gridColumn: "1 / -1" }}>{pendingAttachments.map(({ attachment, localName }) => { const unsafe = ["quarantined", "scan_failed"].includes(attachment.status); const ready = attachment.status === "ready"; return <span className={`file-chip attachment-${attachment.status}`} key={attachment.id}><span aria-hidden="true"><AppIcon className={ready || unsafe ? "" : "spin"} name={ready ? "check" : unsafe ? "triangleAlert" : "loader"} /></span><span>{localName}<small>{attachmentLabel(attachment)}</small></span><button type="button" aria-label={`Remove ${localName}`} onClick={() => removePendingAttachment(attachment)}><AppIcon name="x" /></button></span>; })}</div>}
              <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{attachmentAnnouncement}</p>
              <DraftSyncNotice sync={draftSync} />
              <MentionPicker members={members} currentUserId={currentUserId} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
              <CompositionToolbar value={composer} textareaId="thread-composer" disabled={sending} onChange={composerChanged} />
              <label htmlFor="thread-composer">Reply in thread</label>
              <textarea id="thread-composer" rows={3} value={composer} onChange={(event) => composerChanged(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} maxLength={65_535} disabled={sending} data-initial-focus />
              <label className={`attachment-button ${uploading ? "disabled" : ""}`}><input type="file" aria-label="Attach files to this thread" multiple disabled={uploading || sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" /><AppIcon name="paperclip" />{uploading ? "Uploading…" : "Attach"}</label>
              <span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span>
              <button className="button primary compact" type="submit" disabled={sending || uploading || !attachmentsReady || (!composer.trim() && pendingAttachments.length === 0)}>{sending ? "Sending…" : "Reply"}</button>
            </form>
          </>
        )}
      </section>
    </div>
  );
}

function retainRemovedMessage(current: Message | null | undefined, incoming: Message): Message {
  return current && current.status !== "active" && incoming.status === "active" ? current : incoming;
}

function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  const byId = new Map(current.map((message) => [message.id, message]));
  incoming.forEach((message) => byId.set(message.id, message));
  return [...byId.values()].sort(
    (left, right) => left.conversation_sequence - right.conversation_sequence
  );
}
