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
import { AppIcon } from "../../components/AppIcon";
import { AppMenuTrigger } from "../../components/AppMenuControls";
import {
  clientMessageId,
  conversationTitle,
  errorText
} from "../../lib/format";
import type {
  Conversation,
  GuestSession,
  Message,
  RetainedSenderLabel,
  Session,
  SocketHandoff
} from "../../types";
import { GuestConversionPanel } from "./GuestConversionPanel";
import { GuestMessageViewport } from "./GuestMessageViewport";
import { GuestRoomMenu } from "./GuestRoomMenu";
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
import { useGuestConversationFeed } from "./useGuestConversationFeed";
import { useGuestConversion } from "./useGuestConversion";
import { useGuestMessageViewport } from "./useGuestMessageViewport";
import { useGuestParticipants } from "./useGuestParticipants";
import { useGuestRealtime } from "./useGuestRealtime";
import { useMobileRoomLayout } from "./useMobileRoomLayout";

const GuestCallPanel = lazy(() =>
  import("../calls/CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);

const GuestWhiteboard = lazy(() =>
  import("../whiteboard/CollaborativeWhiteboard").then(
    ({ CollaborativeWhiteboard }) => ({ default: CollaborativeWhiteboard })
  )
);

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
  whiteboardEnabled = false,
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
  whiteboardEnabled?: boolean;
  identityLabel?: "Guest" | "Host" | "Member";
  initialPresenceCount?: number;
  onPresenceChange?: (count: number) => void;
}) {
  const [conversation, setConversation] = useState(initialSession.conversation);
  const [knownUsersById, setKnownUsersById] = useState(
    () => new Map([[initialSession.user.id, initialSession.user]])
  );
  const [retainedSenderLabelsById, setRetainedSenderLabelsById] = useState(
    () => new Map<string, RetainedSenderLabel>()
  );
  const [composer, setComposer] = useState("");
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [loadRetry, setLoadRetry] = useState(0);
  const [sending, setSending] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [error, setError] = useState("");
  const [showRoomMenu, setShowRoomMenu] = useState(false);
  const [activeWorkspaceTool, setActiveWorkspaceTool] = useState<
    "canvas" | "messages"
  >("canvas");
  const visibleMessageAuthorsRef = useRef<
    Array<{ senderUserId: string; messageId: string }>
  >([]);
  const accountToggleRef = useRef<HTMLButtonElement | null>(null);
  const accountReturnFocusRef = useRef<HTMLButtonElement | null>(null);
  const roomMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const roomHeadingRef = useRef<HTMLHeadingElement | null>(null);
  const accountEmailRef = useRef<HTMLInputElement | null>(null);
  const accountWasOpenRef = useRef(false);
  const restoreRoomHeadingFocusRef = useRef(false);
  const roomMenuTriggerFocusedRef = useRef(false);
  const mobileRoomLayout = useMobileRoomLayout();
  const {
    composerRef,
    isNearBottom,
    jumpToLatest,
    latestSequenceRef,
    messageScrollChanged,
    messageScrollRef,
    nearBottomRef,
    newMessageCount,
    scrollRequestRef,
    setNewMessageCount
  } = useGuestMessageViewport({ api, loading });

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

  const mergeRetainedSenderLabels = useCallback((
    incoming: RetainedSenderLabel[]
  ) => {
    if (incoming.length === 0) return;
    setRetainedSenderLabelsById((current) =>
      mergeRetainedSenderLabelMaps(current, incoming)
    );
  }, []);

  const {
    applyReaction,
    mergeMessages,
    messages,
    requestCatchUp
  } = useGuestConversationFeed({
    api,
    conversationId: conversation.id,
    currentUserId: initialSession.user.id,
    latestSequenceRef,
    mergeRetainedSenderLabels,
    nearBottomRef,
    scrollRequestRef,
    setError,
    setNewMessageCount
  });

  const {
    members,
    reloadMembers,
    scheduleMembersReload
  } = useGuestParticipants({
    api,
    conversationId: conversation.id,
    mergeRetainedSenderLabels,
    setError,
    visibleMessageAuthorsRef
  });

  const {
    connectionStatus,
    handoffRealtime,
    onlineUserIds,
    onlineUsers,
    presenceKnown,
    realtimeCall,
    realtimeRef
  } = useGuestRealtime({
    api,
    applyReaction,
    conversationId: conversation.id,
    initialPresenceCount,
    latestSequenceRef,
    mergeMessages,
    onAccessEnded,
    onPresenceChange,
    requestCatchUp,
    scheduleMembersReload,
    setConversation,
    setError
  });

  const {
    conversionEnabled,
    conversionNotice,
    conversionReceipt,
    converting,
    convertAccount,
    selfServiceConversion,
    setShowAccount,
    showAccount
  } = useGuestConversion({
    api,
    initialSession,
    accountActionsAllowed,
    handoffRealtime,
    onConverted,
    setError
  });

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
  const whiteboardOptions = useMemo(() => {
    const collaborators = new Map(
      members.map(({ user }) => [user.id, user.display_name])
    );
    collaborators.set(
      initialSession.user.id,
      initialSession.user.display_name
    );
    return {
      api,
      userId: initialSession.user.id,
      deviceId: initialSession.device.id,
      users: [...collaborators].map(([id, display_name]) => ({
        id,
        display_name
      }))
    };
  }, [api, initialSession.device.id, initialSession.user, members]);

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

  function leave() {
    setLeaving(true);
    setError("");
    void api.logout().catch(() => undefined);
    onLeave();
  }

  const openRoomChat = useCallback(() => {
    window.requestAnimationFrame(() => {
      composerRef.current?.focus();
      composerRef.current?.scrollIntoView?.({ block: "nearest" });
    });
  }, []);

  function resolveMessageSender(message: Message) {
    const activeSender = activeUsersById.get(message.sender_user_id);
    const sender = visibleSenderIdentities.get(message.sender_user_id);
    const displayName = sender?.display_name || "Room member";

    return {
      displayName,
      identifier: participantIdentifier(
        { id: message.sender_user_id, display_name: displayName },
        duplicateKnownDisplayNames
      ),
      guest: activeSender?.account_type === "guest"
    };
  }

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

      <GuestConversionPanel
        accountActionsAllowed={accountActionsAllowed}
        accountEmailRef={accountEmailRef}
        conversionEnabled={conversionEnabled}
        conversionNotice={conversionNotice}
        converting={converting}
        initialSession={initialSession}
        onClose={() => setShowAccount(false)}
        onSubmit={(event) => void convertAccount(event)}
        open={showAccount}
        receipt={conversionReceipt}
        selfServiceConversion={selfServiceConversion}
      />

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

      {whiteboardEnabled && (
        <div
          className="guest-workspace-tools"
          role="group"
          aria-label="Workspace tools"
        >
          <button
            className="button ghost"
            type="button"
            aria-pressed={activeWorkspaceTool === "canvas"}
            onClick={() => setActiveWorkspaceTool("canvas")}
          >
            <AppIcon name="whiteboard" /> Canvas
          </button>
          <button
            className="button ghost"
            type="button"
            aria-pressed={activeWorkspaceTool === "messages"}
            onClick={() => setActiveWorkspaceTool("messages")}
          >
            <AppIcon name="messages" /> Messages
            {newMessageCount > 0 && (
              <span className="guest-tool-count" aria-label={`${newMessageCount} unread`}>
                {newMessageCount}
              </span>
            )}
          </button>
        </div>
      )}

      <div
        className={`guest-collaboration-workspace${
          whiteboardEnabled ? "" : " without-whiteboard"
        }`}
        data-mobile-view={activeWorkspaceTool}
      >
        {whiteboardEnabled && (
          <div className="guest-whiteboard-panel" aria-label="Shared drawing canvas">
            <Suspense
              fallback={
                <div className="whiteboard-loading" role="status">
                  <span className="spinner" aria-hidden="true" />
                  Preparing shared canvas…
                </div>
              }
            >
              <GuestWhiteboard
                conversationId={conversation.id}
                conversationTitle={conversationTitle(conversation)}
                collaborationOptions={whiteboardOptions}
                compact
              />
            </Suspense>
          </div>
        )}
        <div className="guest-chat-panel" aria-label="Room messages">
          <GuestMessageViewport
            autoFocus={!roomBanner && !whiteboardEnabled}
            composer={composer}
            composerRef={composerRef}
            conversationTitle={conversationTitle(conversation)}
            currentUserId={initialSession.user.id}
            identityLabel={identityLabel}
            isNearBottom={isNearBottom}
            loadError={loadError}
            loading={loading}
            messages={messages}
            messageScrollRef={messageScrollRef}
            mobile={mobileRoomLayout}
            newMessageCount={newMessageCount}
            onComposerChange={setComposer}
            onJumpToLatest={jumpToLatest}
            onRetryLoad={() => setLoadRetry((attempt) => attempt + 1)}
            onScroll={messageScrollChanged}
            onSubmit={(event) => void sendMessage(event)}
            resolveSender={resolveMessageSender}
            sending={sending}
          />
        </div>
      </div>

      {error && (
        <div className="guest-shell-error" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="Dismiss error" onClick={() => setError("")}><AppIcon name="x" /></button>
        </div>
      )}
    </main>
  );
}
