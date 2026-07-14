import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ChangeEvent, FormEvent } from "react";
import { Link, useSearchParams } from "react-router-dom";
import type { CreateConversationInput, SendMessageInput } from "../../api";
import {
  downloadUrl,
  sha256,
  uploadToPresignedTarget
} from "../../api";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { ActionDialog } from "../../components/ActionDialog";
import {
  clientMessageId,
  conversationTitle,
  errorText
} from "../../lib/format";
import { loadDraft, storeDraft } from "../../lib/drafts";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  Attachment,
  ConnectionStatus,
  ConversationMembership,
  Message,
  ReactionEvent,
  ReadCursorEvent
} from "../../types";
import { ConversationDetails } from "./ConversationDetails";
import { ChannelBrowser } from "./ChannelBrowser";
import { CreateConversationForm } from "./CreateConversationForm";
import { MessageItem } from "./MessageItem";
import { MentionPicker } from "./MentionPicker";
import { SearchPanel } from "./SearchPanel";
import { ThreadDrawer } from "./ThreadDrawer";

interface PendingAttachment {
  attachment: Attachment;
  localName: string;
}

interface FailedSend {
  input: SendMessageInput;
  body: string;
  error: string;
}

interface FocusTarget {
  id: string;
  conversationId: string;
  sequence: number;
}

