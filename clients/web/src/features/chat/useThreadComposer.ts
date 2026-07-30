import {
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import type {
  FormEvent,
  MutableRefObject
} from "react";
import type { SendMessageInput } from "../../api";
import {
  loadThreadDraft,
  storeThreadDraft
} from "../../lib/drafts";
import { clientMessageId, errorText } from "../../lib/format";
import type { Message } from "../../types";
import type { PendingThreadAttachment } from "./useThreadAttachments";

interface FailedThreadSend {
  input: SendMessageInput;
  draftSnapshot: string;
  error: string;
}

interface AttachmentReservation {
  fail: (abandonOrphans: boolean) => void;
  stale: () => boolean;
  succeed: () => void;
}

export function useThreadComposer({
  activeThreadKeyRef,
  attachmentsReady,
  clearPendingAttachments,
  conversationId,
  currentUserId,
  mergeReply,
  onSend,
  pendingAttachments,
  requestGenerationRef,
  reserveAttachmentsForSend,
  root,
  setError,
  targetMessageId,
  tenantId
}: {
  activeThreadKeyRef: MutableRefObject<string>;
  attachmentsReady: boolean;
  clearPendingAttachments: () => void;
  conversationId: string;
  currentUserId: string;
  mergeReply: (reply: Message) => void;
  onSend: (input: SendMessageInput) => Promise<Message>;
  pendingAttachments: PendingThreadAttachment[];
  requestGenerationRef: MutableRefObject<number>;
  reserveAttachmentsForSend: (
    attachmentIds: string[],
    threadKey: string,
    requestGeneration: number
  ) => AttachmentReservation;
  root: Message | null;
  setError: (error: string | null) => void;
  targetMessageId: string;
  tenantId: string;
}) {
  const [sending, setSending] = useState(false);
  const [composer, setComposer] = useState("");
  const composerRef = useRef("");
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [failedSend, setFailedSend] =
    useState<FailedThreadSend | null>(null);

  useEffect(() => {
    composerRef.current = "";
    setComposer("");
    setMentionedUserIds([]);
    setFailedSend(null);
    setSending(false);
  }, [conversationId, targetMessageId]);

  const initializeDraft = useCallback((rootId: string) => {
    const savedDraft = loadThreadDraft(
      tenantId,
      currentUserId,
      conversationId,
      rootId
    );
    composerRef.current = savedDraft;
    setComposer(savedDraft);
  }, [conversationId, currentUserId, tenantId]);

  useEffect(() => {
    if (!root) return;
    storeThreadDraft(
      tenantId,
      currentUserId,
      conversationId,
      root.id,
      composer
    );
  }, [composer, conversationId, currentUserId, root?.id, tenantId]);

  async function sendInput(
    input: SendMessageInput,
    draftSnapshot: string
  ) {
    const threadKey = activeThreadKeyRef.current;
    const requestGeneration = requestGenerationRef.current;
    const rootId = root?.id;
    const attachmentReservation = reserveAttachmentsForSend(
      input.attachment_ids || [],
      threadKey,
      requestGeneration
    );
    let reply: Message;
    try {
      reply = await onSend(input);
    } catch (reason: unknown) {
      attachmentReservation.fail(attachmentReservation.stale());
      throw reason;
    }
    attachmentReservation.succeed();
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
    ) {
      return reply;
    }
    mergeReply(reply);
    composerRef.current = "";
    setComposer("");
    setMentionedUserIds([]);
    clearPendingAttachments();
    setFailedSend(null);
    return reply;
  }

  async function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = composer.trim();
    if (!root || !body || sending) return;
    if (!attachmentsReady) {
      setError(
        "Wait for every attachment safety scan to finish or remove the file."
      );
      return;
    }
    const input: SendMessageInput = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: pendingAttachments.map(
        ({ attachment }) => attachment.id
      ),
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

  function composerChanged(value: string) {
    composerRef.current = value;
    setComposer(value);
  }

  return {
    composer,
    composerChanged,
    failedSend,
    initializeDraft,
    mentionedUserIds,
    retrySend,
    send,
    sending,
    setMentionedUserIds
  };
}
