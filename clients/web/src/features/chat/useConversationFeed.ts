import {
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import type { Dispatch, SetStateAction } from "react";
import type { ApiClient, SendMessageInput } from "../../api";
import { errorText } from "../../lib/format";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  Message,
  ReactionEvent,
  ReadCursorEvent,
  RetainedSenderLabel,
  Session
} from "../../types";

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

interface CatchUpRequest {
  afterSequence: number;
  beforeSequence?: number;
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
      const activityByConversation = new Map<
        string,
        { latest: number; hasMessageFromOther: boolean }
      >();
      for (const message of incoming) {
        const current = activityByConversation.get(message.conversation_id);
        activityByConversation.set(message.conversation_id, {
          latest: Math.max(
            current?.latest || 0,
            message.conversation_sequence
          ),
          hasMessageFromOther:
            current?.hasMessageFromOther === true ||
            message.sender_user_id !== session?.user.id
        });
      }
      if (activityByConversation.size === 0) return;
      setConversations((current) =>
        current.map((conversation) => {
          const activity = activityByConversation.get(conversation.id);
          if (!activity) return conversation;
          const latestSequence = Math.max(
            conversation.latest_sequence,
            activity.latest
          );
          const shouldRemainUnread =
            conversation.id !== activeConversationIdRef.current ||
            document.visibilityState !== "visible" ||
            !nearBottomRef.current;
          return {
            ...conversation,
            latest_sequence: latestSequence,
            unread_count:
              shouldRemainUnread && activity.hasMessageFromOther
                ? Math.max(
                    conversation.unread_count || 0,
                    latestSequence - (conversation.last_read_sequence || 0)
                  )
                : conversation.unread_count
          };
        })
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
      for (const message of activeIncoming) {
        if (
          message.conversation_sequence > contiguousSequenceRef.current
        ) {
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
      if (futureSequencesRef.current.size > 0) {
        requestCatchUpRef.current();
      }

      setMessages((current) => {
        const byId = new Map(
          current.map((message) => [message.id, message])
        );
        activeIncoming.forEach((message) => {
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
          (left, right) =>
            left.conversation_sequence - right.conversation_sequence
        );
      });
    },
    [session?.user.id, updateConversationSummaries]
  );

  const applyReaction = useCallback(
    (event: ReactionEvent, add: boolean) => {
      setMessages((current) =>
        current.map((message) => {
          if (message.id !== event.message_id) return message;
          const without = message.reactions.filter(
            (reaction) =>
              !(
                reaction.user_id === event.user_id &&
                reaction.emoji === event.emoji
              )
          );
          return {
            ...message,
            reactions: add
              ? [
                  ...without,
                  { user_id: event.user_id, emoji: event.emoji }
                ]
              : without
          };
        })
      );
    },
    []
  );

  useEffect(() => {
    if (!session || !activeConversationId || !activeConversation) return;
    const conversationId = activeConversationId;
    const activeLatestSequence = activeConversation.latest_sequence;
    const realtimeDisabled =
      import.meta.env.VITE_DISABLE_REALTIME === "true";
    let current = true;
    let realtime: RealtimeConversation | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let catchUpRetryTimer: number | null = null;
    let catchUpRetryAttempts = 0;
    let catchUpInFlight = false;
    let pendingCatchUpRequest: CatchUpRequest | null = null;
    setMessages([]);
    knownMessageIdsRef.current.clear();
    setTypingUsers(new Set());
    setReadCursors({});
    setMessagesLoading(true);
    setConnectionStatus("connecting");
    setError(null);
    futureSequencesRef.current.clear();
    nearBottomRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    loadOlderRequestGenerationRef.current += 1;
    setOlderLoading(false);
    setHasOlder(false);

    async function catchUp(
      afterSequence: number,
      beforeSequence?: number
    ) {
      let cursor = afterSequence;
      for (let pages = 0; current && pages < 500; pages += 1) {
        const page =
          beforeSequence === undefined
            ? await api.messages(conversationId, cursor, 200)
            : await api.messages(
                conversationId,
                cursor,
                200,
                beforeSequence
              );
        if (!current) return;
        mergeRetainedSenderLabels(page.included?.sender_labels || []);
        receiveMessages(page.data);
        if (!page.page.has_more) return;
        const next = page.page.next_after_sequence;
        if (next === null || next <= cursor) {
          throw new Error(
            "Realtime replay returned a non-advancing cursor."
          );
        }
        cursor = next;
      }
      if (current) {
        throw new Error(
          "Realtime replay exceeded the safe catch-up limit."
        );
      }
    }

    const requestCatchUp = (
      afterSequence = contiguousSequenceRef.current,
      beforeSequence?: number
    ) => {
      if (!current) return;
      const pending = pendingCatchUpRequest;
      pendingCatchUpRequest = pending
        ? {
            afterSequence: Math.min(
              pending.afterSequence,
              afterSequence
            ),
            beforeSequence:
              pending.beforeSequence === undefined ||
              beforeSequence === undefined
                ? undefined
                : Math.max(
                    pending.beforeSequence,
                    beforeSequence
                  )
          }
        : { afterSequence, beforeSequence };
      if (catchUpInFlight) return;
      catchUpInFlight = true;
      let failed = false;
      let requestInFlight: CatchUpRequest | null = null;

      const drainCatchUpRequests = async () => {
        while (current && pendingCatchUpRequest !== null) {
          const requested = pendingCatchUpRequest;
          requestInFlight = requested;
          pendingCatchUpRequest = null;
          const before = contiguousSequenceRef.current;
          await catchUp(
            requested.afterSequence,
            requested.beforeSequence
          );
          requestInFlight = null;
          catchUpRetryAttempts = 0;
          if (
            current &&
            futureSequencesRef.current.size > 0 &&
            contiguousSequenceRef.current === before
          ) {
            pendingCatchUpRequest = null;
            setError(
              "Durable message replay could not close a sequence gap. Reconnecting…"
            );
            scheduleReconnect();
            return;
          }
        }
      };

      void drainCatchUpRequests()
        .catch((reason: unknown) => {
          if (!current) return;
          failed = true;
          if (requestInFlight) {
            const pending = pendingCatchUpRequest;
            pendingCatchUpRequest = pending
              ? {
                  afterSequence: Math.min(
                    requestInFlight.afterSequence,
                    pending.afterSequence
                  ),
                  beforeSequence:
                    requestInFlight.beforeSequence === undefined ||
                    pending.beforeSequence === undefined
                      ? undefined
                      : Math.max(
                          requestInFlight.beforeSequence,
                          pending.beforeSequence
                        )
                }
              : requestInFlight;
          }
          setError(
            `${errorText(reason)} Retrying durable replay…`
          );
        })
        .finally(() => {
          catchUpInFlight = false;
          if (!current || pendingCatchUpRequest === null) return;
          const retry = () => {
            catchUpRetryTimer = null;
            if (!current || pendingCatchUpRequest === null) return;
            const pending = pendingCatchUpRequest;
            pendingCatchUpRequest = null;
            requestCatchUp(
              pending.afterSequence,
              pending.beforeSequence
            );
          };
          if (failed) {
            if (catchUpRetryTimer === null) {
              const timeout =
                [1_000, 2_000, 5_000, 10_000][
                  catchUpRetryAttempts
                ] ?? 15_000;
              catchUpRetryAttempts += 1;
              catchUpRetryTimer = window.setTimeout(
                retry,
                timeout
              );
            }
          } else {
            retry();
          }
        });
    };
    requestCatchUpRef.current = requestCatchUp;

    const scheduleReconnect = () => {
      if (!current || reconnectTimer) return;
      realtime?.disconnect();
      realtime = null;
      realtimeRef.current = null;
      setConnectionStatus("reconnecting");
      const timeout =
        [1_000, 2_000, 5_000, 10_000][reconnectAttempts] ??
        15_000;
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
              if (
                !current ||
                activeConversationIdRef.current !== conversationId
              ) {
                return;
              }
              setConnectionStatus(status);
              if (status !== "live") {
                setOnlineUsers(0);
                noteRealtimeDisconnected();
              }
              if (status === "live") {
                reconnectAttempts = 0;
                void refreshConversations().catch(() => undefined);
              }
            },
            onMessages: (incoming) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                receiveMessages(incoming);
              }
            },
            onReactionAdded: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                applyReaction(event, true);
              }
            },
            onReactionRemoved: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                applyReaction(event, false);
              }
            },
            onRead: (event: ReadCursorEvent) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                setReadCursors((cursors) => ({
                  ...cursors,
                  [event.user_id]: event.sequence
                }));
              }
            },
            onTyping: (userId, active) =>
              setTypingUsers((currentUsers) => {
                if (
                  !current ||
                  activeConversationIdRef.current !== conversationId
                ) {
                  return currentUsers;
                }
                const next = new Set(currentUsers);
                if (active) next.add(userId);
                else next.delete(userId);
                return next;
              }),
            onPresence: (count, userIds) => {
              if (
                !current ||
                activeConversationIdRef.current !== conversationId
              ) {
                return;
              }
              setOnlineUsers(count);
              notePresence(userIds);
            },
            onMembershipChanged: () => {
              if (
                !current ||
                activeConversationIdRef.current !== conversationId
              ) {
                return;
              }
              onMembershipChanged();
              scheduleMemberRefresh(conversationId);
            },
            onConversationChanged: () => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                void refreshConversations().catch(() => undefined);
              }
            },
            onCallStarted: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                publishRealtimeEvent(event);
              }
            },
            onCallEnded: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                publishRealtimeEvent(event);
              }
            },
            onAudioCallStarted: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                publishRealtimeEvent(event);
              }
            },
            onAudioCallEnded: (event) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                publishRealtimeEvent(event);
              }
            },
            onCatchUpRequired: (afterSequence) =>
              requestCatchUp(afterSequence),
            onError: (message) => {
              if (
                current &&
                activeConversationIdRef.current === conversationId
              ) {
                setError(message);
              }
            },
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
        const start = Math.max(
          0,
          linkedSearchSequence
            ? linkedSearchSequence - 60
            : activeLatestSequence - 100
        );
        contiguousSequenceRef.current = start;
        setContiguousSequence(start);
        const page = await api.messages(
          conversationId,
          start,
          100
        );
        if (!current) return;
        mergeRetainedSenderLabels(
          page.included?.sender_labels || []
        );
        receiveMessages(page.data);
        setHasOlder(
          (page.data[0]?.conversation_sequence || start + 1) > 1
        );

        if (realtimeDisabled) {
          setConnectionStatus("offline");
        } else {
          await connectRealtime();
        }
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
      if (catchUpRetryTimer) window.clearTimeout(catchUpRetryTimer);
      realtime?.disconnect();
      if (realtimeRef.current === realtime) {
        realtimeRef.current = null;
      }
    };
  }, [
    activeConversation?.id,
    activeConversationId,
    linkedSearchSequence,
    mergeRetainedSenderLabels,
    notePresence,
    noteRealtimeDisconnected,
    onMembershipChanged,
    publishRealtimeEvent,
    scheduleMemberRefresh,
    session?.user.id
  ]);

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
