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
import { Link, useNavigate } from "react-router";
import type { ApiClient } from "../../api";
import {
  ApiError,
  GuestApiClient,
  loadStoredGuestSession,
  storeGuestSession
} from "../../api";
import { useSession } from "../../app/session";
import {
  browserName,
  clientMessageId,
  conversationTitle,
  errorText,
  formatDateTime,
  formatTime,
  initials
} from "../../lib/format";
import { RealtimeConversation, socketEndpoint } from "../../realtime";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  Conversation,
  ConversationMembership,
  GuestLinkPreview,
  GuestSession,
  InstantRoomPreview,
  InstantRoomResult,
  Message,
  ReactionEvent,
  Session,
  SocketHandoff
} from "../../types";
import {
  guestTokenFromFragment,
  scrubGuestTokenFragment
} from "./guestLink";
import {
  DelegatingRoomApi,
  type GuestRoomApi,
  MemberRoomApi
} from "./roomApi";
import {
  instantRoomJoinIdempotencyKey,
  rotateInstantRoomJoinIdempotencyKey
} from "../instant-room/idempotency";
import {
  capturedInstantRoomShareUrl,
  clearMemberInstantRoomContinuity,
  loadMemberInstantRoomContinuity,
  type MemberInstantRoomContinuity,
  storeMemberInstantRoomContinuity
} from "../instant-room/memberContinuity";
import "./GuestAccess.css";

