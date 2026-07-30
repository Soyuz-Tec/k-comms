import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { FormEvent, ReactNode } from "react";
import { Link } from "react-router";
import { ApiError } from "../../api";
import { AppIcon } from "../../components/AppIcon";
import {
  AppMenuCloseButton,
  AppMenuTrigger
} from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import {
  clientMessageId,
  conversationTitle,
  errorText,
  formatTime,
  initials
} from "../../lib/format";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  ConversationMembership,
  GuestSession,
  Message,
  ReactionEvent,
  RetainedSenderLabel,
  Session,
  SocketHandoff
} from "../../types";
import { ParticipantRoster } from "./ParticipantRoster";
import type { GuestRoomApi } from "./roomApi";
import {
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantIdentifier,
  resolveVisibleSenderIdentity,
  type ParticipantIdentity
} from "../../lib/participantIdentity";
import { loadGuestMessageCatchUp } from "./guestMessageCatchUp";

const GuestCallPanel = lazy(() =>
  import("../calls/CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);

const senderLabelRefreshDelaysMs = [30_000, 60_000, 120_000, 300_000] as const;
type PendingGuestCatchUp = {
  afterSequence: number;
  throughSequence?: number;
  announce: boolean;
};
interface SenderLabelRefreshBackoff {
  conversationId: string;
  candidateSignature: string | null;
  resultSignature: string | null;
  delayIndex: number;
  nextAttemptAt: number;
}

interface ConversionReceipt {
  displayName: string;
  workspaceSlug: string;
}

const apiBase = import.meta.env.VITE_API_BASE_URL || "";

function useMobileRoomLayout() {
  const queryText = "(max-width: 760px), (max-height: 560px)";
  const [mobile, setMobile] = useState(
    () => window.matchMedia?.(queryText).matches ?? false
  );

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia(queryText);
    const update = () => setMobile(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, [queryText]);

  return mobile;
}

function GuestRoomMenu({
  canKeepRoom,
  identityLabel,
  inviteContent,
  leaving,
  onClose,
  onKeepRoom,
  onLeave,
  warnsOfGuestHostLoss
}: {
  canKeepRoom: boolean;
  identityLabel: "Guest" | "Host" | "Member";
  inviteContent?: ReactNode;
  leaving: boolean;
  onClose: () => void;
  onKeepRoom: () => void;
  onLeave: () => void;
  warnsOfGuestHostLoss: boolean;
}) {
  const dialogRef = useModalDialog(onClose);

  return (
    <div
      className="guest-room-menu-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <aside
        ref={dialogRef}
        className="guest-room-menu"
        id="guest-room-menu"
        role="dialog"
        aria-modal="true"
        aria-labelledby="guest-room-menu-title"
      >
        <header>
          <h2 id="guest-room-menu-title">Room menu</h2>
          <AppMenuCloseButton
            data-initial-focus
            accessibleLabel="Close"
            onClick={onClose}
          />
        </header>
        {inviteContent}
        <div className="guest-room-menu-actions">
          {canKeepRoom && (
            <button className="guest-room-menu-action" type="button" onClick={onKeepRoom}>
              <AppIcon name="bookmark" />
              <div>
                <strong>
                  {identityLabel === "Host"
                    ? "Save this room"
                    : "Keep this conversation"}
                </strong>
                <span>Continue from another device with an account.</span>
              </div>
            </button>
          )}
          {identityLabel === "Host" && (
            <Link className="guest-room-menu-action" to="/sign-in" onClick={onClose}>
              <AppIcon name="logIn" />
              <div>
                <strong>Sign in to a workspace</strong>
                <span>Use an existing K-Comms account.</span>
              </div>
            </Link>
          )}
          <button
            className="guest-room-menu-action danger"
            type="button"
            disabled={leaving}
            onClick={onLeave}
          >
            <AppIcon name="logOut" />
            <div>
              <strong>{leaving ? "Leaving room…" : "Leave room"}</strong>
              <span>
                {warnsOfGuestHostLoss
                  ? "Leaving clears this guest host session. Copy the invite to rejoin, or save the room first to keep management access."
                  : "This ends only your session on this device."}
              </span>
            </div>
          </button>
        </div>
      </aside>
    </div>
  );
}

export function GuestShell({
  api,
  initialSession,
  accountActionsAllowed,
  mediaActionsAllowed,
  onLeave,
  onAccessEnded,
  onConverted,
  roomBanner,
  roomMenuInvite,
  identityLabel = "Guest",
  initialPresenceCount = 1,
  onPresenceChange
}: {
  api: GuestRoomApi;
  initialSession: GuestSession;
  accountActionsAllowed: boolean;
  mediaActionsAllowed: boolean;
  onLeave: () => void;
  onAccessEnded?: () => void;
  onConverted: (
    session: Session,
    conversation: Conversation,
    socketHandoff?: SocketHandoff
  ) => void;
  roomBanner?: ReactNode | ((participantCount: number) => ReactNode);
  roomMenuInvite?: ReactNode | ((participantCount: number) => ReactNode);
  identityLabel?: "Guest" | "Host" | "Member";
  initialPresenceCount?: number;
  onPresenceChange?: (count: number) => void;
}) {
  const [conversation, setConversation] = useState(initialSession.conversation);
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const [knownUsersById, setKnownUsersById] = useState(
    () => new Map([[initialSession.user.id, initialSession.user]])
  );
  const [retainedSenderLabelsById, setRetainedSenderLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const [messages, setMessages] = useState<Message[]>([]);
  const [composer, setComposer] = useState("");
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [loadRetry, setLoadRetry] = useState(0);
  const [sending, setSending] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("connecting");
  const [onlineUsers, setOnlineUsers] = useState(initialPresenceCount);
  const [onlineUserIds, setOnlineUserIds] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const [presenceKnown, setPresenceKnown] = useState(false);
  const [realtimeHandoffVersion, setRealtimeHandoffVersion] = useState(0);
  const [error, setError] = useState("");
  const [showAccount, setShowAccount] = useState(false);
  const [showRoomMenu, setShowRoomMenu] = useState(false);
  const [converting, setConverting] = useState(false);
  const [conversionNotice, setConversionNotice] = useState("");
  const [conversionReceipt, setConversionReceipt] =
    useState<ConversionReceipt | null>(null);
  const [realtimeCall, setRealtimeCall] = useState<CallRealtimeEvent | null>(null);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const socketHandoffTicketRef = useRef<string | null>(null);
  const latestSequenceRef = useRef(0);
  const knownMessageIdsRef = useRef(new Set<string>());
  const membersRequestGenerationRef = useRef(0);
  const membersReloadInFlightRef = useRef(false);
  const membersReloadPendingRef = useRef(false);
  const scheduleMembersReloadRef = useRef<() => void>(() => undefined);
  const membersReloadTimerRef = useRef<number | null>(null);
  const memberIdsSignatureRef = useRef<string | null>(null);
  const visibleMessageAuthorsRef = useRef<
    Array<{ senderUserId: string; messageId: string }>
  >([]);
  const senderLabelRefreshBackoffRef = useRef<SenderLabelRefreshBackoff>(
    newSenderLabelRefreshBackoff(conversation.id)
  );
  const catchUpInFlightRef = useRef(false);
  const catchUpRetryTimerRef = useRef<number | null>(null);
  const catchUpRetryAttemptsRef = useRef(0);
  const catchUpLifecycleGenerationRef = useRef(0);
  const catchUpErrorRef = useRef<string | null>(null);
  const pendingCatchUpRef = useRef<PendingGuestCatchUp | null>(null);
  const requestCatchUpRef = useRef<(
    afterSequence: number,
    throughSequence?: number,
    announce?: boolean
  ) => void>(() => undefined);
  const presenceUserIdsSignatureRef = useRef<string | null>(null);
  const connectionStatusRef = useRef<ConnectionStatus>("connecting");
  const nearBottomRef = useRef(true);
  const scrollRequestRef = useRef<ScrollBehavior | null>("auto");
  const lastMarkedReadRef = useRef(0);
  const messageScrollRef = useRef<HTMLDivElement | null>(null);
  const composerRef = useRef<HTMLTextAreaElement | null>(null);
  const accountToggleRef = useRef<HTMLButtonElement | null>(null);
  const accountReturnFocusRef = useRef<HTMLButtonElement | null>(null);
  const roomMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const roomHeadingRef = useRef<HTMLHeadingElement | null>(null);
  const accountEmailRef = useRef<HTMLInputElement | null>(null);
  const accountWasOpenRef = useRef(false);
  const restoreRoomHeadingFocusRef = useRef(false);
  const roomMenuTriggerFocusedRef = useRef(false);
  const onAccessEndedRef = useRef(onAccessEnded);
  onAccessEndedRef.current = onAccessEnded;
  const selfServiceConversion =
    initialSession.capabilities.self_service_conversion === true;
  const conversionEnabled =
    initialSession.capabilities.conversion_enabled === true ||
    selfServiceConversion;
  const mobileRoomLayout = useMobileRoomLayout();

  useEffect(() => {
    const clearRoomMenuTriggerFocus = (event: FocusEvent) => {
      if (event.target !== roomMenuTriggerRef.current) {
        roomMenuTriggerFocusedRef.current = false;
      }
    };
    document.addEventListener("focusin", clearRoomMenuTriggerFocus);
    return () =>
      document.removeEventListener("focusin", clearRoomMenuTriggerFocus);
  }, []);

  useEffect(() => {
    if (!mobileRoomLayout && showRoomMenu) {
      restoreRoomHeadingFocusRef.current = true;
      setShowRoomMenu(false);
    } else if (!mobileRoomLayout && roomMenuTriggerFocusedRef.current) {
      roomMenuTriggerFocusedRef.current = false;
      roomHeadingRef.current?.focus();
    }
  }, [mobileRoomLayout, showRoomMenu]);

  useLayoutEffect(() => {
    if (!mobileRoomLayout && !showRoomMenu && restoreRoomHeadingFocusRef.current) {
      restoreRoomHeadingFocusRef.current = false;
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          if (roomHeadingRef.current?.isConnected) {
            roomHeadingRef.current.focus();
          }
        });
      });
    }
  }, [mobileRoomLayout, showRoomMenu]);

  const markLatestRead = useCallback(() => {
    const latest = latestSequenceRef.current;
    if (
      document.visibilityState !== "visible" ||
      !nearBottomRef.current ||
      latest <= 0 ||
      latest <= lastMarkedReadRef.current
    ) {
      return;
    }

    lastMarkedReadRef.current = latest;
    void api.markRead(latest).catch(() => {
      lastMarkedReadRef.current = 0;
    });
  }, [api]);

  const mergeMessages = useCallback((
    incoming: Message[],
    options: { announce?: boolean; forceScroll?: boolean; behavior?: ScrollBehavior } = {}
  ) => {
    if (incoming.length === 0) return;
    const newMessages = incoming.filter(({ id }) => !knownMessageIdsRef.current.has(id));
    for (const message of incoming) knownMessageIdsRef.current.add(message.id);

    if (newMessages.length > 0) {
      const ownMessage = newMessages.some(
        ({ sender_user_id: senderUserId }) => senderUserId === initialSession.user.id
      );
      if (options.forceScroll || ownMessage || nearBottomRef.current) {
        scrollRequestRef.current = options.behavior ?? "auto";
        setNewMessageCount(0);
      } else if (options.announce !== false) {
        setNewMessageCount((count) => count + newMessages.length);
      }
    }

    setMessages((current) => {
      const byId = new Map(current.map((message) => [message.id, message]));
      for (const message of incoming) byId.set(message.id, message);
      const next = [...byId.values()].sort(
        (left, right) => left.conversation_sequence - right.conversation_sequence
      );
      latestSequenceRef.current = next.at(-1)?.conversation_sequence || 0;
      return next;
    });
  }, [initialSession.user.id]);

  const mergeRetainedSenderLabels = useCallback((
    incoming: RetainedSenderLabel[]
  ) => {
    if (incoming.length === 0) return;
    setRetainedSenderLabelsById((current) =>
      mergeRetainedSenderLabelMaps(current, incoming)
    );
  }, []);

  const requestCatchUp = useCallback((
    afterSequence: number,
    throughSequence?: number,
    announce = true
  ) => {
    const pending = pendingCatchUpRef.current;
    pendingCatchUpRef.current = pending
      ? {
          afterSequence: Math.min(pending.afterSequence, afterSequence),
          throughSequence:
            pending.throughSequence === undefined || throughSequence === undefined
              ? undefined
              : Math.max(pending.throughSequence, throughSequence),
          announce: pending.announce || announce
        }
      : { afterSequence, throughSequence, announce };
    if (catchUpInFlightRef.current) return;
    const lifecycleGeneration = catchUpLifecycleGenerationRef.current;
    catchUpInFlightRef.current = true;
    let failed = false;
    let requestInFlight: PendingGuestCatchUp | null = null;

    const drain = async () => {
      while (pendingCatchUpRef.current) {
        const requested = pendingCatchUpRef.current;
        requestInFlight = requested;
        pendingCatchUpRef.current = null;
        const nextMessages = await loadGuestMessageCatchUp(
          api,
          requested.afterSequence,
          mergeRetainedSenderLabels,
          requested.throughSequence
        );
        if (
          catchUpLifecycleGenerationRef.current !== lifecycleGeneration
        ) return;
        mergeMessages(nextMessages, {
          announce: requested.announce,
          behavior: requested.announce ? "smooth" : "auto"
        });
        requestInFlight = null;
        catchUpRetryAttemptsRef.current = 0;
        if (catchUpErrorRef.current) {
          const recoveredError = catchUpErrorRef.current;
          catchUpErrorRef.current = null;
          setError((current) => current === recoveredError ? "" : current);
        }
      }
    };

    void drain()
      .catch((reason: unknown) => {
        if (
          catchUpLifecycleGenerationRef.current !== lifecycleGeneration
        ) return;
        failed = true;
        if (requestInFlight) {
          const pendingRequest = pendingCatchUpRef.current;
          pendingCatchUpRef.current = pendingRequest
            ? {
                afterSequence: Math.min(
                  requestInFlight.afterSequence,
                  pendingRequest.afterSequence
                ),
                throughSequence:
                  requestInFlight.throughSequence === undefined ||
                  pendingRequest.throughSequence === undefined
                    ? undefined
                    : Math.max(
                        requestInFlight.throughSequence,
                        pendingRequest.throughSequence
                      ),
                announce: requestInFlight.announce || pendingRequest.announce
              }
            : requestInFlight;
        }
        const message = errorText(reason);
        catchUpErrorRef.current = message;
        setError(message);
      })
      .finally(() => {
        if (
          catchUpLifecycleGenerationRef.current !== lifecycleGeneration
        ) return;
        catchUpInFlightRef.current = false;
        const pendingRequest = pendingCatchUpRef.current;
        if (pendingRequest) {
          const retry = () => {
            if (
              catchUpLifecycleGenerationRef.current !== lifecycleGeneration
            ) return;
            catchUpRetryTimerRef.current = null;
            const request = pendingCatchUpRef.current;
            if (!request) return;
            pendingCatchUpRef.current = null;
            requestCatchUpRef.current(
              request.afterSequence,
              request.throughSequence,
              request.announce
            );
          };
          if (failed) {
            if (catchUpRetryTimerRef.current === null) {
              const attempts = catchUpRetryAttemptsRef.current;
              catchUpRetryAttemptsRef.current += 1;
              catchUpRetryTimerRef.current = window.setTimeout(
                retry,
                [1_000, 2_000, 5_000, 10_000][attempts] ?? 15_000
              );
            }
          } else {
            retry();
          }
        }
      });
  }, [api, mergeMessages, mergeRetainedSenderLabels]);
  const applyReaction = useCallback((event: ReactionEvent, add: boolean) => {
    setMessages((current) => current.map((message) => {
      if (message.id !== event.message_id) return message;
      const reactions = message.reactions.filter(
        (reaction) => !(reaction.user_id === event.user_id && reaction.emoji === event.emoji)
      );
      return {
        ...message,
        reactions: add ? [...reactions, { user_id: event.user_id, emoji: event.emoji }] : reactions
      };
    }));
  }, []);

  const reloadMembers = useCallback(async (
    errorTarget: "shell" | "initial" = "shell"
  ): Promise<void> => {
    if (membersReloadInFlightRef.current) {
      membersReloadPendingRef.current = true;
      membersRequestGenerationRef.current += 1;
      return;
    }
    membersReloadInFlightRef.current = true;
    const requestGeneration = ++membersRequestGenerationRef.current;
    try {
      const nextMembers = await api.conversationMembers();
      if (requestGeneration !== membersRequestGenerationRef.current) return;
      setMembers(nextMembers);
      const nextSignature = nextMembers
        .map(({ user }) => user.id)
        .sort()
        .join("\u0000");
      const previousSignature = memberIdsSignatureRef.current;
      memberIdsSignatureRef.current = nextSignature;
      if (previousSignature !== null) {
        const activeUserIds = new Set(nextMembers.map(({ user }) => user.id));
        const departedAuthorMessageIds = visibleMessageAuthorsRef.current
          .filter(({ senderUserId }) => !activeUserIds.has(senderUserId))
          .map(({ messageId }) => messageId);
        if (departedAuthorMessageIds.length > 0) {
          if (
            !senderLabelRefreshAllowed(
              senderLabelRefreshBackoffRef,
              conversation.id,
              departedAuthorMessageIds
            )
          ) {
            return;
          }
          try {
            const labels = await api.messageSenderLabels(
              departedAuthorMessageIds
            );
            if (requestGeneration === membersRequestGenerationRef.current) {
              mergeRetainedSenderLabels(labels);
              recordSenderLabelRefresh(
                senderLabelRefreshBackoffRef,
                conversation.id,
                departedAuthorMessageIds,
                labels
              );
            }
          } catch (reason: unknown) {
            if (requestGeneration === membersRequestGenerationRef.current) {
              setError(errorText(reason));
            }
          }
        }
      }
    } catch (reason: unknown) {
      if (requestGeneration !== membersRequestGenerationRef.current) return;
      if (errorTarget === "initial") throw reason;
      setError(errorText(reason));
    } finally {
      membersReloadInFlightRef.current = false;
      if (membersReloadPendingRef.current) {
        membersReloadPendingRef.current = false;
        scheduleMembersReloadRef.current();
      }
    }
  }, [api, conversation.id, mergeRetainedSenderLabels]);

  const scheduleMembersReload = useCallback(() => {
    if (membersReloadTimerRef.current !== null) return;
    membersReloadTimerRef.current = window.setTimeout(() => {
      membersReloadTimerRef.current = null;
      void reloadMembers();
    }, 0);
  }, [reloadMembers]);
  scheduleMembersReloadRef.current = scheduleMembersReload;

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
    catchUpLifecycleGenerationRef.current += 1;
    requestCatchUpRef.current = requestCatchUp;
    return () => {
      catchUpLifecycleGenerationRef.current += 1;
      if (membersReloadTimerRef.current !== null) {
        window.clearTimeout(membersReloadTimerRef.current);
        membersReloadTimerRef.current = null;
      }
      membersReloadPendingRef.current = false;
      membersRequestGenerationRef.current += 1;
      pendingCatchUpRef.current = null;
      catchUpInFlightRef.current = false;
      if (catchUpRetryTimerRef.current !== null) {
        window.clearTimeout(catchUpRetryTimerRef.current);
        catchUpRetryTimerRef.current = null;
      }
      catchUpRetryAttemptsRef.current = 0;
      catchUpErrorRef.current = null;
      requestCatchUpRef.current = () => undefined;
    };
  }, [conversation.id, requestCatchUp]);

  useEffect(() => {
    memberIdsSignatureRef.current = null;
    senderLabelRefreshBackoffRef.current =
      newSenderLabelRefreshBackoff(conversation.id);
  }, [conversation.id]);

  useEffect(() => {
    const reconciliationTimer = window.setInterval(
      scheduleMembersReload,
      30_000
    );
    return () => window.clearInterval(reconciliationTimer);
  }, [conversation.id, scheduleMembersReload]);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setLoadError("");
    setError("");
    void Promise.all([
      api.conversation(),
      reloadMembers("initial"),
      loadGuestMessageCatchUp(api, 0, mergeRetainedSenderLabels)
    ]).then(([nextConversation, , nextMessages]) => {
      if (!current) return;
      setConversation(nextConversation);
      mergeMessages(nextMessages, {
        announce: false,
        forceScroll: true,
        behavior: "auto"
      });
    }).catch((reason: unknown) => {
      if (current) setLoadError(errorText(reason));
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [
    api,
    loadRetry,
    mergeMessages,
    mergeRetainedSenderLabels,
    reloadMembers
  ]);

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
          conversation.id,
          () => latestSequenceRef.current,
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
            onMembershipChanged: () => {
              scheduleMembersReload();
            },
            onConversationChanged: () => {
              void api.conversation().then(setConversation).catch(() => undefined);
            },
            onCallStarted: setRealtimeCall,
            onCallEnded: setRealtimeCall,
            onAudioCallStarted: setRealtimeCall,
            onAudioCallEnded: setRealtimeCall,
            onCatchUpRequired: (afterSequence) => {
              requestCatchUp(afterSequence);
            },
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
            onError: (message) => setError(message),
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
    conversation.id,
    mergeMessages,
    mergeRetainedSenderLabels,
    onPresenceChange,
    realtimeHandoffVersion,
    requestCatchUp,
    reloadMembers,
    scheduleMembersReload,
    updateConnectionStatus
  ]);

  useLayoutEffect(() => {
    const behavior = scrollRequestRef.current;
    const scroll = messageScrollRef.current;
    if (loading || !behavior || !scroll) return;

    scrollRequestRef.current = null;
    scroll.scrollTo?.({ top: scroll.scrollHeight, behavior });
    scroll.scrollTop = scroll.scrollHeight;
    nearBottomRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    markLatestRead();
  }, [loading, markLatestRead, messages.length]);

  useEffect(() => {
    const authorMessageIds = new Map<string, string>();
    for (const message of messages) {
      if (!authorMessageIds.has(message.sender_user_id)) {
        authorMessageIds.set(message.sender_user_id, message.id);
      }
    }
    visibleMessageAuthorsRef.current = [...authorMessageIds]
      .map(([senderUserId, messageId]) => ({ senderUserId, messageId }))
      .sort((left, right) => left.senderUserId.localeCompare(right.senderUserId));
  }, [messages]);

  useEffect(() => {
    function visibilityChanged() {
      if (document.visibilityState === "visible") markLatestRead();
    }
    document.addEventListener("visibilitychange", visibilityChanged);
    return () => document.removeEventListener("visibilitychange", visibilityChanged);
  }, [markLatestRead]);

  useEffect(() => {
    if (showAccount) {
      accountWasOpenRef.current = true;
      accountEmailRef.current?.focus();
    } else if (accountWasOpenRef.current) {
      accountWasOpenRef.current = false;
      const returnTarget = [
        accountReturnFocusRef.current,
        accountToggleRef.current,
        roomMenuTriggerRef.current
      ].find((element) => element?.isConnected);
      returnTarget?.focus();
    }
  }, [showAccount]);

  useEffect(() => {
    if (conversionNotice) composerRef.current?.focus();
  }, [conversionNotice]);

  useEffect(() => {
    setKnownUsersById((current) => {
      const next = new Map(current);
      for (const member of members) next.set(member.user.id, member.user);
      return next;
    });
  }, [members]);

  const activeUsersById = useMemo(
    () => new Map(members.map(({ user }) => [user.id, user])),
    [members]
  );
  const usersById = knownUsersById;
  const visibleSenderIdentities = useMemo(() => {
    const identities = new Map<string, ParticipantIdentity>();
    for (const identity of activeUsersById.values()) {
      identities.set(identity.id, identity);
    }
    for (const message of messages) {
      const identity = resolveVisibleSenderIdentity(
        message.sender_user_id,
        activeUsersById,
        retainedSenderLabelsById,
        [usersById]
      );
      if (identity) identities.set(identity.id, identity);
    }
    return identities;
  }, [activeUsersById, messages, retainedSenderLabelsById, usersById]);
  const duplicateKnownDisplayNames = useMemo(
    () => duplicateParticipantNames(visibleSenderIdentities.values()),
    [visibleSenderIdentities]
  );

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = composer.trim();
    if (!body || sending || loading || loadError) return;
    const input = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: []
    };
    setSending(true);
    setError("");
    try {
      let sent: Message;
      if (realtimeRef.current && connectionStatus === "live") {
        try {
          sent = await realtimeRef.current.sendMessage(input);
        } catch {
          sent = await api.sendMessage(input);
        }
      } else {
        sent = await api.sendMessage(input);
      }
      mergeMessages([sent], {
        forceScroll: true,
        behavior: "smooth"
      });
      setComposer("");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setSending(false);
      composerRef.current?.focus();
    }
  }

  function messageScrollChanged() {
    const scroll = messageScrollRef.current;
    if (!scroll) return;
    const nearBottom =
      scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight <= 96;
    nearBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
    if (nearBottom) {
      setNewMessageCount(0);
      markLatestRead();
    }
  }

  function jumpToLatest() {
    const scroll = messageScrollRef.current;
    if (!scroll) return;
    scroll.scrollTo?.({ top: scroll.scrollHeight, behavior: "smooth" });
    scroll.scrollTop = scroll.scrollHeight;
    nearBottomRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    markLatestRead();
    composerRef.current?.focus();
  }

  function leave() {
    setLeaving(true);
    setError("");
    void api.logout().catch(() => undefined);
    onLeave();
  }

  async function convertAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!accountActionsAllowed) {
      setConversionNotice("");
      setError(
        "Account creation is disabled for this deployment address. Open K-Comms over trusted HTTPS before entering or submitting credentials."
      );
      return;
    }
    const values = new FormData(event.currentTarget);
    setConverting(true);
    setConversionNotice("");
    setError("");
    try {
      if (!api.convertAccount) {
        throw new Error("Account creation is not available for this room session.");
      }
      const result = await api.convertAccount({
        email: String(values.get("email") || "").trim(),
        password: String(values.get("password") || ""),
        ...(selfServiceConversion
          ? {
              display_name:
                String(values.get("display_name") || "").trim() || undefined
            }
          : {
              verification_code: String(
                values.get("verification_code") || ""
              ).trim()
            })
      });
      if (selfServiceConversion) {
        realtimeRef.current?.disconnect();
        realtimeRef.current = null;
        updateConnectionStatus("connecting");
        socketHandoffTicketRef.current = result.socket_handoff?.ticket || null;
        onConverted(
          result.session,
          result.conversation,
          result.socket_handoff
        );
        setShowAccount(false);
        setConversionNotice(
          `Account created for ${result.session.user.display_name}. You are still in this conversation.`
        );
        setConversionReceipt({
          displayName: result.session.user.display_name,
          workspaceSlug: result.session.tenant.slug
        });
        setRealtimeHandoffVersion((version) => version + 1);
      } else {
        onConverted(result.session, result.conversation);
      }
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setConverting(false);
    }
  }

  const openRoomChat = useCallback(() => {
    window.requestAnimationFrame(() => {
      composerRef.current?.focus();
      composerRef.current?.scrollIntoView?.({ block: "nearest" });
    });
  }, []);

  return (
    <main
      className={`guest-shell${mobileRoomLayout ? " compact-room-layout" : ""}`}
      id="main-content"
    >
      <header className="guest-shell-header">
        <div className="guest-room-heading">
          <span className="guest-badge">{identityLabel}</span>
          <div>
            <h1 ref={roomHeadingRef} tabIndex={-1}>
              {conversationTitle(conversation)}
            </h1>
            <p
              role={mobileRoomLayout ? "status" : undefined}
              aria-live={mobileRoomLayout ? "polite" : undefined}
              aria-atomic={mobileRoomLayout ? "true" : undefined}
            >
              <span className="guest-room-workspace">
                {initialSession.tenant.name} ·{" "}
              </span>
              {presenceKnown
                ? `${onlineUsers} ${onlineUsers === 1 ? "person" : "people"} online`
                : "presence unknown"}{" "}
              ·{" "}
              <span
                className={`guest-connection ${connectionStatus}`}
                role={mobileRoomLayout ? undefined : "status"}
                aria-live={mobileRoomLayout ? undefined : "polite"}
                aria-atomic={mobileRoomLayout ? undefined : "true"}
              >
                {connectionStatus}
              </span>
            </p>
          </div>
        </div>
        {mobileRoomLayout ? (
          <AppMenuTrigger
            ref={roomMenuTriggerRef}
            className="guest-room-menu-trigger"
            accessibleLabel="Open room menu"
            expanded={showRoomMenu}
            controls="guest-room-menu"
            onFocus={() => {
              roomMenuTriggerFocusedRef.current = true;
            }}
            onClick={() => setShowRoomMenu(true)}
          />
        ) : (
          <div className="guest-shell-actions">
            {conversionEnabled && !conversionReceipt && (
              <button
                ref={accountToggleRef}
                className="button ghost"
                type="button"
                aria-expanded={showAccount}
                aria-controls="guest-account-conversion"
                onClick={(event) => {
                  accountReturnFocusRef.current = event.currentTarget;
                  setShowAccount((value) => !value);
                }}
              >
                <AppIcon name="bookmark" />
                {identityLabel === "Host"
                  ? "Save this room"
                  : "Keep this conversation"}
              </button>
            )}
            {identityLabel === "Host" && (
              <Link className="button ghost" to="/sign-in">
                <AppIcon name="logIn" />
                Sign in
              </Link>
            )}
            <button className="button danger" type="button" disabled={leaving} onClick={leave}>
              <AppIcon name="logOut" />
              {leaving ? "Leaving…" : "Leave"}
            </button>
          </div>
        )}
      </header>

      {showRoomMenu && (
        <GuestRoomMenu
          canKeepRoom={conversionEnabled && !conversionReceipt}
          identityLabel={identityLabel}
          inviteContent={
            typeof roomMenuInvite === "function"
              ? roomMenuInvite(members.length)
              : roomMenuInvite
          }
          leaving={leaving}
          onClose={() => setShowRoomMenu(false)}
          onKeepRoom={() => {
            accountReturnFocusRef.current = roomMenuTriggerRef.current;
            setShowRoomMenu(false);
            window.requestAnimationFrame(() => {
              window.requestAnimationFrame(() => setShowAccount(true));
            });
          }}
          onLeave={leave}
          warnsOfGuestHostLoss={
            identityLabel === "Host" &&
            initialSession.user.account_type === "guest"
          }
        />
      )}

      <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {conversionNotice}
      </p>

      {conversionReceipt && (
        <section
          className="guest-conversion-receipt"
          aria-labelledby="guest-conversion-receipt-title"
        >
          <div>
            <strong id="guest-conversion-receipt-title">
              Room saved for {conversionReceipt.displayName}
            </strong>
            <span>
              Use this workspace address to sign in from another device.
            </span>
          </div>
          <label>
            Workspace address
            <input
              type="text"
              value={conversionReceipt.workspaceSlug}
              readOnly
              spellCheck={false}
              onFocus={(event) => event.currentTarget.select()}
            />
          </label>
          <a
            className="button ghost"
            href={`/sign-in?tenant_slug=${encodeURIComponent(
              conversionReceipt.workspaceSlug
            )}`}
          >
            Workspace sign-in link
          </a>
        </section>
      )}

      {(!mobileRoomLayout || !roomMenuInvite) &&
        (typeof roomBanner === "function"
          ? roomBanner(members.length)
          : roomBanner)}
      {(!accountActionsAllowed || !mediaActionsAllowed) && (
        <div className="guest-transport-warning transport-warning" role="alert">
          <strong>Secure account and media actions are unavailable.</strong>
          <span>
            Use non-sensitive content. Open this service over trusted HTTPS
            before using account creation or audio/video controls.
          </span>
        </div>
      )}

      {conversionEnabled && !conversionReceipt && showAccount && (
        <section
          className="guest-account-card"
          id="guest-account-conversion"
          aria-labelledby="guest-account-title"
        >
          <div>
            <h2 id="guest-account-title">Keep your conversation</h2>
            <p id="guest-account-email-help">
              {selfServiceConversion
                ? "Add an email and password without leaving the room. Your identity, membership and conversation history stay in place."
                : (
                  <>
                    Enter the full email authorized by the host
                    {initialSession.capabilities.email_hint
                      ? <> ({initialSession.capabilities.email_hint})</>
                      : null}
                    , plus the one-time verification code the host sent separately.
                    Your identity and conversation history stay in place.
                  </>
                )}
            </p>
          </div>
          <form onSubmit={(event) => void convertAccount(event)}>
            <label className="field">
              Work email
              <input
                ref={accountEmailRef}
                name="email"
                type="email"
                maxLength={320}
                autoComplete="email"
                aria-describedby="guest-account-email-help"
                disabled={!accountActionsAllowed}
                required
              />
            </label>
            {selfServiceConversion && (
              <label className="field">
                Display name <span className="optional">(optional)</span>
                <input
                  name="display_name"
                  type="text"
                  maxLength={120}
                  autoComplete="name"
                  defaultValue={initialSession.user.display_name}
                  disabled={!accountActionsAllowed}
                />
              </label>
            )}
            {!selfServiceConversion && <div className="field">
              <label htmlFor="guest-account-verification-code">
                Account verification code
              </label>
              <input
                id="guest-account-verification-code"
                name="verification_code"
                type="text"
                minLength={43}
                maxLength={43}
                pattern="[A-Za-z0-9_-]{43}"
                autoComplete="one-time-code"
                aria-describedby="guest-account-verification-help"
                spellCheck={false}
                disabled={!accountActionsAllowed}
                required
              />
              <small id="guest-account-verification-help">
                This code is separate from the room link and can be used only for this account conversion.
              </small>
            </div>}
            <label className="field">
              Password
              <input
                name="password"
                type="password"
                minLength={12}
                maxLength={256}
                autoComplete="new-password"
                disabled={!accountActionsAllowed}
                required
              />
              <small>At least 12 characters; the server applies the final password policy.</small>
            </label>
            <button
              className="button primary"
              type="submit"
              disabled={converting || !accountActionsAllowed}
            >
              {converting ? "Creating account…" : "Create account"}
            </button>
            <button className="button ghost" type="button" onClick={() => setShowAccount(false)}>
              Not now
            </button>
          </form>
        </section>
      )}

      <ParticipantRoster
        members={members}
        onlineUserIds={onlineUserIds}
        currentUserId={initialSession.user.id}
        presenceKnown={presenceKnown}
        compact={mobileRoomLayout}
      />

      <section className="guest-live-tools" aria-label="Room call">
        <div>
          <strong>Talk live</strong>
          <span>Start or join without losing the room conversation.</span>
        </div>
        <Suspense fallback={<span className="visually-hidden" role="status">Preparing call controls…</span>}>
          <GuestCallPanel
            api={api}
            conversation={conversation}
            audioEnabled={
              initialSession.capabilities.allow_audio_calls &&
              mediaActionsAllowed
            }
            videoEnabled={
              initialSession.capabilities.allow_video_calls &&
              mediaActionsAllowed
            }
            currentUserDisplayName={initialSession.user.display_name}
            realtimeEvent={realtimeCall}
            onOpenChat={openRoomChat}
          />
        </Suspense>
      </section>

      <section className="guest-room" aria-label={conversationTitle(conversation)}>
        <div
          ref={messageScrollRef}
          className="guest-message-scroll"
          role="region"
          aria-label="Message history"
          aria-busy={loading}
          tabIndex={0}
          onScroll={messageScrollChanged}
        >
          {loading ? (
            <div className="inline-loading" role="status">
              <span className="spinner" aria-hidden="true" />Loading conversation…
            </div>
          ) : loadError ? (
            <div className="empty-state guest-load-error" role="alert">
              <span className="empty-mark" aria-hidden="true"><AppIcon name="triangleAlert" /></span>
              <h2>Could not load this conversation</h2>
              <p>{loadError}</p>
              <button
                className="button primary"
                type="button"
                onClick={() => setLoadRetry((attempt) => attempt + 1)}
              >
                <AppIcon name="refresh" />
                Retry conversation
              </button>
            </div>
          ) : messages.length === 0 ? (
            <div className="empty-state guest-message-empty">
              <h2>No messages yet</h2>
              <p>
                {identityLabel === "Guest"
                  ? "You joined as a guest. "
                  : "Your room is ready. "}
                Send a message when you’re ready.
              </p>
            </div>
          ) : (
            <ol className="guest-message-list">
              {messages.map((message) => {
                const activeSender = activeUsersById.get(message.sender_user_id);
                const sender = visibleSenderIdentities.get(message.sender_user_id);
                const senderDisplayName =
                  sender?.display_name ||
                  "Room member";
                const senderIdentifier = participantIdentifier(
                  { id: message.sender_user_id, display_name: senderDisplayName },
                  duplicateKnownDisplayNames
                );
                return (
                  <li key={message.id} className={message.sender_user_id === initialSession.user.id ? "mine" : ""}>
                    <span className="avatar" aria-hidden="true">
                      {initials(senderDisplayName)}
                    </span>
                    <div>
                      <div className="guest-message-meta">
                        <strong>
                          {senderIdentifier}
                          {message.sender_user_id === initialSession.user.id && " (you)"}
                        </strong>
                        {activeSender?.account_type === "guest" && <span className="guest-badge compact">Guest</span>}
                        <time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time>
                      </div>
                      <p>{message.body}</p>
                    </div>
                  </li>
                );
              })}
            </ol>
          )}
        </div>
        <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {newMessageCount > 0
            ? `${newMessageCount} new ${newMessageCount === 1 ? "message" : "messages"}.`
            : ""}
        </p>
        {!isNearBottom && newMessageCount > 0 && (
          <div className="guest-new-message-jump">
            <button className="button primary compact" type="button" onClick={jumpToLatest}>
              <AppIcon name="arrowDown" />
              {newMessageCount} new {newMessageCount === 1 ? "message" : "messages"} · Jump to latest
            </button>
          </div>
        )}
        <form className="guest-composer" onSubmit={(event) => void sendMessage(event)}>
          <label className="sr-only" htmlFor="guest-message-composer">Message</label>
          <textarea
            ref={composerRef}
            id="guest-message-composer"
            rows={mobileRoomLayout ? 1 : 2}
            maxLength={65_535}
            value={composer}
            readOnly={sending || loading || Boolean(loadError)}
            aria-busy={sending}
            aria-disabled={loading || Boolean(loadError)}
            autoFocus={!roomBanner}
            placeholder={
              mobileRoomLayout
                ? "Write a message"
                : `Message ${conversationTitle(conversation)}`
            }
            onChange={(event) => setComposer(event.target.value)}
            onKeyDown={(event) => {
              if (
                event.key === "Enter" &&
                !event.shiftKey &&
                !event.nativeEvent.isComposing
              ) {
                event.preventDefault();
                event.currentTarget.form?.requestSubmit();
              }
            }}
          />
          <button
            className="button primary"
            type="submit"
            aria-busy={sending}
            aria-label={sending ? "Sending message" : "Send"}
            disabled={sending || loading || Boolean(loadError) || !composer.trim()}
          >
            <AppIcon
              name={sending ? "loader" : "send"}
              className={sending ? "spin" : ""}
            />
            <span className="guest-send-label">
              {sending ? "Sending…" : "Send"}
            </span>
          </button>
        </form>
      </section>

      {error && (
        <div className="guest-shell-error" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="Dismiss error" onClick={() => setError("")}><AppIcon name="x" /></button>
        </div>
      )}
    </main>
  );
}

