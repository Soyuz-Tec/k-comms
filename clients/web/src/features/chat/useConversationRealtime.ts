import { useEffect, type Dispatch, type SetStateAction } from "react";
import type { ApiClient } from "../../api";
import { errorText } from "../../lib/format";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  Message,
  MessageDeliveryCursor,
  ReactionEvent,
  ReadCursorEvent,
  RetainedSenderLabel,
  Session
} from "../../types";
import {
  loadConversationCatchUp,
  mergeCatchUpRequests,
  type CatchUpRequest
} from "./conversationFeedCatchUp";

type Box<T> = { current: T };

interface UseConversationRealtimeOptions {
  activeConversation: Conversation | null;
  activeConversationId: string | null;
  activeConversationIdRef: Box<string | null>;
  api: ApiClient;
  applyReaction: (event: ReactionEvent, add: boolean) => void;
  contiguousSequenceRef: Box<number>;
  futureSequencesRef: Box<Set<number>>;
  knownMessageIdsRef: Box<Set<string>>;
  linkedSearchSequence: number | null;
  loadOlderRequestGenerationRef: Box<number>;
  mergeRetainedSenderLabels: (labels: RetainedSenderLabel[]) => void;
  nearBottomRef: Box<boolean>;
  notePresence: (userIds: string[]) => void;
  noteRealtimeDisconnected: () => void;
  onMembershipChanged: () => void;
  publishRealtimeEvent: (event: CallRealtimeEvent) => void;
  realtimeRef: Box<RealtimeConversation | null>;
  receiveMessages: (messages: Message[]) => void;
  refreshConversations: () => Promise<void>;
  requestCatchUpRef: Box<(afterSequence?: number, beforeSequence?: number) => void>;
  scheduleMemberRefresh: (conversationId: string) => void;
  session: Session | null;
  setConnectionStatus: Dispatch<SetStateAction<ConnectionStatus>>;
  setContiguousSequence: Dispatch<SetStateAction<number>>;
  setError: (error: string | null) => void;
  setHasOlder: Dispatch<SetStateAction<boolean>>;
  setIsNearBottom: Dispatch<SetStateAction<boolean>>;
  setMessages: Dispatch<SetStateAction<Message[]>>;
  setMessagesLoading: Dispatch<SetStateAction<boolean>>;
  setNewMessageCount: Dispatch<SetStateAction<number>>;
  setOlderLoading: Dispatch<SetStateAction<boolean>>;
  setOnlineUsers: Dispatch<SetStateAction<number>>;
  setReadCursors: Dispatch<SetStateAction<Record<string, number>>>;
  setDeliveryCursors: Dispatch<SetStateAction<MessageDeliveryCursor[]>>;
  setTypingUsers: Dispatch<SetStateAction<Set<string>>>;
}

export function useConversationRealtime({
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
  setDeliveryCursors,
  setTypingUsers
}: UseConversationRealtimeOptions) {
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
    setDeliveryCursors([]);
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
      await loadConversationCatchUp(
        api,
        conversationId,
        afterSequence,
        beforeSequence,
        () => current,
        mergeRetainedSenderLabels,
        receiveMessages
      );
    }

    const requestCatchUp = (
      afterSequence = contiguousSequenceRef.current,
      beforeSequence?: number
    ) => {
      if (!current) return;
      pendingCatchUpRequest = mergeCatchUpRequests(
        pendingCatchUpRequest,
        { afterSequence, beforeSequence }
      );
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
            pendingCatchUpRequest = mergeCatchUpRequests(
              pendingCatchUpRequest,
              requestInFlight
            );
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
            onDelivery: (event) => {
              if (!current || activeConversationIdRef.current !== conversationId) return;
              setDeliveryCursors((cursors) => mergeDeliveryCursor(cursors, event));
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
        const [page, deliveryCursors] = await Promise.all([
          api.messages(conversationId, start, 100),
          typeof api.deliveryCursors === "function"
            ? api.deliveryCursors(conversationId).catch(() => [])
            : Promise.resolve([])
        ]);
        if (!current) return;
        setDeliveryCursors(deliveryCursors);
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

}

function mergeDeliveryCursor(
  cursors: MessageDeliveryCursor[],
  incoming: MessageDeliveryCursor
): MessageDeliveryCursor[] {
  const key = `${incoming.recipient_user_id}:${incoming.device_ref}`;
  const next = cursors.filter(
    (cursor) => `${cursor.recipient_user_id}:${cursor.device_ref}` !== key
  );
  next.push(incoming);
  return next;
}
