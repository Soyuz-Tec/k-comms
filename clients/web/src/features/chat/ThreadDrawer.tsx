import { useEffect, useMemo, useRef, useState } from "react";
import type { ChangeEvent, FormEvent } from "react";
import { downloadUrl, sha256, uploadToPresignedTarget } from "../../api";
import type { ApiClient, SendMessageInput } from "../../api";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { AppIcon } from "../../components/AppIcon";
import { loadThreadDraft, storeThreadDraft } from "../../lib/drafts";
import { clientMessageId, errorText, formatBytes, formatTime } from "../../lib/format";
import {
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantIdentifier,
  retainedSenderLabelMap,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import type {
  Attachment,
  ConversationMembership,
  Message,
  RetainedSenderLabel,
  User
} from "../../types";
import { MentionPicker } from "./MentionPicker";

interface PendingAttachment {
  attachment: Attachment;
  localName: string;
}

interface FailedSend {
  input: SendMessageInput;
  draftSnapshot: string;
  error: string;
}

const SENDER_LABEL_REFRESH_DELAYS_MS = [30_000, 60_000, 120_000, 300_000] as const;

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
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [composer, setComposer] = useState("");
  const composerRef = useRef("");
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [failedSend, setFailedSend] = useState<FailedSend | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retainedSenderLabelsById, setRetainedSenderLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const retainedSenderLabelsByIdRef = useRef(retainedSenderLabelsById);
  const [knownMemberLabelsById, setKnownMemberLabelsById] = useState(
    () => new Map<string, ParticipantIdentity>()
  );
  const activeThreadKeyRef = useRef(`${conversationId}:${targetMessageId}`);
  activeThreadKeyRef.current = `${conversationId}:${targetMessageId}`;
  const requestGenerationRef = useRef(0);
  const pendingAttachmentIdsRef = useRef(new Set<string>());
  const sendingAttachmentIdsRef = useRef(new Set<string>());
  const senderLabelRefreshInFlightRef = useRef(false);
  const senderLabelRefreshGenerationRef = useRef(0);
  const threadSenderMessageIdsRef = useRef<{
    threadKey: string;
    messageIds: string[];
  }>({
    threadKey: `${conversationId}:${targetMessageId}`,
    messageIds: []
  });
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const activeMembersById = useMemo(
    () => new Map(members.map(({ user }) => [user.id, user])),
    [members]
  );
  const effectiveRetainedSenderLabelsById = useMemo(
    () => mergeRetainedSenderLabelMaps(
      new Map(retainedSenderLabels || []),
      [...retainedSenderLabelsById.values()]
    ),
    [retainedSenderLabels, retainedSenderLabelsById]
  );
  const visibleSenderIdentities = useMemo(() => {
    const identitiesById = new Map<string, ParticipantIdentity>();
    for (const message of root ? [root, ...replies] : replies) {
      const identity = resolveVisibleSenderIdentity(
        message.sender_user_id,
        activeMembersById,
        effectiveRetainedSenderLabelsById,
        [usersById, knownMemberLabelsById]
      );
      if (identity) identitiesById.set(identity.id, identity);
    }
    return identitiesById;
  }, [
    activeMembersById,
    effectiveRetainedSenderLabelsById,
    knownMemberLabelsById,
    replies,
    root,
    usersById
  ]);
  const duplicateVisibleSenderNames = useMemo(
    () => duplicateParticipantNames(visibleSenderIdentities.values()),
    [visibleSenderIdentities]
  );
  const dialogRef = useModalDialog(onClose);

  useEffect(() => {
    retainedSenderLabelsByIdRef.current = retainedSenderLabelsById;
  }, [retainedSenderLabelsById]);

  useEffect(() => {
    setKnownMemberLabelsById(
      new Map(members.map(({ user }) => [user.id, user]))
    );
  }, [conversationId, targetMessageId]);

  useEffect(() => {
    setKnownMemberLabelsById((current) => {
      const next = new Map(current);
      for (const { user } of members) next.set(user.id, user);
      return next;
    });
  }, [members]);

  useEffect(() => {
    let current = true;
    const requestGeneration = ++requestGenerationRef.current;
    setLoading(true);
    setLoadingOlder(false);
    setRoot(null);
    setReplies([]);
    composerRef.current = "";
    setComposer("");
    setMentionedUserIds([]);
    setPendingAttachments([]);
    setFailedSend(null);
    setSending(false);
    setUploading(false);
    setError(null);
    setRetainedSenderLabelsById(new Map());
    void api
      .messageThread(conversationId, targetMessageId)
      .then((thread) => {
        if (!current || requestGenerationRef.current !== requestGeneration) return;
        const savedDraft = loadThreadDraft(
          tenantId,
          currentUserId,
          conversationId,
          thread.data.root.id
        );
        composerRef.current = savedDraft;
        setComposer(savedDraft);
        setRoot(thread.data.root);
        setReplies(thread.data.replies);
        setHasMore(thread.page.has_more);
        setBeforeSequence(thread.page.next_before_sequence);
        setRetainedSenderLabelsById(
          retainedSenderLabelMap(thread.included?.sender_labels)
        );
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
      for (const id of pendingAttachmentIdsRef.current) {
        if (sendingAttachmentIdsRef.current.has(id)) continue;
        pendingAttachmentIdsRef.current.delete(id);
        void api.abandonAttachment(id).catch(() => undefined);
      }
    };
  }, [api, conversationId, currentUserId, targetMessageId, tenantId]);

  useEffect(() => {
    if (!root) return;
    storeThreadDraft(tenantId, currentUserId, conversationId, root.id, composer);
  }, [composer, conversationId, currentUserId, root?.id, tenantId]);

  useEffect(() => {
    const messageIdBySender = new Map<string, string>();
    for (const message of root ? [root, ...replies] : replies) {
      if (!messageIdBySender.has(message.sender_user_id)) {
        messageIdBySender.set(message.sender_user_id, message.id);
      }
    }
    threadSenderMessageIdsRef.current = {
      threadKey: `${conversationId}:${targetMessageId}`,
      messageIds: [...messageIdBySender.values()]
    };
  }, [conversationId, replies, root, targetMessageId]);

  useEffect(() => {
    const threadKey = `${conversationId}:${targetMessageId}`;
    const refreshGeneration = ++senderLabelRefreshGenerationRef.current;
    let current = true;
    let timeout: number | undefined;
    let backoffIndex = 0;

    const scheduleRefresh = () => {
      if (!current || document.hidden) return;
      if (timeout !== undefined) window.clearTimeout(timeout);
      timeout = window.setTimeout(() => {
        timeout = undefined;
        void refreshSenderLabels();
      }, SENDER_LABEL_REFRESH_DELAYS_MS[backoffIndex]);
    };

    const refreshSenderLabels = async () => {
      if (document.hidden) return;
      const messageSnapshot = threadSenderMessageIdsRef.current;
      if (
        messageSnapshot.threadKey !== threadKey ||
        messageSnapshot.messageIds.length === 0
      ) return;
      if (senderLabelRefreshInFlightRef.current) {
        scheduleRefresh();
        return;
      }
      senderLabelRefreshInFlightRef.current = true;
      let labelsChanged = false;
      try {
        const labels = await api.messageSenderLabels(
          conversationId,
          messageSnapshot.messageIds
        );
        if (
          !current ||
          senderLabelRefreshGenerationRef.current !== refreshGeneration ||
          activeThreadKeyRef.current !== threadKey
        ) return;
        if (labels.length > 0) {
          const existing = retainedSenderLabelsByIdRef.current;
          const merged = mergeRetainedSenderLabels(existing, labels);
          labelsChanged = !retainedSenderLabelMapsEqual(existing, merged);
          if (labelsChanged) {
            retainedSenderLabelsByIdRef.current = merged;
            setRetainedSenderLabelsById(merged);
          }
        }
      } catch {
        // This reconciliation is best effort and retries with bounded backoff.
      } finally {
        senderLabelRefreshInFlightRef.current = false;
        if (
          current &&
          senderLabelRefreshGenerationRef.current === refreshGeneration &&
          activeThreadKeyRef.current === threadKey
        ) {
          backoffIndex = labelsChanged
            ? 0
            : Math.min(
                backoffIndex + 1,
                SENDER_LABEL_REFRESH_DELAYS_MS.length - 1
              );
          scheduleRefresh();
        }
      }
    };

    const visibilityChanged = () => {
      if (!current) return;
      if (document.hidden) {
        if (timeout !== undefined) window.clearTimeout(timeout);
        timeout = undefined;
        return;
      }
      backoffIndex = 0;
      scheduleRefresh();
    };

    document.addEventListener("visibilitychange", visibilityChanged);
    scheduleRefresh();
    return () => {
      current = false;
      senderLabelRefreshGenerationRef.current += 1;
      if (timeout !== undefined) window.clearTimeout(timeout);
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [api, conversationId, replies, root, targetMessageId]);

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
      setRetainedSenderLabelsById((current) =>
        mergeRetainedSenderLabels(current, thread.included?.sender_labels)
      );
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

  async function sendInput(input: SendMessageInput, draftSnapshot: string) {
    const threadKey = activeThreadKeyRef.current;
    const requestGeneration = requestGenerationRef.current;
    const rootId = root?.id;
    const attachmentIds = new Set(input.attachment_ids || []);
    for (const id of attachmentIds) sendingAttachmentIdsRef.current.add(id);
    let reply: Message;
    try {
      reply = await onSend(input);
    } catch (reason: unknown) {
      for (const id of attachmentIds) sendingAttachmentIdsRef.current.delete(id);
      if (
        activeThreadKeyRef.current !== threadKey ||
        requestGenerationRef.current !== requestGeneration
      ) {
        for (const id of attachmentIds) {
          pendingAttachmentIdsRef.current.delete(id);
          void api.abandonAttachment(id).catch(() => undefined);
        }
      }
      throw reason;
    }
    for (const id of attachmentIds) {
      sendingAttachmentIdsRef.current.delete(id);
      pendingAttachmentIdsRef.current.delete(id);
    }
    if (
      rootId &&
      loadThreadDraft(
        tenantId,
        currentUserId,
        conversationId,
        rootId
      ) === draftSnapshot
    ) {
      storeThreadDraft(
        tenantId,
        currentUserId,
        conversationId,
        rootId,
        ""
      );
    }
    if (
      activeThreadKeyRef.current !== threadKey ||
      composerRef.current !== draftSnapshot
    ) return reply;
    setReplies((current) => mergeMessages(current, [reply]));
    composerRef.current = "";
    setComposer("");
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
    const threadKey = activeThreadKeyRef.current;
    const requestGeneration = requestGenerationRef.current;
    try {
      await sendInput(input, composer);
    } catch (reason: unknown) {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setFailedSend({
          input,
          draftSnapshot: composer,
          error: errorText(reason)
        });
      }
    } finally {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setSending(false);
      }
    }
  }

  async function retrySend() {
    if (!failedSend || sending) return;
    setSending(true);
    setError(null);
    const threadKey = activeThreadKeyRef.current;
    const requestGeneration = requestGenerationRef.current;
    try {
      await sendInput(failedSend.input, failedSend.draftSnapshot);
    } catch (reason: unknown) {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setFailedSend({ ...failedSend, error: errorText(reason) });
      }
    } finally {
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setSending(false);
      }
    }
  }

  async function monitorAttachment(
    id: string,
    threadKey: string,
    requestGeneration: number
  ) {
    for (let attempt = 0; attempt < 45; attempt += 1) {
      await delay(1_000);
      if (
        activeThreadKeyRef.current !== threadKey ||
        requestGenerationRef.current !== requestGeneration
      ) return;
      try {
        const response = await api.attachmentStatus(id);
        if (
          activeThreadKeyRef.current !== threadKey ||
          requestGenerationRef.current !== requestGeneration
        ) return;
        const attachment = response.data;
        setPendingAttachments((current) => current.map((item) => item.attachment.id === id ? { ...item, attachment } : item));
        if (attachment.status === "ready") return;
        if (["quarantined", "scan_failed", "deleted"].includes(attachment.status)) {
          setError(`${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`);
          return;
        }
      } catch (reason: unknown) {
        if (
          attempt === 44 &&
          activeThreadKeyRef.current === threadKey &&
          requestGenerationRef.current === requestGeneration
        ) setError(errorText(reason));
      }
    }
    if (
      activeThreadKeyRef.current === threadKey &&
      requestGenerationRef.current === requestGeneration
    ) {
      setError("Attachment scanning is taking longer than expected. You can remove the file and retry later.");
    }
  }

  async function filesSelected(event: ChangeEvent<HTMLInputElement>) {
    const selected = [...(event.target.files || [])];
    event.target.value = "";
    if (selected.length === 0) return;
    const threadKey = activeThreadKeyRef.current;
    const requestGeneration = requestGenerationRef.current;
    setUploading(true);
    setError(null);
    try {
      for (const file of selected) {
        if (!maxAttachmentBytes) throw new Error("The server did not provide an attachment size limit");
        if (file.size > maxAttachmentBytes) throw new Error(`${file.name} exceeds the ${formatAttachmentLimit(maxAttachmentBytes)} limit`);
        const intent = await api.createAttachment(file, await sha256(file));
        if (
          activeThreadKeyRef.current !== threadKey ||
          requestGenerationRef.current !== requestGeneration
        ) {
          await api.abandonAttachment(intent.data.id).catch(() => undefined);
          return;
        }
        await uploadToPresignedTarget(intent.upload, file);
        if (
          activeThreadKeyRef.current !== threadKey ||
          requestGenerationRef.current !== requestGeneration
        ) {
          await api.abandonAttachment(intent.data.id).catch(() => undefined);
          return;
        }
        const attachment = await api.completeAttachment(intent.data.id);
        pendingAttachmentIdsRef.current.add(attachment.id);
        if (
          activeThreadKeyRef.current !== threadKey ||
          requestGenerationRef.current !== requestGeneration
        ) {
          pendingAttachmentIdsRef.current.delete(intent.data.id);
          await api.abandonAttachment(intent.data.id).catch(() => undefined);
          return;
        }
        setPendingAttachments((current) => [...current, { attachment, localName: file.name }]);
        if (attachment.status !== "ready") {
          void monitorAttachment(attachment.id, threadKey, requestGeneration);
        }
      }
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
        setUploading(false);
      }
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

  function removePendingAttachment(attachment: Attachment) {
    pendingAttachmentIdsRef.current.delete(attachment.id);
    setPendingAttachments((current) =>
      current.filter((item) => item.attachment.id !== attachment.id)
    );
    void api.abandonAttachment(attachment.id).catch(() => {
      if (
        activeThreadKeyRef.current ===
        `${conversationId}:${targetMessageId}`
      ) {
        setError("The removed file is still awaiting secure cleanup.");
      }
    });
  }

  const attachmentsReady = pendingAttachments.every(({ attachment }) => attachment.status === "ready");
  const attachmentAnnouncement = pendingAttachments
    .map(({ attachment, localName }) => `${localName}: ${attachmentLabel(attachment)}`)
    .join(". ");
  const senderIdentifier = (userId: string): string => {
    const identity = visibleSenderIdentities.get(userId);
    const resolvedIdentifier = identity
      ? participantIdentifier(identity, duplicateVisibleSenderNames)
      : "Unknown user";
    return userId === currentUserId
      ? `${resolvedIdentifier} (you)`
      : resolvedIdentifier;
  };

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
              <textarea id="thread-composer" rows={3} value={composer} onChange={(event) => { composerRef.current = event.target.value; setComposer(event.target.value); }} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} maxLength={65_535} disabled={sending} data-initial-focus />
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

function mergeRetainedSenderLabels(
  current: Map<string, RetainedSenderLabel>,
  incoming: RetainedSenderLabel[] | undefined
): Map<string, RetainedSenderLabel> {
  return mergeRetainedSenderLabelMaps(current, incoming);
}

function retainedSenderLabelMapsEqual(
  left: ReadonlyMap<string, RetainedSenderLabel>,
  right: ReadonlyMap<string, RetainedSenderLabel>
): boolean {
  if (left.size !== right.size) return false;
  for (const [id, label] of left) {
    const candidate = right.get(id);
    if (
      !candidate ||
      candidate.display_name !== label.display_name ||
      candidate.redacted !== label.redacted
    ) {
      return false;
    }
  }
  return true;
}