function newSenderLabelRefreshBackoff(
  conversationId: string
): SenderLabelRefreshBackoff {
  return {
    conversationId,
    candidateSignature: null,
    resultSignature: null,
    delayIndex: 0,
    nextAttemptAt: 0
  };
}

function senderLabelRefreshAllowed(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[]
): boolean {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  let current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    current = {
      ...newSenderLabelRefreshBackoff(conversationId),
      candidateSignature
    };
    backoffRef.current = current;
  }
  return (
    document.visibilityState === "visible" &&
    Date.now() >= current.nextAttemptAt
  );
}

function recordSenderLabelRefresh(
  backoffRef: { current: SenderLabelRefreshBackoff },
  conversationId: string,
  messageIds: string[],
  labels: RetainedSenderLabel[]
): void {
  const candidateSignature = JSON.stringify([...messageIds].sort());
  const resultSignature = JSON.stringify(
    [...labels]
      .sort((left, right) => left.id.localeCompare(right.id))
      .map(({ id, display_name, redacted }) => [id, display_name, redacted])
  );
  const current = backoffRef.current;
  if (
    current.conversationId !== conversationId ||
    current.candidateSignature !== candidateSignature
  ) {
    return;
  }
  const changed =
    current.resultSignature !== null &&
    current.resultSignature !== resultSignature;
  const delayIndex =
    current.resultSignature === null || changed
      ? 0
      : Math.min(
          current.delayIndex + 1,
          senderLabelRefreshDelaysMs.length - 1
        );
  const delayMs =
    senderLabelRefreshDelaysMs[delayIndex] ??
    300_000;
  backoffRef.current = {
    ...current,
    resultSignature,
    delayIndex,
    nextAttemptAt: Date.now() + delayMs
  };
}
