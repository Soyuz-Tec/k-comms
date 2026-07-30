import {
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import type { Dispatch, SetStateAction } from "react";
import type { ApiClient, SendMessageInput } from "../../api";
import { errorText } from "../../lib/format";
import type { RealtimeConversation } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  Message,
  ReactionEvent,
  RetainedSenderLabel,
  Session
} from "../../types";
import {
  advanceContiguousSequence,
  applyMessageReaction,
  collectConversationActivity,
  mergeConversationMessages,
  updateConversationActivity
} from "./conversationFeedReducer";
import { useConversationRealtime } from "./useConversationRealtime";

interface UseConversationFeedOptions {
  api: ApiClient;
  session: Session | null;
  activeConversation: Conversation | null;
  activeConversationId: string | null;
  linkedSearchSequence: number | null;
  readerActive: boolean;
  setError: (error: string | null) => void;
  setConversations: Dispatch<SetStateAction<Conversation[]>>;
  refreshConversations: () => Promise<void>;
  mergeRetainedSenderLabels: (labels: RetainedSenderLabel[]) => void;
  scheduleMemberRefresh: (conversationId: string) => void;
  notePresence: (userIds: string[]) => void;
  noteRealtimeDisconnected: () => void;
  onMembershipChanged: () => void;
  publishRealtimeEvent: (event: CallRealtimeEvent) => void;
}

