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
import type { FormEvent } from "react";
import { Link, useNavigate } from "react-router";
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
  Message,
  ReactionEvent,
  Session
} from "../../types";
import {
  guestTokenFromFragment,
  scrubGuestTokenFragment
} from "./guestLink";
import "./GuestAccess.css";

const GuestCallPanel = lazy(() =>
  import("../calls/CallPanel").then(({ CallPanel }) => ({ default: CallPanel }))
);

const apiBase = import.meta.env.VITE_API_BASE_URL || "";
const guestMessagePageSize = 200;
const maxGuestCatchUpPages = 100;

export async function loadGuestMessageCatchUp(
  api: Pick<GuestApiClient, "messages">,
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
  const { setSession: setAccountSession } = useSession();
  const [token] = useState(() => guestTokenFromFragment());
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
    if (token) scrubGuestTokenFragment();
  }, [token]);

  if (!apiRef.current) {
    apiRef.current = new GuestApiClient(apiBase, guestSession, setGuestSession);
  }
  const api = apiRef.current;
  api.setSession(guestSession);

  if (guestSession) {
    return (
      <GuestShell
        api={api}
        initialSession={guestSession}
        onLeave={() => {
          setAccessEnded(false);
          setGuestSession(null);
        }}
        onConverted={(session, conversation) => {
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
      token={token}
      accessEnded={accessEnded}
      onJoined={setGuestSession}
    />
  );
}

function GuestJoin({
  api,
  token,
  accessEnded,
  onJoined
}: {
  api: GuestApiClient;
  token: string | null;
  accessEnded: boolean;
  onJoined: (session: GuestSession) => void;
}) {
  const [preview, setPreview] = useState<GuestLinkPreview | null>(null);
  const [loading, setLoading] = useState(Boolean(token));
  const [joining, setJoining] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!token) return;
    let current = true;
    setLoading(true);
    setError("");
    void api.previewGuestLink(token).then((result) => {
      if (current) setPreview(result);
    }).catch((reason: unknown) => {
      if (current) setError(guestLinkError(reason));
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [api, token]);

  async function join(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!token) return;
    const values = new FormData(event.currentTarget);
    const displayName = String(values.get("display_name") || "").trim();
    if (!displayName) return;

    setJoining(true);
    setError("");
    try {
      onJoined(await api.joinGuest({
        token,
        display_name: displayName,
        device: { name: browserName(), platform: "web" }
      }));
    } catch (reason: unknown) {
      setError(guestLinkError(reason));
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
              {preview.conversion_enabled === true
                ? "Join this room now. No account is required. Optional account creation needs the separate one-time code from the host."
                : "Join this room now without creating an account. This link provides temporary communication access only."}
            </p>
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
              <button className="button primary full" type="submit" disabled={joining}>
                {joining ? "Joining room…" : "Join conversation"}
              </button>
            </form>
            <small className="guest-expiry">
              This invitation expires {formatDateTime(preview.expires_at)}.
            </small>
          </>
        ) : (
          <>
            <span className="guest-badge neutral">Guest link</span>
            <h1 id="guest-entry-title">
              {token
                ? "This guest link is unavailable"
                : accessEnded
                  ? "Guest access has ended"
                  : "Open a K-Comms guest link"}
            </h1>
            <p>
              {token
                ? "It may have expired, reached its guest limit or been revoked. Ask the room host for a new link."
                : accessEnded
                  ? "This guest session expired or was revoked. Ask the room host for a new link."
                  : "Scan the room QR code or open the unique link shared by its host."}
            </p>
            <div className="guest-entry-actions">
              <Link className="button primary full" to="/app">
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

function GuestShell({
  api,
  initialSession,
  onLeave,
  onConverted
}: {
  api: GuestApiClient;
  initialSession: GuestSession;
  onLeave: () => void;
  onConverted: (session: Session, conversation: Conversation) => void;
}) {
  const [conversation, setConversation] = useState(initialSession.conversation);
  const [members, setMembers] = useState<ConversationMembership[]>([]);
  const [messages, setMessages] = useState<Message[]>([]);
  const [composer, setComposer] = useState("");
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("connecting");
  const [error, setError] = useState("");
  const [showAccount, setShowAccount] = useState(false);
  const [converting, setConverting] = useState(false);
  const [realtimeCall, setRealtimeCall] = useState<CallRealtimeEvent | null>(null);
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const realtimeRef = useRef<RealtimeConversation | null>(null);
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
  const conversionEnabled = initialSession.capabilities.conversion_enabled === true;

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
      if (current) setError(errorText(reason));
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [api, mergeMessages]);

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
        const { ticket } = await api.socketTicket();
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
            onPresence: () => undefined,
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
  }, [api, applyReaction, conversation.id, mergeMessages, reloadMembers]);

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

  const usersById = useMemo(
    () => new Map(members.map((member) => [member.user.id, member.user])),
    [members]
  );

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = composer.trim();
    if (!body || sending) return;
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
    setError("");
    try {
      const result = await api.convertAccount({
        email: String(values.get("email") || "").trim(),
        verification_code: String(values.get("verification_code") || "").trim(),
        password: String(values.get("password") || "")
      });
      onConverted(result.session, result.conversation);
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
          <span className="guest-badge">Guest</span>
          <div>
            <h1>{conversationTitle(conversation)}</h1>
            <p>
              {initialSession.tenant.name} ·{" "}
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

      {conversionEnabled && showAccount && (
        <section
          className="guest-account-card"
          id="guest-account-conversion"
          aria-labelledby="guest-account-title"
        >
          <div>
            <h2 id="guest-account-title">Keep your conversation</h2>
            <p id="guest-account-email-help">
              Enter the full email authorized by the host
              {initialSession.capabilities.email_hint
                ? <> ({initialSession.capabilities.email_hint})</>
                : null}
              , plus the one-time verification code the host sent separately.
              Your identity and conversation history stay in place.
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
            <div className="field">
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
            </div>
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
          ) : messages.length === 0 ? (
            <div className="empty-state">
              <span className="empty-mark" aria-hidden="true">✦</span>
              <h2>Start the conversation</h2>
              <p>You joined as a guest. Send a message whenever you’re ready.</p>
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
            readOnly={sending}
            aria-busy={sending}
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
          <button className="button primary" type="submit" disabled={sending || !composer.trim()}>
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
  const message = errorText(reason);
  return message === "Something went wrong. Please try again."
    ? "This guest link is no longer available. Ask the host for a new link."
    : message;
}
