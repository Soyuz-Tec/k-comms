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
import {
  AppMenuTrigger,
  AppSurfaceControlButton
} from "../../components/AppMenuControls";
import { DraggableSurface } from "../../components/DraggableSurface";
import {
  clientMessageId,
  conversationTitle,
  errorText
} from "../../lib/format";
import type {
  CallMediaKind,
  Conversation,
  GuestSession,
  Message,
  RetainedSenderLabel,
  Session,
  SocketHandoff
} from "../../types";
import { GuestConversionPanel } from "./GuestConversionPanel";
import { GuestMessageMenu } from "./GuestMessageMenu";
import { GuestMessageViewport } from "./GuestMessageViewport";
import { GuestRoomMenu } from "./GuestRoomMenu";
import { ParticipantRoster } from "./ParticipantRoster";
import type { GuestRoomApi } from "./roomApi";
import type { CallReadinessMode } from "../calls/callReadinessNavigation";
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
  openRoomMenuOnEntry = false,
  initialCallOnEntry = null,
  initialCallReadinessMode = null,
  onInitialCallConsumed,
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
  openRoomMenuOnEntry?: boolean;
  initialCallOnEntry?: CallMediaKind | null;
  initialCallReadinessMode?: CallReadinessMode | null;
  onInitialCallConsumed?: () => void;
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
  const [showMessageMenu, setShowMessageMenu] = useState(false);
  const [messagesOpen, setMessagesOpen] = useState(true);
  const visibleMessageAuthorsRef = useRef<
    Array<{ senderUserId: string; messageId: string }>
  >([]);
  const accountToggleRef = useRef<HTMLButtonElement | null>(null);
  const accountReturnFocusRef = useRef<HTMLButtonElement | null>(null);
  const roomMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const messageMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const roomHeadingRef = useRef<HTMLHeadingElement | null>(null);
  const accountEmailRef = useRef<HTMLInputElement | null>(null);
  const accountWasOpenRef = useRef(false);
  const restoreRoomHeadingFocusRef = useRef(false);
  const roomMenuTriggerFocusedRef = useRef(false);
  const openedRoomMenuOnEntryRef = useRef(false);
  const mobileRoomLayout = useMobileRoomLayout();
  const usesRoomMenu = mobileRoomLayout || whiteboardEnabled;

  useEffect(() => {
    if (
      openedRoomMenuOnEntryRef.current ||
      !openRoomMenuOnEntry ||
      !usesRoomMenu ||
      !roomMenuInvite
    ) {
      return;
    }
    openedRoomMenuOnEntryRef.current = true;
    setShowRoomMenu(true);
  }, [openRoomMenuOnEntry, roomMenuInvite, usesRoomMenu]);
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
    if (!usesRoomMenu && showRoomMenu) {
      restoreRoomHeadingFocusRef.current = true;
      setShowRoomMenu(false);
    } else if (!usesRoomMenu && roomMenuTriggerFocusedRef.current) {
      roomMenuTriggerFocusedRef.current = false;
      roomHeadingRef.current?.focus();
    }
  }, [showRoomMenu, usesRoomMenu]);

  useLayoutEffect(() => {
    if (!usesRoomMenu && !showRoomMenu && restoreRoomHeadingFocusRef.current) {
      restoreRoomHeadingFocusRef.current = false;
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          if (roomHeadingRef.current?.isConnected) {
            roomHeadingRef.current.focus();
          }
        });
      });
    }
  }, [showRoomMenu, usesRoomMenu]);

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
    if (whiteboardEnabled) setMessagesOpen(true);
    window.requestAnimationFrame(() => {
      composerRef.current?.focus();
      composerRef.current?.scrollIntoView?.({ block: "nearest" });
    });
  }, [whiteboardEnabled, composerRef]);

  const closeMessageMenu = useCallback(() => {
    setShowMessageMenu(false);
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

  const roomTitle = conversationTitle(conversation);
  const roomMeta = (
    <>
      {presenceKnown
        ? `${onlineUsers} ${onlineUsers === 1 ? "person" : "people"} online`
        : "presence unknown"}{" "}
      ·{" "}
      <span
        className={`guest-connection ${connectionStatus}`}
        role={mobileRoomLayout && !whiteboardEnabled ? undefined : "status"}
        aria-live={mobileRoomLayout && !whiteboardEnabled ? undefined : "polite"}
        aria-atomic={mobileRoomLayout && !whiteboardEnabled ? undefined : "true"}
      >
        {connectionStatus}
      </span>
    </>
  );
  const participantRoster = (
    <ParticipantRoster
      members={members}
      onlineUserIds={onlineUserIds}
      currentUserId={initialSession.user.id}
      presenceKnown={presenceKnown}
      compact={whiteboardEnabled || mobileRoomLayout}
    />
  );
  const callPanel = (
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
        launchRequest={initialCallOnEntry}
        launchReadinessMode={initialCallReadinessMode}
        onLaunchRequestConsumed={onInitialCallConsumed}
        onOpenChat={openRoomChat}
      />
    </Suspense>
  );
  const messageViewport = (
    <GuestMessageViewport
      autoFocus={!roomBanner && !whiteboardEnabled}
      composer={composer}
      composerRef={composerRef}
      conversationTitle={roomTitle}
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
  );

  return (
    <main
      className={`guest-shell${mobileRoomLayout ? " compact-room-layout" : ""}${
        whiteboardEnabled ? " canvas-room-layout" : ""
      }`}
      id="main-content"
    >
      {whiteboardEnabled ? (
        <>
          <h1 ref={roomHeadingRef} className="visually-hidden" tabIndex={-1}>
            {roomTitle}
          </h1>
          <p className="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
            {presenceKnown
              ? `${onlineUsers} ${onlineUsers === 1 ? "person" : "people"} online`
              : "presence unknown"}{" "}
            · {connectionStatus}
          </p>
          <div className="guest-floating-room-launcher">
            <AppMenuTrigger
              ref={roomMenuTriggerRef}
              className="guest-room-controls-trigger"
              accessibleLabel="Open room controls"
              controls="guest-room-menu"
              expanded={showRoomMenu}
              overlay
              title="Room controls"
              onFocus={() => {
                roomMenuTriggerFocusedRef.current = true;
              }}
              onClick={() => {
                setShowMessageMenu(false);
                setShowRoomMenu(true);
              }}
            />
          </div>
        </>
      ) : (
        <header className="guest-shell-header">
          <div className="guest-room-heading">
            <span className="guest-badge">{identityLabel}</span>
            <div>
              <h1 ref={roomHeadingRef} tabIndex={-1}>{roomTitle}</h1>
              <p
                role={mobileRoomLayout ? "status" : undefined}
                aria-live={mobileRoomLayout ? "polite" : undefined}
                aria-atomic={mobileRoomLayout ? "true" : undefined}
              >
                <span className="guest-room-workspace">
                  {initialSession.tenant.name} ·{" "}
                </span>
                {roomMeta}
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
                  <AppIcon name="logIn" /> Sign in
                </Link>
              )}
              <button className="button danger" type="button" disabled={leaving} onClick={leave}>
                <AppIcon name="logOut" /> {leaving ? "Leaving…" : "Leave"}
              </button>
            </div>
          )}
        </header>
      )}

      {(whiteboardEnabled || showRoomMenu) && (
        <GuestRoomMenu
          canKeepRoom={conversionEnabled && !conversionReceipt}
          callContent={whiteboardEnabled ? callPanel : undefined}
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
          open={showRoomMenu}
          participantContent={whiteboardEnabled ? participantRoster : undefined}
          roomMeta={whiteboardEnabled ? roomMeta : undefined}
          roomTitle={whiteboardEnabled ? roomTitle : undefined}
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

      {!whiteboardEnabled && (!mobileRoomLayout || !roomMenuInvite) &&
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

      {!whiteboardEnabled && participantRoster}
      {!whiteboardEnabled && (
        <section className="guest-live-tools" aria-label="Room call">
          <div>
            <strong>Talk live</strong>
            <span>Start or join without losing the room conversation.</span>
          </div>
          {callPanel}
        </section>
      )}

      <div
        className={`guest-collaboration-workspace${
          whiteboardEnabled ? " canvas-workspace" : " without-whiteboard"
        }`}
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
                conversationTitle={roomTitle}
                collaborationOptions={whiteboardOptions}
                compact
              />
            </Suspense>
          </div>
        )}
        {whiteboardEnabled ? (
          <DraggableSurface
            className={`guest-floating-chat${messagesOpen ? "" : " is-collapsed"}`}
            dragLabel="messages"
          >
            <div className="guest-floating-chat-heading">
              <AppMenuTrigger
                ref={messageMenuTriggerRef}
                className="guest-message-menu-trigger"
                accessibleLabel="Open message menu"
                controls="guest-message-menu"
                expanded={showMessageMenu}
                popup="menu"
                title="Message menu"
                onClick={() => {
                  setMessagesOpen(true);
                  setShowMessageMenu((current) => !current);
                }}
              />
              <strong>Messages</strong>
              {newMessageCount > 0 && (
                <span className="guest-tool-count" aria-label={`${newMessageCount} unread`}>
                  {newMessageCount}
                </span>
              )}
              <AppSurfaceControlButton
                accessibleLabel={messagesOpen ? "Collapse messages" : "Expand messages"}
                kind={messagesOpen ? "minimize" : "restore"}
                onClick={() => {
                  setShowMessageMenu(false);
                  setMessagesOpen((current) => !current);
                }}
              />
            </div>
            {showMessageMenu && (
              <GuestMessageMenu
                onClose={closeMessageMenu}
                onFocusComposer={openRoomChat}
                onJumpToLatest={() => {
                  setMessagesOpen(true);
                  window.requestAnimationFrame(jumpToLatest);
                }}
                triggerRef={messageMenuTriggerRef}
              />
            )}
            {messagesOpen && (
              <div className="guest-chat-panel" aria-label="Room messages">
                {messageViewport}
              </div>
            )}
          </DraggableSurface>
        ) : (
          <div className="guest-chat-panel" aria-label="Room messages">
            {messageViewport}
          </div>
        )}
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
