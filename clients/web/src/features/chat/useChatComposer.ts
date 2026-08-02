import {
  useEffect,
  useRef,
  useState
} from "react";
import type {
  ChangeEvent,
  FormEvent,
  MutableRefObject
} from "react";
import type { SendMessageInput } from "../../api";
import { clientMessageId, errorText } from "../../lib/format";
import { loadDraft, storeDraft } from "../../lib/drafts";
import type { Message, MessageMetadata, Session } from "../../types";
import type { AttachmentSendReservation } from "./useChatAttachments";

export interface FailedChatSend {
  input: SendMessageInput;
  body: string;
  draftSnapshot: string;
  error: string;
}

interface UseChatComposerOptions {
  activeConversationId: string | null;
  attachmentsReady: boolean;
  clearPendingAttachments: () => void;
  forceScrollToLatestRef: MutableRefObject<boolean>;
  onConversationChanged: () => void;
  messageMetadata?: MessageMetadata;
  onMetadataSent?: () => void;
  readyAttachmentIds: string[];
  receiveMessages: (messages: Message[]) => void;
  reserveAttachmentsForSend: (
    attachmentIds: string[]
  ) => AttachmentSendReservation;
  resetAttachments: () => void;
  sendCommand: (
    conversationId: string,
    input: SendMessageInput
  ) => Promise<Message>;
  session: Session | null;
  setConversationTyping: (typing: boolean) => void;
  setError: (error: string | null) => void;
  updateConversationSummaries: (messages: Message[]) => void;
}