export function useConversationFeed({
  api,
  session,
  activeConversation,
  activeConversationId,
  linkedSearchSequence,
  readerActive,
  setError,
  setConversations,
  refreshConversations,
  mergeRetainedSenderLabels,
  scheduleMemberRefresh,
  notePresence,
  noteRealtimeDisconnected,
  onMembershipChanged,
  publishRealtimeEvent
}: UseConversationFeedOptions) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [messagesLoading, setMessagesLoading] = useState(false);
  const [olderLoading, setOlderLoading] = useState(false);
  const [hasOlder, setHasOlder] = useState(false);
  const [connectionStatus, setConnectionStatus] =
    useState<ConnectionStatus>("offline");
  const [onlineUsers, setOnlineUsers] = useState(0);
  const [typingUsers, setTypingUsers] = useState<Set<string>>(
    () => new Set()
  );
  const [readCursors, setReadCursors] = useState<Record<string, number>>({});
  const [contiguousSequence, setContiguousSequence] = useState(0);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const activeConversationIdRef = useRef(activeConversationId);
  activeConversationIdRef.current = activeConversationId;
  const contiguousSequenceRef = useRef(0);
  const futureSequencesRef = useRef<Set<number>>(new Set());
  const knownMessageIdsRef = useRef<Set<string>>(new Set());
  const loadOlderRequestGenerationRef = useRef(0);
  const nearBottomRef = useRef(true);
  const requestCatchUpRef = useRef<(
    afterSequence?: number,
    beforeSequence?: number
  ) => void>(() => undefined);

  const updateNearBottom = useCallback((nearBottom: boolean) => {
    nearBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
    if (nearBottom) setNewMessageCount(0);
  }, []);

  const shouldAutoScroll = useCallback(() => nearBottomRef.current, []);

  const updateConversationSummaries = useCallback(
    (incoming: Message[]) => {
      const activityByConversation = collectConversationActivity(
        incoming,
        session?.user.id
      );
      if (activityByConversation.size === 0) return;
      setConversations((current) =>
        updateConversationActivity(
          current,
          activityByConversation,
          activeConversationIdRef.current,
          document.visibilityState === "visible" &&
            nearBottomRef.current
        )
      );
    },
    [session?.user.id, setConversations]
  );

  const receiveMessages = useCallback(
    (incoming: Message[]) => {
      if (incoming.length === 0) return;
      updateConversationSummaries(incoming);
      const currentConversationId = activeConversationIdRef.current;
      const activeIncoming = currentConversationId
        ? incoming.filter(
            (message) =>
              message.conversation_id === currentConversationId
          )
        : [];
      if (activeIncoming.length === 0) return;
      const newMessagesFromOthers = activeIncoming.filter(
        (message) =>
          !knownMessageIdsRef.current.has(message.id) &&
          message.sender_user_id !== session?.user.id
      ).length;
      activeIncoming.forEach((message) =>
        knownMessageIdsRef.current.add(message.id)
      );
      if (!nearBottomRef.current && newMessagesFromOthers > 0) {
        setNewMessageCount((count) => count + newMessagesFromOthers);
      }
      const nextContiguous = advanceContiguousSequence(
        contiguousSequenceRef.current,
        futureSequencesRef.current,
        activeIncoming
      );
      if (nextContiguous !== contiguousSequenceRef.current) {
        contiguousSequenceRef.current = nextContiguous;
        setContiguousSequence(nextContiguous);
      }
      if (futureSequencesRef.current.size > 0) {
        requestCatchUpRef.current();
      }

      setMessages((current) => {
        return mergeConversationMessages(current, activeIncoming);
      });
    },
    [session?.user.id, updateConversationSummaries]
  );

  const applyReaction = useCallback(
    (event: ReactionEvent, add: boolean) => {
      setMessages((current) => applyMessageReaction(current, event, add));
    },
    []
  );

  useConversationRealtime({
    activeConversation,
    activeConversationId,
    activeConversationIdRef,
    api,
    applyReaction,
    contiguousSequenceRef,
    futureSequencesRef,
    knownMessageIdsRef,
    linkedSearchSequence,
    loadOlderRequestGenerationRef,
    mergeRetainedSenderLabels,
    nearBottomRef,
    notePresence,
    noteRealtimeDisconnected,
    onMembershipChanged,
    publishRealtimeEvent,
    realtimeRef,
    receiveMessages,
    refreshConversations,
    requestCatchUpRef,
    scheduleMemberRefresh,
    session,
    setConnectionStatus,
    setContiguousSequence,
    setError,
    setHasOlder,
    setIsNearBottom,
    setMessages,
    setMessagesLoading,
    setNewMessageCount,
    setOlderLoading,
    setOnlineUsers,
    setReadCursors,
    setTypingUsers
  });

  const latestSequence =
    messages.at(-1)?.conversation_sequence || 0;
  const readableSequence = Math.min(
    latestSequence,
    contiguousSequence
  );

  useEffect(() => {
    if (
      !activeConversationId ||
      !isNearBottom ||
      readableSequence <= 0 ||
      !readerActive
    ) {
      return;
    }
    let timer: number | null = null;
    const mark = () => {
      if (document.visibilityState !== "visible") return;
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        const command = realtimeRef.current
          ? realtimeRef.current
              .markRead(readableSequence)
              .then(() => undefined)
          : api.markRead(activeConversationId, readableSequence);
        void command
          .then(() =>
            setConversations((current) =>
              current.map((conversation) =>
                conversation.id === activeConversationId
                  ? {
                      ...conversation,
                      last_read_sequence: readableSequence,
                      unread_count: 0
                    }
                  : conversation
              )
            )
          )
          .catch(() => undefined);
      }, 500);
    };
    mark();
    document.addEventListener("visibilitychange", mark);
    return () => {
      if (timer) window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", mark);
    };
  }, [
    activeConversationId,
    api,
    isNearBottom,
    readableSequence,
    readerActive,
    setConversations
  ]);

  const loadOlder = useCallback(
    async (scroll: HTMLDivElement | null) => {
      if (!activeConversationId || olderLoading) return;
      const conversationId = activeConversationId;
      const requestGeneration =
        ++loadOlderRequestGenerationRef.current;
      const oldest = messages[0]?.conversation_sequence;
      if (!oldest || oldest <= 1) {
        setHasOlder(false);
        return;
      }
      setOlderLoading(true);
      const previousHeight = scroll?.scrollHeight || 0;
      try {
        const after = Math.max(0, oldest - 201);
        const page = await api.messages(
          conversationId,
          after,
          200,
          oldest
        );
        if (
          requestGeneration !==
            loadOlderRequestGenerationRef.current ||
          activeConversationIdRef.current !== conversationId
        ) {
          return;
        }
        mergeRetainedSenderLabels(
          page.included?.sender_labels || []
        );
        page.data.forEach((message) =>
          knownMessageIdsRef.current.add(message.id)
        );
        setMessages((current) => {
          const byId = new Map(
            [...page.data, ...current].map((message) => [
              message.id,
              message
            ])
          );
          return [...byId.values()].sort(
            (left, right) =>
              left.conversation_sequence -
              right.conversation_sequence
          );
        });
        setHasOlder(
          (page.data[0]?.conversation_sequence || oldest) > 1
        );
        window.requestAnimationFrame(() => {
          if (
            requestGeneration ===
              loadOlderRequestGenerationRef.current &&
            activeConversationIdRef.current === conversationId &&
            scroll
          ) {
            scroll.scrollTop += scroll.scrollHeight - previousHeight;
          }
        });
      } catch (reason: unknown) {
        if (
          requestGeneration ===
            loadOlderRequestGenerationRef.current &&
          activeConversationIdRef.current === conversationId
        ) {
          setError(errorText(reason));
        }
      } finally {
        if (
          requestGeneration ===
            loadOlderRequestGenerationRef.current &&
          activeConversationIdRef.current === conversationId
        ) {
          setOlderLoading(false);
        }
      }
    },
    [
      activeConversationId,
      api,
      mergeRetainedSenderLabels,
      messages,
      olderLoading,
      setError
    ]
  );

  const sendCommand = useCallback(
    (conversationId: string, input: SendMessageInput) => {
      const realtime =
        connectionStatus === "live" ? realtimeRef.current : null;
      return realtime
        ? realtime.sendMessage(input)
        : api.sendMessage(conversationId, input);
    },
    [api, connectionStatus]
  );

  const setTyping = useCallback((active: boolean) => {
    realtimeRef.current?.setTyping(active);
  }, []);

  return {
    messages,
    messagesLoading,
    olderLoading,
    hasOlder,
    connectionStatus,
    onlineUsers,
    typingUsers,
    readCursors,
    isNearBottom,
    newMessageCount,
    latestSequence,
    updateNearBottom,
    shouldAutoScroll,
    receiveMessages,
    updateConversationSummaries,
    applyReaction,
    loadOlder,
    sendCommand,
    setTyping
  };
}
