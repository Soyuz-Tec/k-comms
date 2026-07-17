import { useEffect, useMemo, useState } from "react";
import type { ChangeEvent, FormEvent } from "react";
import { downloadUrl, sha256, uploadToPresignedTarget } from "../../api";
import type { ApiClient, SendMessageInput } from "../../api";
import { useModalDialog } from "../../components/useModalDialog";
import { loadThreadDraft, storeThreadDraft } from "../../lib/drafts";
import { clientMessageId, errorText, formatBytes, formatTime } from "../../lib/format";
import type { Attachment, ConversationMembership, Message, User } from "../../types";
import { MentionPicker } from "./MentionPicker";

interface PendingAttachment {
  attachment: Attachment;
  localName: string;
}

interface FailedSend {
  input: SendMessageInput;
  error: string;
}

export function ThreadDrawer({
  api,
  tenantId,
  conversationId,
  targetMessageId,
  currentUserId,
  maxAttachmentBytes,
  members,
  users,
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
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [composer, setComposer] = useState("");
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [failedSend, setFailedSend] = useState<FailedSend | null>(null);
  const [error, setError] = useState<string | null>(null);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const dialogRef = useModalDialog(onClose);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setRoot(null);
    setReplies([]);
    setComposer("");
    setMentionedUserIds([]);
    setPendingAttachments([]);
    setFailedSend(null);
    setError(null);
    void api
      .messageThread(conversationId, targetMessageId)
      .then((thread) => {
        if (!current) return;
        setComposer(loadThreadDraft(tenantId, currentUserId, conversationId, thread.data.root.id));
        setRoot(thread.data.root);
        setReplies(thread.data.replies);
        setHasMore(thread.page.has_more);
        setBeforeSequence(thread.page.next_before_sequence);
      })
      .catch((reason: unknown) => current && setError(errorText(reason)))
      .finally(() => current && setLoading(false));
    return () => { current = false; };
  }, [api, conversationId, currentUserId, targetMessageId, tenantId]);

  useEffect(() => {
    if (!root) return;
    storeThreadDraft(tenantId, currentUserId, conversationId, root.id, composer);
  }, [composer, conversationId, currentUserId, root?.id, tenantId]);

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
    setLoadingOlder(true);
    setError(null);
    try {
      const thread = await api.messageThread(conversationId, root.id, beforeSequence);
      setReplies((current) => mergeMessages(thread.data.replies, current));
      setHasMore(thread.page.has_more);
      setBeforeSequence(thread.page.next_before_sequence);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setLoadingOlder(false);
    }
  }

  async function sendInput(input: SendMessageInput) {
    const reply = await onSend(input);
    setReplies((current) => mergeMessages(current, [reply]));
    setComposer("");
    if (root) storeThreadDraft(tenantId, currentUserId, conversationId, root.id, "");
    setMentionedUserIds([]);
    setPendingAttachments([]);
    setFailedSend(null);
  }

  async function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = composer.trim();
    if (!root || !body || sending) return;
    if (pendingAttachments.some(({ attachment }) => attachment.status !== "ready")) {
      setError("Wait for every attachment safety scan to finish or remove the file.");
      return;
    }
    const input: SendMessageInput = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: pendingAttachments.map(({ attachment }) => attachment.id),
      mentioned_user_ids: mentionedUserIds,
      reply_to_message_id: root.id
    };
    setSending(true);
    setError(null);
    try {
      await sendInput(input);
    } catch (reason: unknown) {
      setFailedSend({ input, error: errorText(reason) });
    } finally {
      setSending(false);
    }
  }

  async function retrySend() {
    if (!failedSend || sending) return;
    setSending(true);
    setError(null);
    try {
      await sendInput(failedSend.input);
    } catch (reason: unknown) {
      setFailedSend({ ...failedSend, error: errorText(reason) });
    } finally {
      setSending(false);
    }
  }

  async function monitorAttachment(id: string) {
    for (let attempt = 0; attempt < 45; attempt += 1) {
      await delay(1_000);
      try {
        const response = await api.attachmentStatus(id);
        const attachment = response.data;
        setPendingAttachments((current) => current.map((item) => item.attachment.id === id ? { ...item, attachment } : item));
        if (attachment.status === "ready") return;
        if (["quarantined", "scan_failed", "deleted"].includes(attachment.status)) {
          setError(`${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`);
          return;
        }
      } catch (reason: unknown) {
        if (attempt === 44) setError(errorText(reason));
      }
    }
    setError("Attachment scanning is taking longer than expected. You can remove the file and retry later.");
  }

  async function filesSelected(event: ChangeEvent<HTMLInputElement>) {
    const selected = [...(event.target.files || [])];
    event.target.value = "";
    if (selected.length === 0) return;
    setUploading(true);
    setError(null);
    try {
      for (const file of selected) {
        if (!maxAttachmentBytes) throw new Error("The server did not provide an attachment size limit");
        if (file.size > maxAttachmentBytes) throw new Error(`${file.name} exceeds the ${formatAttachmentLimit(maxAttachmentBytes)} limit`);
        const intent = await api.createAttachment(file, await sha256(file));
        await uploadToPresignedTarget(intent.upload, file);
        const attachment = await api.completeAttachment(intent.data.id);
        setPendingAttachments((current) => [...current, { attachment, localName: file.name }]);
        if (attachment.status !== "ready") void monitorAttachment(attachment.id);
      }
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setUploading(false);
    }
  }

  async function openAttachment(attachment: Attachment) {
    if (attachment.status !== "ready") {
      setError("This attachment is not available until its safety scan passes.");
      return;
    }
    setError(null);
    try {
      const response = await api.attachmentDownload(attachment.id);
      const url = downloadUrl(response.download);
      if (!url) throw new Error("The server did not return an approved HTTPS download URL");
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  const attachmentsReady = pendingAttachments.every(({ attachment }) => attachment.status === "ready");
  const attachmentAnnouncement = pendingAttachments
    .map(({ attachment, localName }) => `${localName}: ${attachmentLabel(attachment)}`)
    .join(". ");

  return (
    <div className="drawer-backdrop thread-backdrop">
      <aside ref={dialogRef} className="thread-drawer" role="dialog" aria-modal="true" aria-labelledby="thread-title">
        <header>
          <div><span className="eyebrow">Conversation thread</span><h2 id="thread-title">Thread</h2></div>
          <button className="icon-button" type="button" aria-label="Close thread" onClick={onClose}>×</button>
        </header>
        {error && <div className="form-error" role="alert">{error}</div>}
        {loading ? <div className="inline-loading" aria-busy="true"><span className="spinner" aria-hidden="true" />Loading thread…</div> : root && (
          <>
            <ThreadMessage message={root} user={usersById.get(root.sender_user_id)} currentUserId={currentUserId} onAttachment={(attachment) => void openAttachment(attachment)} root />
            <div className="thread-divider"><span>{Math.max(root.thread_reply_count || 0, replies.length)} replies</span></div>
            {hasMore && <button className="button ghost compact thread-load" type="button" disabled={loadingOlder} onClick={() => void loadOlder()}>{loadingOlder ? "Loading…" : "Load older replies"}</button>}
            <ol className="thread-replies" aria-live="polite">
              {replies.map((message) => <ThreadMessage key={message.id} message={message} user={usersById.get(message.sender_user_id)} currentUserId={currentUserId} onAttachment={(attachment) => void openAttachment(attachment)} />)}
            </ol>
            <form className="thread-composer" aria-busy={sending || uploading} onSubmit={(event) => void send(event)}>
              {failedSend && <div className="failed-send" role="alert" style={{ gridColumn: "1 / -1" }}><span>Reply not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
              {pendingAttachments.length > 0 && <div className="pending-files" aria-label="Files being attached to this thread" style={{ gridColumn: "1 / -1" }}>{pendingAttachments.map(({ attachment, localName }) => <span className={`file-chip attachment-${attachment.status}`} key={attachment.id}><span aria-hidden="true">{attachment.status === "ready" ? "✓" : ["quarantined", "scan_failed"].includes(attachment.status) ? "!" : "…"}</span><span>{localName}<small>{attachmentLabel(attachment)}</small></span><button type="button" aria-label={`Remove ${localName}`} onClick={() => setPendingAttachments((current) => current.filter((item) => item.attachment.id !== attachment.id))}>×</button></span>)}</div>}
              <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{attachmentAnnouncement}</p>
              <MentionPicker members={members} currentUserId={currentUserId} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
              <label htmlFor="thread-composer">Reply in thread</label>
              <textarea id="thread-composer" rows={3} value={composer} onChange={(event) => setComposer(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} maxLength={65_535} disabled={sending} data-initial-focus />
              <label className={`attachment-button ${uploading ? "disabled" : ""}`}><input type="file" aria-label="Attach files to this thread" multiple disabled={uploading || sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" /><span aria-hidden="true">＋</span>{uploading ? "Uploading…" : "Attach"}</label>
              <span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span>
              <button className="button primary compact" type="submit" disabled={sending || uploading || !attachmentsReady || !composer.trim()}>{sending ? "Sending…" : "Reply"}</button>
            </form>
          </>
        )}
      </aside>
    </div>
  );
}

function ThreadMessage({ message, user, currentUserId, onAttachment, root = false }: { message: Message; user?: User; currentUserId: string; onAttachment: (attachment: Attachment) => void; root?: boolean }) {
  return (
    <article className={`thread-message ${root ? "thread-root" : ""}`}>
      <header><strong>{message.sender_user_id === currentUserId ? "You" : user?.display_name || "Unknown user"}</strong><time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time></header>
      <p className={message.status === "active" ? "" : "removed"}>{message.status === "active" ? message.body : "Message removed"}</p>
      {message.attachments.length > 0 && <div className="message-attachments">{message.attachments.map((attachment) => <ThreadAttachment key={attachment.id} attachment={attachment} onOpen={onAttachment} />)}</div>}
    </article>
  );
}

function ThreadAttachment({ attachment, onOpen }: { attachment: Attachment; onOpen: (attachment: Attachment) => void }) {
  const ready = attachment.status === "ready";
  const unsafe = attachment.status === "quarantined" || attachment.status === "scan_failed";
  return <button type="button" disabled={!ready} className={unsafe ? "unsafe-attachment" : ""} onClick={() => onOpen(attachment)}><span aria-hidden="true">{ready ? "▤" : unsafe ? "!" : "…"}</span><span><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)} · {attachmentLabel(attachment)}</small></span></button>;
}

function attachmentLabel(attachment: Attachment): string {
  if (attachment.status === "ready") return "Safety scan passed";
  if (attachment.status === "quarantined") return "Quarantined";
  if (attachment.status === "scan_failed") return "Scan failed";
  if (attachment.status === "deleted") return "Deleted";
  return "Safety scan pending";
}

function formatAttachmentLimit(value: number): string {
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(value % 1_000_000 === 0 ? 0 : 1)} MB` : `${Math.ceil(value / 1_000)} KB`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  const byId = new Map(current.map((message) => [message.id, message]));
  incoming.forEach((message) => byId.set(message.id, message));
  return [...byId.values()].sort(
    (left, right) => left.conversation_sequence - right.conversation_sequence
  );
}
