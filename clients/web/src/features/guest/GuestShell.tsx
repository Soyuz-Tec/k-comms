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
import type {
  Conversation,
  GuestSession,
  Message,
  RetainedSenderLabel,
  Session,
  SocketHandoff
} from "../../types";
import { GuestConversionPanel, type ConversionReceipt } from "./GuestConversionPanel";
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
import { useGuestParticipants } from "./useGuestParticipants";
import { useGuestRealtime } from "./useGuestRealtime";

const GuestCallPanel = lazy(() =>
  import("../calls/CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);


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
  const [showAccount, setShowAccount] = useState(false);
  const [showRoomMenu, setShowRoomMenu] = useState(false);
  const [converting, setConverting] = useState(false);
  const [conversionNotice, setConversionNotice] = useState("");
  const [conversionReceipt, setConversionReceipt] =
    useState<ConversionReceipt | null>(null);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const visibleMessageAuthorsRef = useRef<
    Array<{ senderUserId: string; messageId: string }>
  >([]);
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
    latestSequenceRef,
    mergeMessages,
    messages,
    requestCatchUp
  } = useGuestConversationFeed({
    api,
    conversationId: conversation.id,
    currentUserId: initialSession.user.id,
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
        handoffRealtime(result.socket_handoff);
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