export function useChatComposer({
  activeConversationId,
  attachmentsReady,
  clearPendingAttachments,
  forceScrollToLatestRef,
  onConversationChanged,
  messageMetadata,
  onMetadataSent,
  readyAttachmentIds,
  receiveMessages,
  reserveAttachmentsForSend,
  resetAttachments,
  sendCommand,
  session,
  setConversationTyping,
  setError,
  updateConversationSummaries
}: UseChatComposerOptions) {
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [failedSend, setFailedSend] = useState<FailedChatSend | null>(null);
  const [replyTo, setReplyTo] = useState<Message | null>(null);
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const activeConversationIdRef = useRef(activeConversationId);
  activeConversationIdRef.current = activeConversationId;
  const composerRef = useRef(composer);
  const typingTimerRef = useRef<number | null>(null);
  const draftConversationRef = useRef<string | null>(null);
  const tenantId = session?.tenant.id;
  const userId = session?.user.id;

  useEffect(() => {
    const previous = draftConversationRef.current;
    if (previous && tenantId && userId) {
      storeDraft(
        tenantId,
        userId,
        previous,
        composerRef.current
      );
    }
    draftConversationRef.current = activeConversationId;
    forceScrollToLatestRef.current = true;
    const nextComposer =
      activeConversationId && tenantId && userId
        ? loadDraft(
            tenantId,
            userId,
            activeConversationId
          )
        : "";
    composerRef.current = nextComposer;
    setComposer(nextComposer);
    setReplyTo(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    setSending(false);
    resetAttachments();
    onConversationChanged();
  }, [
    activeConversationId,
    forceScrollToLatestRef,
    onConversationChanged,
    resetAttachments,
    tenantId,
    userId
  ]);

  useEffect(() => {
    if (activeConversationId && tenantId && userId) {
      storeDraft(
        tenantId,
        userId,
        activeConversationId,
        composer
      );
    }
  }, [activeConversationId, composer, tenantId, userId]);

  useEffect(
    () => () => {
      if (typingTimerRef.current) {
        window.clearTimeout(typingTimerRef.current);
      }
    },
    []
  );

  async function sendInput(
    input: SendMessageInput,
    draftSnapshot: string
  ) {
    if (!activeConversationId) return;
    const conversationId = activeConversationId;
    const attachmentReservation = reserveAttachmentsForSend(
      input.attachment_ids || []
    );
    let message: Message;
    try {
      message = await sendCommand(conversationId, input);
    } catch (reason: unknown) {
      attachmentReservation.fail(
        activeConversationIdRef.current !== conversationId
      );
      throw reason;
    }
    attachmentReservation.succeed();
    if (
      tenantId &&
      userId &&
      loadDraft(tenantId, userId, conversationId) ===
        draftSnapshot
    ) {
      storeDraft(tenantId, userId, conversationId, "");
    }
    if (
      activeConversationIdRef.current !== conversationId ||
      composerRef.current !== draftSnapshot
    ) {
      updateConversationSummaries([message]);
      return;
    }
    forceScrollToLatestRef.current = true;
    receiveMessages([message]);
    composerRef.current = "";
    setComposer("");
    clearPendingAttachments();
    setReplyTo(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    onMetadataSent?.();
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!activeConversationId || sending) return;
    const body = composer.trim();
    if (!body) {
      setError("Write a message before sending.");
      return;
    }
    if (!attachmentsReady) {
      setError(
        "Wait for every attachment safety scan to finish or remove the file."
      );
      return;
    }
    const input: SendMessageInput = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: readyAttachmentIds,
      reply_to_message_id: replyTo?.id || null,
      mentioned_user_ids: mentionedUserIds,
      metadata: combinedMessageMetadata(body, messageMetadata)
    };
    setSending(true);
    setError(null);
    setConversationTyping(false);
    const conversationId = activeConversationId;
    try {
      await sendInput(input, composer);
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        const message = errorText(reason);
        setFailedSend({
          input,
          body,
          draftSnapshot: composer,
          error: message
        });
        setError(message);
      }
    } finally {
      if (activeConversationIdRef.current === conversationId) {
        setSending(false);
      }
    }
  }

  async function retrySend() {
    if (!failedSend || sending) return;
    setSending(true);
    setError(null);
    const conversationId = activeConversationId;
    try {
      await sendInput(failedSend.input, failedSend.draftSnapshot);
    } catch (reason: unknown) {
      if (activeConversationIdRef.current === conversationId) {
        const message = errorText(reason);
        setFailedSend({ ...failedSend, error: message });
        setError(message);
      }
    } finally {
      if (activeConversationIdRef.current === conversationId) {
        setSending(false);
      }
    }
  }

  async function sendThreadReply(
    input: SendMessageInput
  ): Promise<Message> {
    if (!activeConversationId) {
      throw new Error("Select a conversation before replying.");
    }
    const conversationId = activeConversationId;
    const message = await sendCommand(conversationId, input);
    if (activeConversationIdRef.current === conversationId) {
      forceScrollToLatestRef.current = true;
      receiveMessages([message]);
    } else {
      updateConversationSummaries([message]);
    }
    return message;
  }

  function composerChanged(event: ChangeEvent<HTMLTextAreaElement>) {
    composerRef.current = event.target.value;
    setComposer(event.target.value);
    setConversationTyping(true);
    if (typingTimerRef.current) {
      window.clearTimeout(typingTimerRef.current);
    }
    typingTimerRef.current = window.setTimeout(
      () => setConversationTyping(false),
      1_500
    );
  }

  return {
    activeConversationIdRef,
    composer,
    composerChanged,
    failedSend,
    mentionedUserIds,
    replyTo,
    retrySend,
    sendMessage,
    sendThreadReply,
    sending,
    setMentionedUserIds,
    setReplyTo
  };
}

function combinedMessageMetadata(
  body: string,
  supplied?: MessageMetadata
): MessageMetadata | undefined {
  const links = Array.from(
    new Set(body.match(/https:\/\/[^\s<>]+/gi) ?? [])
  )
    .slice(0, 5)
    .map((url) => ({ url }));
  const metadata: MessageMetadata = { ...(supplied ?? {}) };
  if (links.length > 0) metadata.links = links;
  return Object.keys(metadata).length > 0 ? metadata : undefined;
}