export function ChatPage() {
  const { api, session } = useSession();
  const {
    conversations,
    users,
    capabilities,
    loading: workspaceLoading,
    setError,
    setConversations,
    createConversation,
    refreshConversations
  } = useWorkspaceData();
  const onboardingStorageKey = session ? `k-comms:onboarding:${session.tenant.id}:${session.user.id}` : "k-comms:onboarding:anonymous";
  const [searchParams, setSearchParams] = useSearchParams();
  const activeConversationId = searchParams.get("conversation");
  const linkedMessageId = safeUuid(searchParams.get("message"));
  const [messages, setMessages] = useState<Message[]>([]);
  const [messagesLoading, setMessagesLoading] = useState(false);
  const [olderLoading, setOlderLoading] = useState(false);
  const [hasOlder, setHasOlder] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("offline");
  const [onlineUsers, setOnlineUsers] = useState(0);
  const [typingUsers, setTypingUsers] = useState<Set<string>>(() => new Set());
  const [readCursors, setReadCursors] = useState<Record<string, number>>({});
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [failedSend, setFailedSend] = useState<FailedSend | null>(null);
  const [replyTo, setReplyTo] = useState<Message | null>(null);
  const [threadTargetId, setThreadTargetId] = useState<string | null>(null);
  const [conversationMembers, setConversationMembers] = useState<ConversationMembership[]>([]);
  const [mentionedUserIds, setMentionedUserIds] = useState<string[]>([]);
  const [showCreateConversation, setShowCreateConversation] = useState(false);
  const [showSearch, setShowSearch] = useState(false);
  const [showDetails, setShowDetails] = useState(false);
  const [showBrowseChannels, setShowBrowseChannels] = useState(false);
  const [mobilePane, setMobilePane] = useState<"list" | "messages">("list");
  const [focusTarget, setFocusTarget] = useState<FocusTarget | null>(null);
  const [membershipVersion, setMembershipVersion] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const [reportTarget, setReportTarget] = useState<Message | null>(null);
  const [reporting, setReporting] = useState(false);
  const [reportError, setReportError] = useState<string | null>(null);
  const [contiguousSequence, setContiguousSequence] = useState(0);
  const [conversationQuery, setConversationQuery] = useState("");
  const [conversationKind, setConversationKind] = useState<"all" | "direct" | "group" | "channel">("all");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const [showOnboarding, setShowOnboarding] = useState(() => session ? readOnboardingPreference(onboardingStorageKey) : false);
  const [isMobile, setIsMobile] = useState(() => window.matchMedia?.("(max-width: 760px)").matches ?? false);

  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const contiguousSequenceRef = useRef(0);
  const futureSequencesRef = useRef<Set<number>>(new Set());
  const knownMessageIdsRef = useRef<Set<string>>(new Set());
  const nearBottomRef = useRef(true);
  const forceScrollToLatestRef = useRef(true);
  const typingTimerRef = useRef<number | null>(null);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const draftConversationRef = useRef<string | null>(null);
  const requestCatchUpRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia("(max-width: 760px)");
    const changed = () => setIsMobile(query.matches);
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, []);

  const activeConversation = useMemo(
    () => conversations.find(({ id }) => id === activeConversationId) || null,
    [activeConversationId, conversations]
  );
  const filteredConversations = useMemo(() => {
    const query = conversationQuery.trim().toLocaleLowerCase();
    return conversations.filter((conversation) => {
      if (conversationKind !== "all" && conversation.kind !== conversationKind) return false;
      if (unreadOnly && (conversation.unread_count || 0) === 0) return false;
      if (query && !conversationTitle(conversation).toLocaleLowerCase().includes(query)) return false;
      return true;
    });
  }, [conversationKind, conversationQuery, conversations, unreadOnly]);
  const usersById = useMemo(() => new Map(users.map((user) => [user.id, user])), [users]);
  const messagesById = useMemo(() => new Map(messages.map((message) => [message.id, message])), [messages]);

  const updateNearBottom = useCallback((nearBottom: boolean) => {
    nearBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
    if (nearBottom) setNewMessageCount(0);
  }, []);

  useEffect(() => {
    if (!activeConversationId) {
      setConversationMembers([]);
      return;
    }
    let current = true;
    setConversationMembers([]);
    void api
      .conversationMembers(activeConversationId)
      .then((members) => current && setConversationMembers(members))
      .catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [activeConversationId, api, setError]);

  useEffect(() => {
    if (workspaceLoading || conversations.length === 0) return;
    if (!activeConversationId || !conversations.some(({ id }) => id === activeConversationId)) {
      setSearchParams({ conversation: conversations[0]?.id || "" }, { replace: true });
    }
  }, [activeConversationId, conversations, setSearchParams, workspaceLoading]);

  useEffect(() => {
    const previous = draftConversationRef.current;
    if (previous && session) storeDraft(session.tenant.id, session.user.id, previous, composer);
    draftConversationRef.current = activeConversationId;
    knownMessageIdsRef.current.clear();
    nearBottomRef.current = true;
    forceScrollToLatestRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    setComposer(activeConversationId && session ? loadDraft(session.tenant.id, session.user.id, activeConversationId) : "");
    setReplyTo(null);
    setThreadTargetId(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    setPendingAttachments([]);
  }, [activeConversationId, session?.tenant.id, session?.user.id]);

  useEffect(() => {
    if (activeConversationId && linkedMessageId) setThreadTargetId(linkedMessageId);
  }, [activeConversationId, linkedMessageId]);

  useEffect(() => {
    if (activeConversationId && session) storeDraft(session.tenant.id, session.user.id, activeConversationId, composer);
  }, [activeConversationId, composer, session?.tenant.id, session?.user.id]);

  const receiveMessages = useCallback(
    (incoming: Message[]) => {
      if (incoming.length === 0) return;
      const newMessagesFromOthers = incoming.filter(
        (message) => !knownMessageIdsRef.current.has(message.id) && message.sender_user_id !== session?.user.id
      ).length;
      incoming.forEach((message) => knownMessageIdsRef.current.add(message.id));
      if (!nearBottomRef.current && newMessagesFromOthers > 0) {
        setNewMessageCount((count) => count + newMessagesFromOthers);
      }
      for (const message of incoming) {
        if (message.conversation_sequence > contiguousSequenceRef.current) {
          futureSequencesRef.current.add(message.conversation_sequence);
        }
      }
      let nextContiguous = contiguousSequenceRef.current;
      while (futureSequencesRef.current.delete(nextContiguous + 1)) {
        nextContiguous += 1;
      }
      if (nextContiguous !== contiguousSequenceRef.current) {
        contiguousSequenceRef.current = nextContiguous;
        setContiguousSequence(nextContiguous);
      }
      if (futureSequencesRef.current.size > 0) requestCatchUpRef.current();

      setMessages((current) => {
        const byId = new Map(current.map((message) => [message.id, message]));
        incoming.forEach((message) => {
          byId.set(message.id, message);
          if (message.thread_root_message_id) {
            const root = byId.get(message.thread_root_message_id);
            if (root) {
              byId.set(root.id, {
                ...root,
                thread_reply_count: Math.max(
                  root.thread_reply_count || 0,
                  message.thread_reply_count || 0
                )
              });
            }
          }
        });
        return [...byId.values()].sort(
          (left, right) => left.conversation_sequence - right.conversation_sequence
        );
      });

      const latest = Math.max(...incoming.map((message) => message.conversation_sequence));
      const conversationId = incoming[0]?.conversation_id;
      if (conversationId) {
        setConversations((current) =>
          current.map((conversation) => {
            if (conversation.id !== conversationId) return conversation;
            const latestSequence = Math.max(conversation.latest_sequence, latest);
            const shouldRemainUnread = document.visibilityState !== "visible" || !nearBottomRef.current;
            return {
              ...conversation,
              latest_sequence: latestSequence,
              unread_count: shouldRemainUnread
                ? Math.max(conversation.unread_count || 0, latestSequence - (conversation.last_read_sequence || 0))
                : conversation.unread_count
            };
          })
        );
      }
    },
    [session?.user.id, setConversations]
  );

  const applyReaction = useCallback((event: ReactionEvent, add: boolean) => {
    setMessages((current) =>
      current.map((message) => {
        if (message.id !== event.message_id) return message;
        const without = message.reactions.filter(
          (reaction) => !(reaction.user_id === event.user_id && reaction.emoji === event.emoji)
        );
        return { ...message, reactions: add ? [...without, { user_id: event.user_id, emoji: event.emoji }] : without };
      })
    );
  }, []);

  useEffect(() => {
    if (!session || !activeConversationId || !activeConversation) return;
    const conversationId = activeConversationId;
    const activeLatestSequence = activeConversation.latest_sequence;
    const realtimeDisabled = import.meta.env.VITE_DISABLE_REALTIME === "true";
    let current = true;
    let realtime: RealtimeConversation | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let catchUpInFlight = false;
    setMessages([]);
    knownMessageIdsRef.current.clear();
    setTypingUsers(new Set());
    setReadCursors({});
    setMessagesLoading(true);
    setConnectionStatus("connecting");
    setError(null);
    futureSequencesRef.current.clear();

    async function catchUp(afterSequence: number) {
      let cursor = afterSequence;
      for (let pages = 0; current && pages < 500; pages += 1) {
        const page = await api.messages(conversationId, cursor, 200);
        if (!current) return;
        receiveMessages(page.data);
        if (!page.page.has_more) return;
        const next = page.page.next_after_sequence;
        if (next === null || next <= cursor) throw new Error("Realtime replay returned a non-advancing cursor.");
        cursor = next;
      }
      if (current) throw new Error("Realtime replay exceeded the safe catch-up limit.");
    }

    const requestCatchUp = () => {
      if (!current || catchUpInFlight) return;
      catchUpInFlight = true;
      const before = contiguousSequenceRef.current;
      void catchUp(before)
        .then(() => {
          if (current && futureSequencesRef.current.size > 0 && contiguousSequenceRef.current === before) {
            setError("Durable message replay could not close a sequence gap. Reconnecting…");
            scheduleReconnect();
          }
        })
        .catch((reason: unknown) => current && setError(errorText(reason)))
        .finally(() => { catchUpInFlight = false; });
    };
    requestCatchUpRef.current = requestCatchUp;

    const scheduleReconnect = () => {
      if (!current || reconnectTimer) return;
      realtime?.disconnect();
      realtime = null;
      realtimeRef.current = null;
      setConnectionStatus("reconnecting");
      const timeout = [1_000, 2_000, 5_000, 10_000][reconnectAttempts] ?? 15_000;
      reconnectAttempts += 1;
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        void connectRealtime();
      }, timeout);
    };

    async function connectRealtime() {
      try {
        const { ticket } = await api.socketTicket();
        if (!current) return;
        realtime = new RealtimeConversation(
          socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""),
          ticket,
          conversationId,
          () => contiguousSequenceRef.current,
          {
            onStatus: (status) => {
              setConnectionStatus(status);
              if (status === "live") {
                reconnectAttempts = 0;
                void refreshConversations().catch(() => undefined);
              }
            },
            onMessages: receiveMessages,
            onReactionAdded: (event) => applyReaction(event, true),
            onReactionRemoved: (event) => applyReaction(event, false),
            onRead: (event: ReadCursorEvent) => setReadCursors((cursors) => ({ ...cursors, [event.user_id]: event.sequence })),
            onTyping: (userId, active) => setTypingUsers((currentUsers) => {
              const next = new Set(currentUsers);
              if (active) next.add(userId); else next.delete(userId);
              return next;
            }),
            onPresence: setOnlineUsers,
            onMembershipChanged: () => setMembershipVersion((value) => value + 1),
            onConversationChanged: () => void refreshConversations().catch(() => undefined),
            onCatchUpRequired: requestCatchUp,
            onError: setError,
            onReconnectRequired: scheduleReconnect
          }
        );
        realtimeRef.current = realtime;
        realtime.connect();
      } catch (reason: unknown) {
        if (current) {
          setError(errorText(reason));
          scheduleReconnect();
        }
      }
    }

    async function loadAndConnect() {
      try {
        const targeted = focusTarget?.conversationId === conversationId ? focusTarget.sequence : null;
        const start = Math.max(0, targeted ? targeted - 60 : activeLatestSequence - 100);
        contiguousSequenceRef.current = start;
        setContiguousSequence(start);
        const page = await api.messages(conversationId, start, 100);
        if (!current) return;
        receiveMessages(page.data);
        setHasOlder((page.data[0]?.conversation_sequence || start + 1) > 1);

        if (realtimeDisabled) setConnectionStatus("offline");
        else await connectRealtime();
      } catch (reason: unknown) {
        if (current) {
          setConnectionStatus("offline");
          setError(errorText(reason));
        }
      } finally {
        if (current) setMessagesLoading(false);
      }
    }

    void loadAndConnect();
    return () => {
      current = false;
      requestCatchUpRef.current = () => undefined;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      realtime?.disconnect();
      if (realtimeRef.current === realtime) realtimeRef.current = null;
    };
  }, [activeConversation?.id, activeConversationId, focusTarget?.id, session?.user.id]);

  const latestSequence = messages.at(-1)?.conversation_sequence || 0;
  const readableSequence = Math.min(latestSequence, contiguousSequence);
  useEffect(() => {
    if (!activeConversationId || !isNearBottom || readableSequence <= 0 || (isMobile && mobilePane !== "messages")) return;
    let timer: number | null = null;
    const mark = () => {
      if (document.visibilityState !== "visible") return;
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        const command = realtimeRef.current
          ? realtimeRef.current.markRead(readableSequence).then(() => undefined)
          : api.markRead(activeConversationId, readableSequence);
        void command.then(() => setConversations((current) => current.map((conversation) => conversation.id === activeConversationId ? { ...conversation, last_read_sequence: readableSequence, unread_count: 0 } : conversation))).catch(() => undefined);
      }, 500);
    };
    mark();
    document.addEventListener("visibilitychange", mark);
    return () => {
      if (timer) window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", mark);
    };
  }, [activeConversationId, api, isMobile, isNearBottom, mobilePane, readableSequence, setConversations]);

  useEffect(() => {
    if (!focusTarget || focusTarget.conversationId !== activeConversationId) return;
    const element = document.getElementById(`message-${focusTarget.id}`);
    if (element) {
      element.scrollIntoView({ behavior: "smooth", block: "center" });
      const timer = window.setTimeout(() => setFocusTarget(null), 3_000);
      return () => window.clearTimeout(timer);
    }
  }, [activeConversationId, focusTarget, messages.length]);

  useEffect(() => {
    if (focusTarget?.conversationId === activeConversationId) return;
    if (!nearBottomRef.current && !forceScrollToLatestRef.current) return;
    messagesEndRef.current?.scrollIntoView({ behavior: forceScrollToLatestRef.current ? "smooth" : "auto", block: "nearest" });
    forceScrollToLatestRef.current = false;
    updateNearBottom(true);
  }, [activeConversationId, focusTarget?.conversationId, latestSequence, updateNearBottom]);

  useEffect(() => () => {
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
  }, []);

  function selectConversation(id: string) {
    setSearchParams({ conversation: id });
    setMobilePane("messages");
    setShowDetails(false);
    setShowBrowseChannels(false);
  }

  function messageScrollChanged() {
    const scroll = scrollRef.current;
    if (!scroll) return;
    updateNearBottom(scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight <= 96);
  }

  function jumpToLatest() {
    forceScrollToLatestRef.current = false;
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
    updateNearBottom(true);
  }

  async function create(input: CreateConversationInput) {
    setError(null);
    try {
      const conversation = await createConversation(input);
      setShowCreateConversation(false);
      selectConversation(conversation.id);
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  async function sendInput(input: SendMessageInput, body: string) {
    if (!activeConversationId) return;
    const message = connectionStatus === "live" && realtimeRef.current
      ? await realtimeRef.current.sendMessage(input)
      : await api.sendMessage(activeConversationId, input);
    forceScrollToLatestRef.current = true;
    receiveMessages([message]);
    setComposer("");
    if (session) storeDraft(session.tenant.id, session.user.id, activeConversationId, "");
    setPendingAttachments([]);
    setReplyTo(null);
    setMentionedUserIds([]);
    setFailedSend(null);
    void body;
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!activeConversationId || sending) return;
    const body = composer.trim();
    if (!body) return setError("Write a message before sending.");
    if (pendingAttachments.some(({ attachment }) => attachment.status !== "ready")) return setError("Wait for every attachment safety scan to finish or remove the file.");
    const input: SendMessageInput = { client_message_id: clientMessageId(), body, attachment_ids: pendingAttachments.map(({ attachment }) => attachment.id), reply_to_message_id: replyTo?.id || null, mentioned_user_ids: mentionedUserIds };
    setSending(true);
    setError(null);
    realtimeRef.current?.setTyping(false);
    try {
      await sendInput(input, body);
    } catch (reason: unknown) {
      const message = errorText(reason);
      setFailedSend({ input, body, error: message });
      setError(message);
    } finally {
      setSending(false);
    }
  }

  async function retrySend() {
    if (!failedSend || sending) return;
    setSending(true);
    setError(null);
    try {
      await sendInput(failedSend.input, failedSend.body);
    } catch (reason: unknown) {
      const message = errorText(reason);
      setFailedSend({ ...failedSend, error: message });
      setError(message);
    } finally {
      setSending(false);
    }
  }

  async function sendThreadReply(input: SendMessageInput): Promise<Message> {
    if (!activeConversationId) throw new Error("Select a conversation before replying.");
    const message = connectionStatus === "live" && realtimeRef.current
      ? await realtimeRef.current.sendMessage(input)
      : await api.sendMessage(activeConversationId, input);
    forceScrollToLatestRef.current = true;
    receiveMessages([message]);
    return message;
  }

  function composerChanged(event: ChangeEvent<HTMLTextAreaElement>) {
    setComposer(event.target.value);
    realtimeRef.current?.setTyping(true);
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
    typingTimerRef.current = window.setTimeout(() => realtimeRef.current?.setTyping(false), 1_500);
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
        const maxBytes = capabilities?.max_attachment_bytes;
        if (!maxBytes) throw new Error("The server did not provide an attachment size limit");
        if (file.size > maxBytes) throw new Error(`${file.name} exceeds the ${formatAttachmentLimit(maxBytes)} limit`);
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

  async function loadOlder() {
    if (!activeConversationId || olderLoading) return;
    const oldest = messages[0]?.conversation_sequence;
    if (!oldest || oldest <= 1) return setHasOlder(false);
    setOlderLoading(true);
    const scroll = scrollRef.current;
    const previousHeight = scroll?.scrollHeight || 0;
    try {
      const after = Math.max(0, oldest - 201);
      const page = await api.messages(activeConversationId, after, 200, oldest);
      page.data.forEach((message) => knownMessageIdsRef.current.add(message.id));
      setMessages((current) => {
        const byId = new Map([...page.data, ...current].map((message) => [message.id, message]));
        return [...byId.values()].sort((left, right) => left.conversation_sequence - right.conversation_sequence);
      });
      setHasOlder((page.data[0]?.conversation_sequence || oldest) > 1);
      window.requestAnimationFrame(() => {
        if (scroll) scroll.scrollTop += scroll.scrollHeight - previousHeight;
      });
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setOlderLoading(false);
    }
  }

  async function toggleReaction(message: Message, emoji: string) {
    if (!session || !activeConversationId) return;
    const exists = message.reactions.some((reaction) => reaction.user_id === session.user.id && reaction.emoji === emoji);
    const event = { message_id: message.id, emoji, user_id: session.user.id };
    applyReaction(event, !exists);
    try {
      if (exists) await api.removeReaction(activeConversationId, message.id, emoji); else await api.addReaction(activeConversationId, message.id, emoji);
    } catch (reason: unknown) {
      applyReaction(event, exists);
      setError(errorText(reason));
    }
  }

  async function openAttachment(attachment: Attachment) {
    if (attachment.status !== "ready") return setError("This attachment is not available until its safety scan passes.");
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

  async function editMessage(message: Message, body: string) {
    try {
      receiveMessages([await api.editMessage(message.id, body)]);
    } catch (reason: unknown) {
      setError(errorText(reason));
      throw reason;
    }
  }

  async function deleteMessage(message: Message) {
    try {
      receiveMessages([await api.deleteMessage(message.id)]);
    } catch (reason: unknown) {
      setError(errorText(reason));
      throw reason;
    }
  }

  async function submitReport(details: string) {
    if (!reportTarget) return;
    setReporting(true);
    setReportError(null);
    setError(null);
    try {
      await api.createModerationCase({
        message_id: reportTarget.id,
        conversation_id: reportTarget.conversation_id,
        category: "message_content",
        summary: details.trim().slice(0, 160),
        details: details.trim(),
        priority: "normal"
      });
      setNotice("Report submitted to workspace moderators.");
      setReportTarget(null);
    } catch (reason: unknown) {
      const message = errorText(reason);
      setReportError(message);
      setError(message);
    } finally {
      setReporting(false);
    }
  }

  if (!session) return null;
  if (workspaceLoading) return <main className="centered-page" id="main-content" aria-busy="true"><div className="loading-card"><span className="spinner" aria-hidden="true" /><p>Opening your workspace…</p></div></main>;

  const activeTyping = [...typingUsers].filter((id) => id !== session.user.id).map((id) => usersById.get(id)?.display_name || "Someone");
  const attachmentsReady = pendingAttachments.every(({ attachment }) => attachment.status === "ready");
  const hasSentMessage = messages.some(({ sender_user_id: senderUserId }) => senderUserId === session.user.id);

  function dismissOnboarding() {
    try { window.localStorage.setItem(onboardingStorageKey, "dismissed"); } catch { /* Private or constrained storage must not block dismissal. */ }
    setShowOnboarding(false);
  }

  return (
    <main className={`workspace-grid mobile-${mobilePane}`} id="main-content">
      {notice && <div className="workspace-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}>×</button></div>}
      <aside className="conversation-sidebar" aria-label="Conversations">
        <div className="sidebar-heading"><div><span className="eyebrow">Direct, group & channel</span><h1>Conversations</h1></div><div className="sidebar-tools"><button className="icon-button" type="button" aria-label="Browse channels" aria-expanded={showBrowseChannels} onClick={() => { setShowBrowseChannels((visible) => !visible); setShowSearch(false); setShowDetails(false); }}>#</button><button className="icon-button" type="button" aria-label="Search messages" aria-expanded={showSearch} onClick={() => { setShowSearch((visible) => !visible); setShowBrowseChannels(false); setShowDetails(false); }}>⌕</button><button className="icon-button" type="button" aria-label="Create conversation" aria-expanded={showCreateConversation} onClick={() => setShowCreateConversation((visible) => !visible)}>+</button></div></div>
        {showOnboarding && <section className="onboarding-checklist" aria-labelledby="onboarding-checklist-title">
          <div><h2 id="onboarding-checklist-title">Get started</h2><button type="button" aria-label="Dismiss getting-started checklist" onClick={dismissOnboarding}>×</button></div>
          <ol>
            <li className={activeConversation ? "complete" : undefined}><span aria-hidden="true">{activeConversation ? "✓" : "1"}</span>Choose or start a conversation</li>
            <li className={hasSentMessage ? "complete" : undefined}><span aria-hidden="true">{hasSentMessage ? "✓" : "2"}</span>Send your first message</li>
            <li><span aria-hidden="true">3</span><Link to="/app/settings">Choose notification preferences</Link></li>
          </ol>
        </section>}
        {showCreateConversation && <CreateConversationForm users={users.filter((user) => user.id !== session.user.id && user.status === "active")} allowPublicChannels={capabilities?.allow_public_channels === true} onCancel={() => setShowCreateConversation(false)} onCreate={create} />}
        {conversations.length > 0 && <div className="conversation-filters" role="search" aria-label="Filter conversations">
          <label className="sr-only" htmlFor="conversation-filter-query">Filter conversations by title</label>
          <input id="conversation-filter-query" type="search" value={conversationQuery} onChange={(event) => setConversationQuery(event.target.value)} placeholder="Filter conversations" />
          <label className="sr-only" htmlFor="conversation-filter-kind">Conversation type</label>
          <select id="conversation-filter-kind" value={conversationKind} onChange={(event) => setConversationKind(event.target.value as typeof conversationKind)}>
            <option value="all">All types</option>
            <option value="direct">Direct messages</option>
            <option value="group">Groups</option>
            <option value="channel">Channels</option>
          </select>
          <label className="conversation-unread-filter"><input type="checkbox" checked={unreadOnly} onChange={(event) => setUnreadOnly(event.target.checked)} />Unread only</label>
        </div>}
        <nav className="conversation-list" aria-label="Conversation list">
          {conversations.length === 0 ? <div className="conversation-zero-state"><p className="empty-copy">No conversations yet. Choose how you want to get started.</p><div className="empty-state-actions"><button className="button primary compact" type="button" onClick={() => { setShowCreateConversation(true); setShowBrowseChannels(false); setShowSearch(false); }}>Start a conversation</button><button className="button ghost compact" type="button" onClick={() => { setShowBrowseChannels(true); setShowCreateConversation(false); setShowSearch(false); }}>Browse channels</button></div></div> : filteredConversations.length === 0 ? <p className="empty-copy" role="status">No conversations match these filters.</p> : filteredConversations.map((conversation) => <button type="button" key={conversation.id} className={`conversation-row ${conversation.id === activeConversationId ? "active" : ""}`} aria-current={conversation.id === activeConversationId ? "page" : undefined} onClick={() => selectConversation(conversation.id)}><span className="conversation-icon" aria-hidden="true">{conversation.kind === "channel" ? "#" : conversation.kind === "direct" ? "@" : "◇"}</span><span className="conversation-copy"><strong>{conversationTitle(conversation)}</strong><small>{conversation.kind} · {conversation.visibility}</small></span>{(conversation.unread_count || 0) > 0 && <span className="unread-badge" aria-label={`${conversation.unread_count} unread messages`}>{conversation.unread_count}</span>}</button>)}
        </nav>
      </aside>

      <section className="conversation-pane" aria-label={activeConversation ? conversationTitle(activeConversation) : "Messages"}>
        {activeConversation ? <>
          <header className="conversation-header"><button className="mobile-back" type="button" onClick={() => setMobilePane("list")} aria-label="Back to conversations">‹</button><div><span className="eyebrow">{activeConversation.kind} · {activeConversation.visibility}</span><h2>{conversationTitle(activeConversation)}</h2></div><div className="conversation-header-actions"><div className="connection-summary" aria-live="polite"><span className={`status-dot ${connectionStatus}`} aria-hidden="true" /><span>{connectionLabel(connectionStatus)}</span>{onlineUsers > 0 && <small>{onlineUsers} online</small>}</div><button className="button ghost compact" type="button" aria-expanded={showDetails} onClick={() => setShowDetails((visible) => !visible)}>Details</button></div></header>
          <div className="message-scroll" ref={scrollRef} aria-busy={messagesLoading} onScroll={messageScrollChanged}>
            {hasOlder && <div className="history-loader"><button className="button ghost compact" type="button" disabled={olderLoading} onClick={() => void loadOlder()}>{olderLoading ? "Loading…" : "Load older messages"}</button></div>}
            {messagesLoading && messages.length === 0 ? <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading messages…</div> : messages.length === 0 ? <div className="empty-state"><span className="empty-mark" aria-hidden="true">✦</span><h3>Start the conversation</h3><p>Messages are durable, ordered, and replayed when you reconnect.</p></div> : <ol className="message-list">{messages.map((message) => { const replyPreview = message.reply_to_message_id ? messagesById.get(message.reply_to_message_id) : undefined; return <MessageItem key={message.id} message={message} currentUserId={session.user.id} sender={usersById.get(message.sender_user_id)} replyPreview={replyPreview} replySender={replyPreview ? usersById.get(replyPreview.sender_user_id) : undefined} seenCount={Object.entries(readCursors).filter(([userId, sequence]) => userId !== session.user.id && sequence >= message.conversation_sequence).length} focused={focusTarget?.id === message.id} onReaction={(emoji) => void toggleReaction(message, emoji)} onAttachment={(attachment) => void openAttachment(attachment)} onReply={() => { setReplyTo(message); document.getElementById("message-composer")?.focus(); }} onThread={() => setThreadTargetId(message.id)} onEdit={(body) => editMessage(message, body)} onDelete={() => deleteMessage(message)} onReport={() => { setReportError(null); setReportTarget(message); }} />; })}</ol>}
            <div ref={messagesEndRef} />
          </div>
          <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"}.` : ""}</p>
          {!isNearBottom && <div className="new-message-jump"><button className="button primary compact" type="button" onClick={jumpToLatest}>{newMessageCount > 0 ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"} · Jump to latest` : "Jump to latest"}</button></div>}
          <div className="typing-line" aria-live="polite">{activeTyping.length > 0 ? `${activeTyping.join(", ")} ${activeTyping.length === 1 ? "is" : "are"} typing…` : "\u00a0"}</div>
          <form className="composer" onSubmit={(event) => void sendMessage(event)}>
            {failedSend && <div className="failed-send" role="alert"><span>Message not sent. Your draft is safe. {failedSend.error}</span><button className="button ghost compact" type="button" disabled={sending} onClick={() => void retrySend()}>Retry</button></div>}
            {replyTo && <div className="composer-reply"><span>Replying to <strong>{replyTo.sender_user_id === session.user.id ? "yourself" : usersById.get(replyTo.sender_user_id)?.display_name || "a message"}</strong><small>{replyTo.body}</small></span><button type="button" aria-label="Cancel reply" onClick={() => setReplyTo(null)}>×</button></div>}
            {pendingAttachments.length > 0 && <div className="pending-files" aria-label="Files being attached">{pendingAttachments.map(({ attachment, localName }) => <span className={`file-chip attachment-${attachment.status}`} key={attachment.id}><span aria-hidden="true">{attachment.status === "ready" ? "✓" : ["quarantined", "scan_failed"].includes(attachment.status) ? "!" : "…"}</span><span>{localName}<small>{attachmentLabel(attachment)}</small></span><button type="button" aria-label={`Remove ${localName}`} onClick={() => setPendingAttachments((current) => current.filter((item) => item.attachment.id !== attachment.id))}>×</button></span>)}</div>}
            <MentionPicker members={conversationMembers} currentUserId={session.user.id} selectedUserIds={mentionedUserIds} disabled={sending} onChange={setMentionedUserIds} />
            <label className="sr-only" htmlFor="message-composer">Message</label><textarea id="message-composer" value={composer} onChange={composerChanged} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} rows={2} maxLength={65_535} placeholder={`Message ${conversationTitle(activeConversation)}`} disabled={sending} />
            <div className="composer-actions"><label className={`attachment-button ${uploading ? "disabled" : ""}`}><input type="file" multiple disabled={uploading || sending} onChange={(event) => void filesSelected(event)} accept="image/*,text/*,application/pdf,application/zip,application/json" /><span aria-hidden="true">＋</span>{uploading ? "Uploading…" : "Attach"}</label><span className="composer-hint">Draft saved · Enter to send · Shift+Enter for a new line</span><button className="button primary send-button" type="submit" disabled={sending || uploading || !attachmentsReady || !composer.trim()}>{sending ? "Sending…" : "Send"}<span aria-hidden="true">↗</span></button></div>
          </form>
        </> : <div className="empty-state full-height"><span className="empty-mark" aria-hidden="true">◇</span><h2>Select a conversation</h2><p>Choose a direct message, group or channel.</p></div>}
      </section>

      {showSearch && <SearchPanel api={api} conversations={conversations} users={users} onClose={() => setShowSearch(false)} onSelect={(message) => { setFocusTarget({ id: message.id, conversationId: message.conversation_id, sequence: message.conversation_sequence }); selectConversation(message.conversation_id); setShowSearch(false); }} />}
      {showBrowseChannels && <ChannelBrowser api={api} enabled={capabilities?.allow_public_channels === true} onClose={() => setShowBrowseChannels(false)} onJoined={(joined) => { setConversations((current) => [joined, ...current.filter((value) => value.id !== joined.id)]); void refreshConversations().catch(() => undefined); }} onOpen={(id) => { selectConversation(id); setShowBrowseChannels(false); }} />}
      {showDetails && activeConversation && <ConversationDetails key={`${activeConversation.id}-${membershipVersion}`} api={api} conversation={activeConversation} currentUserId={session.user.id} users={users} onClose={() => setShowDetails(false)} onLeft={() => { setConversations((current) => current.filter((conversation) => conversation.id !== activeConversation.id)); setShowDetails(false); setMobilePane("list"); void refreshConversations().catch(() => undefined); }} onUpdated={(updated) => setConversations((current) => updated.archived_at ? current.filter((conversation) => conversation.id !== updated.id) : current.map((conversation) => conversation.id === updated.id ? { ...conversation, ...updated } : conversation))} />}
      {threadTargetId && activeConversationId && <ThreadDrawer api={api} conversationId={activeConversationId} targetMessageId={threadTargetId} currentUserId={session.user.id} members={conversationMembers} users={users} liveMessages={messages} onClose={() => { setThreadTargetId(null); if (searchParams.has("message")) { const next = new URLSearchParams(searchParams); next.delete("message"); setSearchParams(next, { replace: true }); } }} onSend={sendThreadReply} />}
      {reportTarget && <ActionDialog title="Report this message?" description="Describe why workspace moderators should review this message." impact="Moderators will receive the message reference and your explanation. The message is not deleted automatically." confirmLabel="Submit report" auditReason={{ label: "Reason for reporting this message", helpText: "Give moderators enough context to understand the concern.", minimumLength: 1 }} busy={reporting} error={reportError} onCancel={() => { if (!reporting) setReportTarget(null); }} onConfirm={(reason) => void submitReport(reason)} />}
    </main>
  );
}

function connectionLabel(status: ConnectionStatus): string {
  if (status === "live") return "Live";
  if (status === "connecting") return "Connecting";
  if (status === "reconnecting") return "Reconnecting";
  return "Offline";
}

function attachmentLabel(attachment: Attachment): string {
  if (attachment.status === "ready") return "Safety scan passed";
  if (attachment.status === "quarantined") return "Quarantined";
  if (attachment.status === "scan_failed") return "Scan failed";
  return "Safety scan pending";
}

function formatAttachmentLimit(value: number): string {
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(value % 1_000_000 === 0 ? 0 : 1)} MB` : `${Math.ceil(value / 1_000)} KB`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function safeUuid(value: string | null): string | null {
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

function readOnboardingPreference(storageKey: string): boolean {
  try { return window.localStorage.getItem(storageKey) !== "dismissed"; } catch { return true; }
}
