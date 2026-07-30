import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type RefObject,
  type SetStateAction
} from "react";
import { ApiError } from "../../api";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  Message,
  ReactionEvent,
  SocketHandoff
} from "../../types";
import type { GuestRoomApi } from "./roomApi";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";

interface UseGuestRealtimeOptions {
  api: GuestRoomApi;
  applyReaction: (event: ReactionEvent, add: boolean) => void;
  conversationId: string;
  initialPresenceCount: number;
  latestSequenceRef: RefObject<number>;
  mergeMessages: (
    messages: Message[],
    options?: {
      announce?: boolean;
      forceScroll?: boolean;
      behavior?: ScrollBehavior;
    }
  ) => void;
  onAccessEnded?: () => void;
  onPresenceChange?: (count: number) => void;
  requestCatchUp: (
    afterSequence: number,
    throughSequence?: number,
    announce?: boolean
  ) => void;
  scheduleMembersReload: () => void;
  setConversation: Dispatch<SetStateAction<Conversation>>;
  setError: Dispatch<SetStateAction<string>>;
}

export function useGuestRealtime({
  api,
  applyReaction,
  conversationId,
  initialPresenceCount,
  latestSequenceRef,
  mergeMessages,
  onAccessEnded,
  onPresenceChange,
  requestCatchUp,
  scheduleMembersReload,
  setConversation,
  setError
}: UseGuestRealtimeOptions) {
  const [connectionStatus, setConnectionStatus] =
    useState<ConnectionStatus>("connecting");
  const [onlineUsers, setOnlineUsers] = useState(initialPresenceCount);
  const [onlineUserIds, setOnlineUserIds] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const [presenceKnown, setPresenceKnown] = useState(false);
  const [realtimeHandoffVersion, setRealtimeHandoffVersion] = useState(0);
  const [realtimeCall, setRealtimeCall] = useState<CallRealtimeEvent | null>(null);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const socketHandoffTicketRef = useRef<string | null>(null);
  const presenceUserIdsSignatureRef = useRef<string | null>(null);
  const connectionStatusRef = useRef<ConnectionStatus>("connecting");
  const onAccessEndedRef = useRef(onAccessEnded);
  onAccessEndedRef.current = onAccessEnded;

  const updateConnectionStatus = useCallback((status: ConnectionStatus) => {
    connectionStatusRef.current = status;
    setConnectionStatus(status);
    if (status !== "live") {
      presenceUserIdsSignatureRef.current = null;
      setPresenceKnown(false);
      setOnlineUsers(0);
      setOnlineUserIds(new Set());
    }
  }, []);

  useEffect(() => {
    if (import.meta.env.VITE_DISABLE_REALTIME === "true") {
      updateConnectionStatus("offline");
      return;
    }
    updateConnectionStatus("connecting");
    let current = true;
    let realtime: RealtimeConversation | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let connecting = false;

    function scheduleReconnect() {
      if (!current || reconnectTimer !== null) return;
      const delay = Math.min(15_000, 1_000 * (2 ** reconnectAttempts));
      reconnectAttempts += 1;
      updateConnectionStatus("reconnecting");
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        void connectRealtime();
      }, delay);
    }

    async function connectRealtime() {
      if (!current || connecting) return;
      connecting = true;
      try {
        const handoffTicket = socketHandoffTicketRef.current;
        socketHandoffTicketRef.current = null;
        const { ticket } = handoffTicket
          ? { ticket: handoffTicket }
          : await api.socketTicket();
        if (!current) return;
        realtime = new RealtimeConversation(
          socketEndpoint(apiBase),
          ticket,
          conversationId,
          () => latestSequenceRef.current || 0,
          {
            onStatus: (status) => {
              updateConnectionStatus(status);
              if (status === "live") {
                reconnectAttempts = 0;
                scheduleMembersReload();
              }
            },
            onMessages: (nextMessages) => mergeMessages(nextMessages, {
              announce: true,
              behavior: "smooth"
            }),
            onReactionAdded: (event) => applyReaction(event, true),
            onReactionRemoved: (event) => applyReaction(event, false),
            onRead: () => undefined,
            onMembershipChanged: scheduleMembersReload,
            onConversationChanged: () => {
              void api.conversation().then(setConversation).catch(() => undefined);
            },
            onCallStarted: setRealtimeCall,
            onCallEnded: setRealtimeCall,
            onAudioCallStarted: setRealtimeCall,
            onAudioCallEnded: setRealtimeCall,
            onCatchUpRequired: (afterSequence) => requestCatchUp(afterSequence),
            onTyping: () => undefined,
            onPresence: (count, userIds) => {
              if (connectionStatusRef.current !== "live") return;
              const nextUserIds = new Set(userIds);
              const nextSignature = [...nextUserIds].sort().join("\u0000");
              if (presenceUserIdsSignatureRef.current !== nextSignature) {
                presenceUserIdsSignatureRef.current = nextSignature;
                scheduleMembersReload();
              }
              setOnlineUsers(count);
              setOnlineUserIds(nextUserIds);
              setPresenceKnown(true);
              onPresenceChange?.(count);
            },
            onError: setError,
            onReconnectRequired: () => {
              realtime?.disconnect();
              realtime = null;
              realtimeRef.current = null;
              scheduleReconnect();
            }
          }
        );
        realtimeRef.current = realtime;
        realtime.connect();
      } catch (reason: unknown) {
        if (current) {
          if (reason instanceof ApiError && [401, 403].includes(reason.status)) {
            updateConnectionStatus("offline");
            setError("Guest access has ended. Ask the room host for a new link.");
            onAccessEndedRef.current?.();
          } else {
            updateConnectionStatus("offline");
            scheduleReconnect();
          }
        }
      } finally {
        connecting = false;
      }
    }

    void connectRealtime();
    return () => {
      current = false;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      realtime?.disconnect();
      realtimeRef.current = null;
    };
  }, [
    api,
    applyReaction,
    conversationId,
    latestSequenceRef,
    mergeMessages,
    onPresenceChange,
    realtimeHandoffVersion,
    requestCatchUp,
    scheduleMembersReload,
    setConversation,
    setError,
    updateConnectionStatus
  ]);

  const handoffRealtime = useCallback((handoff?: SocketHandoff) => {
    realtimeRef.current?.disconnect();
    realtimeRef.current = null;
    updateConnectionStatus("connecting");
    socketHandoffTicketRef.current = handoff?.ticket || null;
    setRealtimeHandoffVersion((version) => version + 1);
  }, [updateConnectionStatus]);

  return {
    connectionStatus,
    handoffRealtime,
    onlineUserIds,
    onlineUsers,
    presenceKnown,
    realtimeCall,
    realtimeRef
  };
}