const GuestCallPanel = lazy(() =>
  import("../calls/CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);

const apiBase = import.meta.env.VITE_API_BASE_URL || "";
const guestMessagePageSize = 200;
const maxGuestCatchUpPages = 100;

export async function loadGuestMessageCatchUp(
  api: Pick<GuestRoomApi, "messages">,
  afterSequence: number
): Promise<Message[]> {
  const messages: Message[] = [];
  let cursor = afterSequence;

  for (let pageNumber = 0; pageNumber < maxGuestCatchUpPages; pageNumber += 1) {
    const page = await api.messages(cursor, guestMessagePageSize);
    messages.push(...page.data);
    if (!page.page.has_more) return messages;

    const nextCursor = page.page.next_after_sequence;
    if (nextCursor === null || nextCursor <= cursor) {
      throw new Error("K-Comms could not safely continue conversation catch-up. Refresh and try again.");
    }
    cursor = nextCursor;
  }

  throw new Error("Conversation catch-up exceeded the safe page limit. Refresh to continue.");
}

export function GuestAccessPage() {
  const navigate = useNavigate();
  const {
    api: accountApi,
    session: accountSession,
    setSession: setAccountSession
  } = useSession();
  const [token] = useState(() => guestTokenFromFragment());
  const [entryShareUrl] = useState(() =>
    token ? capturedInstantRoomShareUrl(token) : null
  );
  const [accessEnded, setAccessEnded] = useState(false);
  const [guestSession, setGuestSessionState] = useState<GuestSession | null>(
    () => {
      if (token) {
        storeGuestSession(null);
        return null;
      }

      return loadStoredGuestSession();
    }
  );
  const [continuedSession, setContinuedSession] =
    useState<GuestSession | null>(null);
  const [memberContinuity, setMemberContinuity] =
    useState<MemberInstantRoomContinuity | null>(() =>
      !token && accountSession
        ? loadMemberInstantRoomContinuity(accountSession)
        : null
    );
  const [continuityError, setContinuityError] = useState("");
  const [continuityRetry, setContinuityRetry] = useState(0);
  const apiRef = useRef<GuestApiClient | null>(null);

  const setGuestSession = useCallback((
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ) => {
    if (reason === "access_ended") {
      setAccessEnded(true);
    } else if (session) {
      setAccessEnded(false);
    }
    storeGuestSession(session);
    setGuestSessionState(session);
  }, []);

  useLayoutEffect(() => {
    if (token) {
      clearMemberInstantRoomContinuity();
      scrubGuestTokenFragment();
    }
  }, [token]);

  useEffect(() => {
    if (!memberContinuity || !accountSession || token || guestSession) return;
    let current = true;
    setContinuityError("");
    void accountApi.conversation(memberContinuity.conversation.id)
      .then((conversation) => {
        if (!current) return;
        if (
          conversation.id !== memberContinuity.conversation.id ||
          conversation.archived_at
        ) {
          clearMemberInstantRoomContinuity();
          setMemberContinuity(null);
          return;
        }
        navigate(
          `/app?conversation=${encodeURIComponent(conversation.id)}`,
          { replace: true }
        );
        setMemberContinuity(null);
      })
      .catch((reason: unknown) => {
        if (!current) return;
        if (isDefinitiveRoomUnavailable(reason)) {
          clearMemberInstantRoomContinuity();
          setMemberContinuity(null);
          return;
        }
        setContinuityError(
          "K-Comms could not confirm this room. Retry to reopen the same conversation."
        );
      });
    return () => {
      current = false;
    };
  }, [
    accountApi,
    accountSession,
    continuityRetry,
    guestSession,
    memberContinuity,
    navigate,
    token
  ]);

  if (!apiRef.current) {
    apiRef.current = new GuestApiClient(apiBase, guestSession, setGuestSession);
  }
  const api = apiRef.current;
  api.setSession(guestSession);
  const roomApiRef = useRef<DelegatingRoomApi | null>(null);
  if (!roomApiRef.current) roomApiRef.current = new DelegatingRoomApi(api);
  const roomApi = roomApiRef.current;
  roomApi.setDelegate(
    continuedSession
      ? new MemberRoomApi(accountApi, continuedSession.conversation.id)
      : api
  );
  const activeRoomSession =
    continuedSession ||
    (guestSession && accountSession
      ? withoutGuestConversion(guestSession)
      : guestSession);

  if (memberContinuity && !activeRoomSession) {
    return (
      <main className="guest-entry" id="main-content">
        <section
          className="guest-entry-card"
          aria-labelledby="member-room-recovery-title"
        >
          <KCommsGuestBrand />
          <span className="guest-badge">Member room</span>
          <h1 id="member-room-recovery-title">Reopening your conversation…</h1>
          {continuityError ? (
            <>
              <p className="form-error" role="alert">{continuityError}</p>
              <button
                className="button primary full"
                type="button"
                onClick={() => setContinuityRetry((value) => value + 1)}
              >
                Retry
              </button>
            </>
          ) : (
            <p role="status">Confirming the room with your signed-in account.</p>
          )}
        </section>
      </main>
    );
  }

  if (activeRoomSession) {
    return (
      <GuestShell
        api={roomApi}
        initialSession={activeRoomSession}
        identityLabel={
          activeRoomSession.user.account_type === "guest" ? "Guest" : "Member"
        }
        onAccessEnded={() => {
          clearMemberInstantRoomContinuity();
          if (continuedSession || accountSession) {
            setAccessEnded(false);
            setGuestSession(null);
            setContinuedSession(null);
            navigate("/app", { replace: true });
            return;
          }
          setGuestSession(null, "access_ended");
        }}
        onLeave={() => {
          clearMemberInstantRoomContinuity();
          if (continuedSession || accountSession) {
            setAccessEnded(false);
            setGuestSession(null);
            if (continuedSession) {
              navigate(
                `/app?conversation=${encodeURIComponent(
                  continuedSession.conversation.id
                )}`,
                { replace: true }
              );
              return;
            }
            navigate(
              "/app",
              { replace: true }
            );
            return;
          }
          setAccessEnded(false);
          setGuestSession(null);
        }}
        onConverted={(session, conversation) => {
          if (accountSession && !continuedSession) {
            return;
          }
          if (
            guestSession?.capabilities.self_service_conversion === true
          ) {
            const registeredRoom = guestSession.instant_room
              ? {
                  ...guestSession.instant_room,
                  ...(guestSession.instant_room.owner_user_id ===
                  guestSession.user.id
                    ? { owner_kind: "registered" as const }
                    : {})
                }
              : undefined;
            const continued: GuestSession = {
              ...session,
              conversation,
              capabilities: {
                ...guestSession.capabilities,
                conversion_enabled: false,
                self_service_conversion: false
              },
              instant_room: registeredRoom,
              share_url: guestSession.share_url
            };
            if (registeredRoom && guestSession.share_url) {
              storeMemberInstantRoomContinuity(session, {
                room: registeredRoom,
                conversation,
                share_url: guestSession.share_url
              });
            }
            setGuestSession(null);
            setAccountSession(session);
            setContinuedSession(continued);
            return;
          }
          setGuestSession(null);
          setAccountSession(session);
          navigate(`/app?conversation=${encodeURIComponent(conversation.id)}`, {
            replace: true
          });
        }}
      />
    );
  }

  return (
      <GuestJoin
        api={api}
        accountApi={accountApi}
        accountSession={accountSession}
        token={token}
        accessEnded={accessEnded}
        onJoined={(session) => {
          const joinedSession =
            session.instant_room && entryShareUrl
              ? { ...session, share_url: entryShareUrl }
              : session;
          setGuestSession(
            accountSession
              ? withoutGuestConversion(joinedSession)
              : joinedSession
          );
        }}
        onAccountJoined={(result) => {
          if (accountSession && entryShareUrl) {
            storeMemberInstantRoomContinuity(accountSession, {
              room: result.room,
              conversation: result.conversation,
              share_url: entryShareUrl
            });
          }
          navigate(`/app?conversation=${encodeURIComponent(result.conversation.id)}`, {
            replace: true
          });
        }}
      />
  );
}

function GuestJoin({
  api,
  accountApi,
  accountSession,
  token,
  accessEnded,
  onJoined,
  onAccountJoined
}: {
  api: GuestApiClient;
  accountApi: ApiClient;
  accountSession: Session | null;
  token: string | null;
  accessEnded: boolean;
  onJoined: (session: GuestSession) => void;
  onAccountJoined: (result: InstantRoomResult) => void;
}) {
  const [preview, setPreview] = useState<
    GuestLinkPreview | InstantRoomPreview | null
  >(null);
  const [instantRoom, setInstantRoom] = useState(false);
  const [loading, setLoading] = useState(Boolean(token));
  const [joining, setJoining] = useState(false);
  const [joinAsGuest, setJoinAsGuest] = useState(false);
  const [error, setError] = useState("");
  const [previewRetryable, setPreviewRetryable] = useState(false);
  const [previewRetry, setPreviewRetry] = useState(0);
  const [retryAt, setRetryAt] = useState<number | null>(null);
  const [clock, setClock] = useState(Date.now());

  useEffect(() => {
    if (!token) return;
    let current = true;
    setLoading(true);
    setError("");
    setPreviewRetryable(false);
    void accountApi.previewInstantRoom(token).then((result) => {
      if (current) {
        setInstantRoom(true);
        setPreview(result);
        setRetryAt(null);
      }
    }).catch(async (reason: unknown) => {
      const legacyGuestLinkCandidate =
        reason instanceof ApiError &&
        (reason.status === 404 ||
          (reason.status === 503 && reason.code === "instant_rooms_unavailable"));

      if (!legacyGuestLinkCandidate) throw reason;
      const result = await api.previewGuestLink(token);
      if (current) {
        setInstantRoom(false);
        setPreview(result);
        setRetryAt(null);
      }
    }).catch((reason: unknown) => {
      if (current) {
        setError(guestLinkError(reason));
        setPreviewRetryable(isRetryableGuestLinkFailure(reason));
        setGuestRetryDeadline(reason, setRetryAt, setClock);
      }
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [accountApi, api, previewRetry, token]);

  useEffect(() => {
    if (!retryAt) return;
    const timer = window.setInterval(() => {
      const now = Date.now();
      setClock(now);
      if (now >= retryAt) setRetryAt(null);
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [retryAt]);

  const retrySeconds = retryAt
    ? Math.max(0, Math.ceil((retryAt - clock) / 1_000))
    : 0;
  const retryBlocked = retrySeconds > 0;

  const accountCanJoin = Boolean(accountSession && instantRoom);
  const legacyConversionOffered =
    preview !== null &&
    "conversion_enabled" in preview &&
    preview.conversion_enabled === true;

  async function joinWithAccount() {
    if (!token || !accountSession || retryBlocked) return;
    setJoining(true);
    setError("");
    try {
      const result = await joinInstantRoomWithReplayRecovery(
        token,
        "account",
        (idempotencyKey) =>
          accountApi.joinInstantRoom({ token }, idempotencyKey)
      );
      if (result.guest_session) {
        onJoined(withoutGuestConversion(result.guest_session));
        return;
      }
      onAccountJoined(result);
    } catch (reason: unknown) {
      setError(guestLinkError(reason));
      setGuestRetryDeadline(reason, setRetryAt, setClock);
    } finally {
      setJoining(false);
    }
  }

  async function join(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!token) return;
    const values = new FormData(event.currentTarget);
    const displayName = String(values.get("display_name") || "").trim();
    if (!displayName || retryBlocked) return;

    setJoining(true);
    setError("");
    try {
      const input = {
        token,
        display_name: displayName,
        device: { name: browserName(), platform: "web" as const }
      };
      onJoined(
        instantRoom
          ? await joinInstantRoomWithReplayRecovery(
              token,
              "guest",
              (idempotencyKey) =>
                api.joinInstantRoom(input, idempotencyKey)
            )
          : await api.joinGuest(input)
      );
    } catch (reason: unknown) {
      setError(guestLinkError(reason));
      setGuestRetryDeadline(reason, setRetryAt, setClock);
    } finally {
      setJoining(false);
    }
  }

  return (
    <main className="guest-entry" id="main-content">
      <section className="guest-entry-card" aria-labelledby="guest-entry-title">
        <KCommsGuestBrand />
        {loading ? (
          <div className="guest-entry-loading" role="status">
            <span className="spinner" aria-hidden="true" />
            <h1 id="guest-entry-title">Checking your secure link…</h1>
          </div>
        ) : preview ? (
          <>
            <span className="guest-badge">Guest access</span>
            <h1 id="guest-entry-title">{preview.room_title}</h1>
            <p>
              {legacyConversionOffered
                ? "Join this room now. No account is required. Optional account creation needs the separate one-time code from the host."
                : "Join this room now without creating an account. This link provides temporary communication access only."}
            </p>
            {accountCanJoin && !joinAsGuest ? (
              <div className="guest-join-form">
                <button
                  className="button primary full"
                  type="button"
                  disabled={joining || retryBlocked}
                  onClick={() => void joinWithAccount()}
                >
                  {retryBlocked
                    ? `Try again in ${retrySeconds}s`
                    : joining
                    ? "Joining room…"
                    : `Join as ${accountSession?.user.display_name}`}
                </button>
                <button
                  className="button ghost full"
                  type="button"
                  disabled={joining || retryBlocked}
                  onClick={() => setJoinAsGuest(true)}
                >
                  Use a guest name instead
                </button>
              </div>
            ) : (
            <form className="guest-join-form" onSubmit={(event) => void join(event)}>
              <label className="field">
                Your display name
                <input
                  name="display_name"
                  type="text"
                  minLength={1}
                  maxLength={120}
                  autoComplete="name"
                  autoFocus
                  required
                  placeholder="How people should see you"
                />
              </label>
              <button
                className="button primary full"
                type="submit"
                disabled={joining || retryBlocked}
              >
                {retryBlocked
                  ? `Try again in ${retrySeconds}s`
                  : joining
                    ? "Joining room…"
                    : "Join conversation"}
              </button>
            </form>
            )}
            <small className="guest-expiry">
              {preview.expires_at
                ? `This invitation expires ${formatDateTime(preview.expires_at)}.`
                : instantRoom
                  ? "This room stays active while someone is connected. Its idle countdown starts after the last person leaves."
                  : "The host controls when this invitation ends."}
            </small>
          </>
        ) : (
          <>
            <span className="guest-badge neutral">Guest link</span>
            <h1 id="guest-entry-title">
              {token
                ? previewRetryable
                  ? "We could not check this guest link"
                  : "This guest link is unavailable"
                : accessEnded
                  ? "Guest access has ended"
                  : "Open a K-Comms guest link"}
            </h1>
            <p>
              {token
                ? previewRetryable
                  ? "Your secure link is unchanged. Retry it here when K-Comms is available."
                  : "It may have expired, reached its guest limit or been revoked. Ask the room host for a new link."
                : accessEnded
                  ? "This guest session expired or was revoked. Ask the room host for a new link."
                  : "Scan the room QR code or open the unique link shared by its host."}
            </p>
            <div className="guest-entry-actions">
              {token && previewRetryable && (
                <button
                  className="button primary full"
                  type="button"
                  disabled={retryBlocked}
                  onClick={() => {
                    if (retryBlocked) return;
                    setRetryAt(null);
                    setPreviewRetry((attempt) => attempt + 1);
                  }}
                >
                  {retryBlocked
                    ? `Try again in ${retrySeconds}s`
                    : "Retry secure link"}
                </button>
              )}
              <Link
                className={`button ${
                  token && previewRetryable ? "ghost" : "primary"
                } full`}
                to="/sign-in"
              >
                Return to K-Comms sign in
              </Link>
            </div>
          </>
        )}
        {error && <p className="form-error" role="alert">{error}</p>}
      </section>
    </main>
  );
}

async function joinInstantRoomWithReplayRecovery<T>(
  token: string,
  mode: "account" | "guest",
  join: (idempotencyKey: string) => Promise<T>
): Promise<T> {
  const idempotencyKey = await instantRoomJoinIdempotencyKey(token, mode);
  try {
    return await join(idempotencyKey);
  } catch (reason: unknown) {
    if (isExpiredReplay(reason)) {
      return join(await rotateInstantRoomJoinIdempotencyKey(token, mode));
    }
    if (isTransientJoinFailure(reason)) {
      await waitForRetry();
      try {
        return await join(idempotencyKey);
      } catch (retryReason: unknown) {
        if (isExpiredReplay(retryReason)) {
          return join(await rotateInstantRoomJoinIdempotencyKey(token, mode));
        }
        throw retryReason;
      }
    }
    throw reason;
  }
}

function isExpiredReplay(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    reason.status === 409 &&
    reason.code === "idempotency_replay_expired"
  );
}

function isTransientJoinFailure(reason: unknown): boolean {
  return (
    reason instanceof TypeError ||
    (reason instanceof ApiError && reason.status >= 500)
  );
}

function isRetryableGuestLinkFailure(reason: unknown): boolean {
  return (
    reason instanceof TypeError ||
    (reason instanceof ApiError &&
      (reason.status === 429 || reason.status >= 500))
  );
}

function setGuestRetryDeadline(
  reason: unknown,
  setRetryAt: (deadline: number | null) => void,
  setClock: (now: number) => void
): void {
  const retryAfter =
    reason instanceof ApiError ? reason.retryAfterSeconds : undefined;
  const now = Date.now();
  setClock(now);
  setRetryAt(retryAfter && retryAfter > 0 ? now + retryAfter * 1_000 : null);
}

function waitForRetry(): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, 350));
}

function withoutGuestConversion(session: GuestSession): GuestSession {
  return {
    ...session,
    capabilities: {
      ...session.capabilities,
      conversion_enabled: false,
      self_service_conversion: false,
      email_hint: null
    }
  };
}

function isDefinitiveRoomUnavailable(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    [401, 403, 404, 410].includes(reason.status)
  );
}

export function GuestShell({
  api,
  initialSession,
  onLeave,
  onAccessEnded,
  onConverted,
  roomBanner,
  identityLabel = "Guest",
  initialPresenceCount = 1,
  onPresenceChange
}: {
  api: GuestRoomApi;
  initialSession: GuestSession;
  onLeave: () => void;
  onAccessEnded?: () => void;
  onConverted: (
    session: Session,
    conversation: Conversation,
    socketHandoff?: SocketHandoff
  ) => void;
  roomBanner?: ReactNode;
  identityLabel?: "Guest" | "Host" | "Member";
  initialPresenceCount?: number;
  onPresenceChange?: (count: number) => void;
}) {
  const [conversation, setConversation] = useState(initialSession.conversation);
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const [messages, setMessages] = useState<Message[]>([]);
  const [composer, setComposer] = useState("");
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [loadRetry, setLoadRetry] = useState(0);
  const [sending, setSending] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("connecting");
  const [onlineUsers, setOnlineUsers] = useState(initialPresenceCount);
  const [realtimeHandoffVersion, setRealtimeHandoffVersion] = useState(0);
  const [error, setError] = useState("");
  const [showAccount, setShowAccount] = useState(false);
  const [converting, setConverting] = useState(false);
  const [conversionNotice, setConversionNotice] = useState("");
  const [realtimeCall, setRealtimeCall] = useState<CallRealtimeEvent | null>(null);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const socketHandoffTicketRef = useRef<string | null>(null);
  const latestSequenceRef = useRef(0);
  const knownMessageIdsRef = useRef(new Set<string>());
  const nearBottomRef = useRef(true);
  const scrollRequestRef = useRef<ScrollBehavior | null>("auto");
  const lastMarkedReadRef = useRef(0);
  const messageScrollRef = useRef<HTMLDivElement | null>(null);
  const composerRef = useRef<HTMLTextAreaElement | null>(null);
  const accountToggleRef = useRef<HTMLButtonElement | null>(null);
  const accountEmailRef = useRef<HTMLInputElement | null>(null);
  const accountWasOpenRef = useRef(false);
  const onAccessEndedRef = useRef(onAccessEnded);
  onAccessEndedRef.current = onAccessEnded;
  const selfServiceConversion =
    initialSession.capabilities.self_service_conversion === true;
  const conversionEnabled =
    initialSession.capabilities.conversion_enabled === true ||
    selfServiceConversion;

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

  const reloadMembers = useCallback(() => {
    void api.conversationMembers()
      .then(setMembers)
      .catch((reason: unknown) => setError(errorText(reason)));
  }, [api]);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setLoadError("");
    setError("");
    void Promise.all([
      api.conversation(),
      api.conversationMembers(),
      loadGuestMessageCatchUp(api, 0)
    ]).then(([nextConversation, nextMembers, nextMessages]) => {
      if (!current) return;
      setConversation(nextConversation);
      setMembers(nextMembers);
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
  }, [api, loadRetry, mergeMessages]);

  useEffect(() => {
    if (import.meta.env.VITE_DISABLE_REALTIME === "true") {
      setConnectionStatus("offline");
      return;
    }
    let current = true;
    let realtime: RealtimeConversation | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempts = 0;
    let connecting = false;

    function scheduleReconnect() {
      if (!current || reconnectTimer !== null) return;
      const delay = Math.min(15_000, 1_000 * (2 ** reconnectAttempts));
      reconnectAttempts += 1;
      setConnectionStatus("reconnecting");
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
              if (status === "live") reconnectAttempts = 0;
              setConnectionStatus(status);
            },
            onMessages: (nextMessages) => mergeMessages(nextMessages, {
              announce: true,
              behavior: "smooth"
            }),
            onReactionAdded: (event) => applyReaction(event, true),
            onReactionRemoved: (event) => applyReaction(event, false),
            onRead: () => undefined,
            onMembershipChanged: reloadMembers,
            onConversationChanged: () => {
              void api.conversation().then(setConversation).catch(() => undefined);
            },
            onCallStarted: setRealtimeCall,
            onCallEnded: setRealtimeCall,
            onAudioCallStarted: setRealtimeCall,
            onAudioCallEnded: setRealtimeCall,
            onCatchUpRequired: (afterSequence) => {
              void loadGuestMessageCatchUp(api, afterSequence)
                .then((nextMessages) => mergeMessages(nextMessages, {
                  announce: true,
                  behavior: "smooth"
                }))
                .catch((reason: unknown) => setError(errorText(reason)));
            },
            onTyping: () => undefined,
            onPresence: (count) => {
              setOnlineUsers(count);
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
            setConnectionStatus("offline");
            setError("Guest access has ended. Ask the room host for a new link.");
            onAccessEndedRef.current?.();
          } else {
            setConnectionStatus("offline");
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
    onPresenceChange,
    realtimeHandoffVersion,
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
      accountToggleRef.current?.focus();
    }
  }, [showAccount]);

  useEffect(() => {
    if (conversionNotice) composerRef.current?.focus();
  }, [conversionNotice]);

  const usersById = useMemo(
    () => new Map(members.map((member) => [member.user.id, member.user])),
    [members]
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

  async function leave() {
    setLeaving(true);
    setError("");
    try {
      await api.logout();
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      onLeave();
      setLeaving(false);
    }
  }

  async function convertAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
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
        setConnectionStatus("connecting");
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

  return (
    <main className="guest-shell" id="main-content">
      <header className="guest-shell-header">
        <KCommsGuestBrand />
        <div className="guest-room-heading">
            <span className="guest-badge">{identityLabel}</span>
          <div>
            <h1>{conversationTitle(conversation)}</h1>
            <p>
              {initialSession.tenant.name} · {onlineUsers}{" "}
              {onlineUsers === 1 ? "person" : "people"} online ·{" "}
              <span
                className={`guest-connection ${connectionStatus}`}
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                {connectionStatus}
              </span>
            </p>
          </div>
        </div>
        <div className="guest-shell-actions">
          {conversionEnabled && (
            <button
              ref={accountToggleRef}
              className="button ghost"
              type="button"
              aria-expanded={showAccount}
              aria-controls="guest-account-conversion"
              onClick={() => setShowAccount((value) => !value)}
            >
              Create account
            </button>
          )}
          <button className="button danger" type="button" disabled={leaving} onClick={() => void leave()}>
            {leaving ? "Leaving…" : "Leave"}
          </button>
        </div>
      </header>

      <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {conversionNotice}
      </p>

      {roomBanner}

      {conversionEnabled && showAccount && (
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
                required
              />
              <small>At least 12 characters; the server applies the final password policy.</small>
            </label>
            <button className="button primary" type="submit" disabled={converting}>
              {converting ? "Creating account…" : "Create account"}
            </button>
            <button className="button ghost" type="button" onClick={() => setShowAccount(false)}>
              Not now
            </button>
          </form>
        </section>
      )}

      <section className="guest-room" aria-label={conversationTitle(conversation)}>
        <div
          ref={messageScrollRef}
          className="guest-message-scroll"
          aria-busy={loading}
          onScroll={messageScrollChanged}
        >
          {loading ? (
            <div className="inline-loading" role="status">
              <span className="spinner" aria-hidden="true" />Loading conversation…
            </div>
          ) : loadError ? (
            <div className="empty-state guest-load-error" role="alert">
              <span className="empty-mark" aria-hidden="true">!</span>
              <h2>Could not load this conversation</h2>
              <p>{loadError}</p>
              <button
                className="button primary"
                type="button"
                onClick={() => setLoadRetry((attempt) => attempt + 1)}
              >
                Retry conversation
              </button>
            </div>
          ) : messages.length === 0 ? (
            <div className="empty-state">
              <span className="empty-mark" aria-hidden="true">✦</span>
              <h2>Start the conversation</h2>
              <p>
                {identityLabel === "Guest"
                  ? "You joined as a guest. "
                  : "Your room is ready. "}
                Send a message whenever you’re ready.
              </p>
            </div>
          ) : (
            <ol className="guest-message-list">
              {messages.map((message) => {
                const sender = usersById.get(message.sender_user_id);
                return (
                  <li key={message.id} className={message.sender_user_id === initialSession.user.id ? "mine" : ""}>
                    <span className="avatar" aria-hidden="true">
                      {initials(sender?.display_name || "Guest")}
                    </span>
                    <div>
                      <div className="guest-message-meta">
                        <strong>{sender?.display_name || "Room member"}</strong>
                        {sender?.account_type === "guest" && <span className="guest-badge compact">Guest</span>}
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
              {newMessageCount} new {newMessageCount === 1 ? "message" : "messages"} · Jump to latest
            </button>
          </div>
        )}
        <form className="guest-composer" onSubmit={(event) => void sendMessage(event)}>
          <label className="sr-only" htmlFor="guest-message-composer">Message</label>
          <textarea
            ref={composerRef}
            id="guest-message-composer"
            rows={2}
            maxLength={65_535}
            value={composer}
            readOnly={sending || loading || Boolean(loadError)}
            aria-busy={sending}
            aria-disabled={loading || Boolean(loadError)}
            autoFocus
            placeholder={`Message ${conversationTitle(conversation)}`}
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
            disabled={sending || loading || Boolean(loadError) || !composer.trim()}
          >
            {sending ? "Sending…" : "Send"}
          </button>
        </form>
      </section>

      <Suspense fallback={<span className="visually-hidden" role="status">Preparing call controls…</span>}>
        <GuestCallPanel
          api={api}
          conversation={conversation}
          audioEnabled={initialSession.capabilities.allow_audio_calls}
          videoEnabled={initialSession.capabilities.allow_video_calls}
          currentUserDisplayName={initialSession.user.display_name}
          realtimeEvent={realtimeCall}
        />
      </Suspense>

      {error && (
        <div className="guest-shell-error" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="Dismiss error" onClick={() => setError("")}>×</button>
        </div>
      )}
    </main>
  );
}

function KCommsGuestBrand() {
  return (
    <div className="guest-brand" aria-label="K-Comms">
      <span aria-hidden="true">K</span>
      <strong>K-Comms</strong>
    </div>
  );
}

function guestLinkError(reason: unknown): string {
  if (reason instanceof ApiError) {
    if (reason.status === 429) {
      return reason.retryAfterSeconds
        ? `Too many attempts. Try again in ${reason.retryAfterSeconds} seconds.`
        : "Too many attempts. Wait a moment, then try again.";
    }
    if (reason.status >= 500) {
      return "K-Comms is temporarily unavailable. Your link is unchanged; try again shortly.";
    }
    if (
      [404, 410, 422].includes(reason.status) ||
      /expired|revoked|unavailable|exhausted/u.test(reason.code)
    ) {
      return "This communication link is unavailable. It may have expired or been revoked. Ask the host for a new link.";
    }
  }
  const message = errorText(reason);
  return message === "Something went wrong. Please try again."
    ? "This guest link is no longer available. Ask the host for a new link."
    : message;
}
