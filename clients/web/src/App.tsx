import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ChangeEvent, FormEvent } from "react";
import {
  ApiClient,
  ApiError,
  downloadUrl,
  loadStoredSession,
  sha256,
  storeSession,
  uploadToPresignedTarget
} from "./api";
import type {
  BootstrapInput,
  CreateConversationInput,
  CreateUserInput,
  LoginInput
} from "./api";
import { RealtimeConversation, socketEndpoint } from "./realtime";
import type {
  Attachment,
  ConnectionStatus,
  Conversation,
  Message,
  ReactionEvent,
  ReadCursorEvent,
  Session,
  User
} from "./types";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";
const quickReactions = ["👍", "❤️", "🎉", "👀"];

interface PendingAttachment {
  attachment: Attachment;
  localName: string;
}

export default function App() {
  const [session, setSession] = useState<Session | null>(() => loadStoredSession());
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>("offline");
  const [onlineUsers, setOnlineUsers] = useState(0);
  const [typingUsers, setTypingUsers] = useState<Set<string>>(() => new Set());
  const [readCursors, setReadCursors] = useState<Record<string, number>>({});
  const [workspaceLoading, setWorkspaceLoading] = useState(Boolean(session));
  const [messagesLoading, setMessagesLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [showCreateConversation, setShowCreateConversation] = useState(false);
  const [showCreateUser, setShowCreateUser] = useState(false);

  const realtimeRef = useRef<RealtimeConversation | null>(null);
  const latestSequenceRef = useRef(0);
  const typingTimerRef = useRef<number | null>(null);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);

  const commitSession = useCallback((next: Session | null) => {
    storeSession(next);
    setSession(next);
  }, []);

  const apiRef = useRef<ApiClient | null>(null);
  if (!apiRef.current) apiRef.current = new ApiClient(apiBase, session, commitSession);
  const api = apiRef.current;
  api.setSession(session);

  const activeConversation = useMemo(
    () => conversations.find((conversation) => conversation.id === activeConversationId) || null,
    [activeConversationId, conversations]
  );
  const usersById = useMemo(
    () => new Map(users.map((user) => [user.id, user])),
    [users]
  );

  const receiveMessages = useCallback((incoming: Message[]) => {
    if (incoming.length === 0) return;
    setMessages((current) => {
      const byId = new Map(current.map((message) => [message.id, message]));
      incoming.forEach((message) => byId.set(message.id, message));
      const merged = [...byId.values()].sort(
        (left, right) => left.conversation_sequence - right.conversation_sequence
      );
      latestSequenceRef.current = merged.at(-1)?.conversation_sequence || 0;
      return merged;
    });

    const latest = Math.max(...incoming.map((message) => message.conversation_sequence));
    const conversationId = incoming[0]?.conversation_id;
    if (conversationId) {
      setConversations((current) =>
        current.map((conversation) =>
          conversation.id === conversationId
            ? { ...conversation, latest_sequence: Math.max(conversation.latest_sequence, latest) }
            : conversation
        )
      );
    }
  }, []);

  const applyReaction = useCallback((event: ReactionEvent, add: boolean) => {
    setMessages((current) =>
      current.map((message) => {
        if (message.id !== event.message_id) return message;
        const without = message.reactions.filter(
          (reaction) => !(reaction.user_id === event.user_id && reaction.emoji === event.emoji)
        );
        return {
          ...message,
          reactions: add ? [...without, { user_id: event.user_id, emoji: event.emoji }] : without
        };
      })
    );
  }, []);

  useEffect(() => {
    if (!session) {
      setConversations([]);
      setUsers([]);
      setMessages([]);
      setActiveConversationId(null);
      setWorkspaceLoading(false);
      return;
    }

    let current = true;
    setWorkspaceLoading(true);
    setError(null);
    Promise.all([api.me(), api.users(), api.conversations()])
      .then(([identity, tenantUsers, availableConversations]) => {
        if (!current) return;
        const refreshedSession = {
          ...session,
          tenant: identity.tenant,
          user: identity.user,
          device: identity.device
        };
        commitSession(refreshedSession);
        setUsers(tenantUsers);
        setConversations(availableConversations);
        setActiveConversationId((selected) =>
          selected && availableConversations.some((conversation) => conversation.id === selected)
            ? selected
            : availableConversations[0]?.id || null
        );
      })
      .catch((reason: unknown) => {
        if (current) setError(errorText(reason));
      })
      .finally(() => {
        if (current) setWorkspaceLoading(false);
      });

    return () => {
      current = false;
    };
  }, [api, commitSession, session?.access_token]);

  useEffect(() => {
    if (!session) return;
    const receivedAt = session.received_at || 0;
    const lifetime = session.expires_in * 1_000;
    const refreshLead = Math.min(60_000, Math.max(1_000, lifetime * 0.2));
    const refreshAt = receivedAt + lifetime - refreshLead;
    const delay = Math.max(250, refreshAt - Date.now());
    const timer = window.setTimeout(() => {
      void api.refreshSession().catch(() => commitSession(null));
    }, delay);
    return () => window.clearTimeout(timer);
  }, [api, commitSession, session]);

  useEffect(() => {
    const accessToken = session?.access_token;
    if (!accessToken || !activeConversationId) return;
    const conversationId = activeConversationId;
    const socketToken = accessToken;

    let current = true;
    latestSequenceRef.current = 0;
    setMessages([]);
    setPendingAttachments([]);
    setTypingUsers(new Set());
    setReadCursors({});
    setMessagesLoading(true);
    setConnectionStatus("connecting");
    setError(null);

    let realtime: RealtimeConversation | null = null;

    async function replayThenConnect() {
      let afterSequence = 0;
      let pages = 0;
      const maxPages = 500;

      try {
        while (current) {
          const page = await api.messages(conversationId, afterSequence, 200);
          if (!current) return;
          if (page.page.reset_required) {
            throw new Error("The server requested a full history reset. Reopen the conversation to retry.");
          }

          const pageLatest = page.data.at(-1)?.conversation_sequence || afterSequence;
          latestSequenceRef.current = Math.max(latestSequenceRef.current, pageLatest);
          receiveMessages(page.data);
          pages += 1;

          if (!page.page.has_more) break;
          const next = page.page.next_after_sequence;
          if (next === null || next <= afterSequence) {
            throw new Error("Message replay returned a non-advancing cursor.");
          }
          if (pages >= maxPages) {
            throw new Error("Message history exceeds the safe replay limit; live connection was not opened.");
          }
          afterSequence = next;
        }

        if (!current) return;
        realtime = new RealtimeConversation(
          socketEndpoint(apiBase),
          socketToken,
          conversationId,
          () => latestSequenceRef.current,
          {
            onStatus: setConnectionStatus,
            onMessages: receiveMessages,
            onReactionAdded: (event) => applyReaction(event, true),
            onReactionRemoved: (event) => applyReaction(event, false),
            onRead: (event: ReadCursorEvent) =>
              setReadCursors((cursors) => ({ ...cursors, [event.user_id]: event.sequence })),
            onTyping: (userId, active) =>
              setTypingUsers((currentUsers) => {
                const next = new Set(currentUsers);
                if (active) next.add(userId);
                else next.delete(userId);
                return next;
              }),
            onPresence: setOnlineUsers,
            onError: setError
          }
        );
        realtimeRef.current = realtime;
        realtime.connect();
      } catch (reason: unknown) {
        if (current) {
          setConnectionStatus("offline");
          setError(errorText(reason));
        }
      } finally {
        if (current) setMessagesLoading(false);
      }
    }

    void replayThenConnect();

    return () => {
      current = false;
      realtime?.disconnect();
      if (realtimeRef.current === realtime) realtimeRef.current = null;
    };
  }, [activeConversationId, api, applyReaction, receiveMessages, session?.access_token]);

  const latestSequence = messages.at(-1)?.conversation_sequence || 0;
  useEffect(() => {
    if (!activeConversationId || latestSequence <= 0 || document.visibilityState !== "visible") return;
    const timer = window.setTimeout(() => {
      const command = realtimeRef.current
        ? realtimeRef.current.markRead(latestSequence).then(() => undefined)
        : api.markRead(activeConversationId, latestSequence);
      void command
        .then(() =>
          setConversations((current) =>
            current.map((conversation) =>
              conversation.id === activeConversationId
                ? { ...conversation, last_read_sequence: latestSequence, unread_count: 0 }
                : conversation
            )
          )
        )
        .catch(() => undefined);
    }, 700);
    return () => window.clearTimeout(timer);
  }, [activeConversationId, api, latestSequence]);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }, [messages.length]);

  useEffect(
    () => () => {
      if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
    },
    []
  );

  function authenticated(next: Session, preferredConversationId?: string) {
    commitSession(next);
    if (preferredConversationId) setActiveConversationId(preferredConversationId);
  }

  async function logout() {
    setError(null);
    try {
      await api.logout();
    } catch (reason: unknown) {
      commitSession(null);
      setError(errorText(reason));
    }
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!activeConversationId || sending) return;
    const body = composer.trim();
    if (!body) {
      setError("Write a message before sending.");
      return;
    }

    setSending(true);
    setError(null);
    realtimeRef.current?.setTyping(false);
    const input = {
      client_message_id: clientMessageId(),
      body,
      attachment_ids: pendingAttachments.map(({ attachment }) => attachment.id)
    };

    try {
      const message =
        connectionStatus === "live" && realtimeRef.current
          ? await realtimeRef.current.sendMessage(input)
          : await api.sendMessage(activeConversationId, input);
      receiveMessages([message]);
      setComposer("");
      setPendingAttachments([]);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setSending(false);
    }
  }

  function composerChanged(event: ChangeEvent<HTMLTextAreaElement>) {
    setComposer(event.target.value);
    realtimeRef.current?.setTyping(true);
    if (typingTimerRef.current) window.clearTimeout(typingTimerRef.current);
    typingTimerRef.current = window.setTimeout(() => realtimeRef.current?.setTyping(false), 1_500);
  }

  async function filesSelected(event: ChangeEvent<HTMLInputElement>) {
    const selected = [...(event.target.files || [])];
    event.target.value = "";
    if (selected.length === 0) return;
    setUploading(true);
    setError(null);

    try {
      for (const file of selected) {
        if (file.size > 25_000_000) throw new Error(`${file.name} exceeds the 25 MB limit`);
        const checksum = await sha256(file);
        const intent = await api.createAttachment(file, checksum);
        await uploadToPresignedTarget(intent.upload, file);
        const attachment = await api.completeAttachment(intent.data.id);
        setPendingAttachments((current) => [...current, { attachment, localName: file.name }]);
      }
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setUploading(false);
    }
  }

  async function toggleReaction(message: Message, emoji: string) {
    if (!session || !activeConversationId) return;
    const exists = message.reactions.some(
      (reaction) => reaction.user_id === session.user.id && reaction.emoji === emoji
    );
    const event = { message_id: message.id, emoji, user_id: session.user.id };
    applyReaction(event, !exists);
    try {
      if (exists) await api.removeReaction(activeConversationId, message.id, emoji);
      else await api.addReaction(activeConversationId, message.id, emoji);
    } catch (reason: unknown) {
      applyReaction(event, exists);
      setError(errorText(reason));
    }
  }

  async function openAttachment(attachment: Attachment) {
    setError(null);
    try {
      const response = await api.attachmentDownload(attachment.id);
      const url = downloadUrl(response.download);
      if (!url) throw new Error("The server did not return a download URL");
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  async function createConversation(input: CreateConversationInput) {
    setError(null);
    try {
      const conversation = await api.createConversation(input);
      setConversations((current) => [conversation, ...current]);
      setActiveConversationId(conversation.id);
      setShowCreateConversation(false);
      setNotice(`Created ${conversation.title || "conversation"}.`);
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  async function createUser(input: CreateUserInput) {
    setError(null);
    try {
      const user = await api.createUser(input);
      setUsers((current) => [...current, user].sort((left, right) => left.display_name.localeCompare(right.display_name)));
      setShowCreateUser(false);
      setNotice(`Created an account for ${user.display_name}.`);
    } catch (reason: unknown) {
      setError(errorText(reason));
    }
  }

  if (!session) {
    return <AuthScreen api={api} onAuthenticated={authenticated} />;
  }

  if (workspaceLoading) {
    return (
      <main className="centered-page" aria-busy="true">
        <Brand />
        <div className="loading-card">
          <span className="spinner" aria-hidden="true" />
          <p>Opening your workspace…</p>
        </div>
      </main>
    );
  }

  const activeTyping = [...typingUsers]
    .filter((id) => id !== session.user.id)
    .map((id) => usersById.get(id)?.display_name || "Someone");

  return (
    <div className="app-shell">
      <header className="topbar">
        <Brand compact />
        <div className="workspace-name">
          <span className="eyebrow">Workspace</span>
          <strong>{session.tenant.name}</strong>
        </div>
        <div className="account-menu">
          <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
          <span className="account-copy">
            <strong>{session.user.display_name}</strong>
            <small>{session.user.role}</small>
          </span>
          <button className="button ghost compact" type="button" onClick={() => void logout()}>
            Sign out
          </button>
        </div>
      </header>

      {error && (
        <div className="banner error-banner" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}>×</button>
        </div>
      )}
      {notice && (
        <div className="banner notice-banner" role="status">
          <span>{notice}</span>
          <button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}>×</button>
        </div>
      )}

      <main className="workspace-grid">
        <aside className="conversation-sidebar" aria-label="Conversations">
          <div className="sidebar-heading">
            <div>
              <span className="eyebrow">Channels & groups</span>
              <h1>Conversations</h1>
            </div>
            <div className="sidebar-tools">
              {["owner", "admin"].includes(session.user.role) && (
                <button
                  className="icon-button member-button"
                  type="button"
                  aria-label="Create teammate account"
                  aria-expanded={showCreateUser}
                  onClick={() => {
                    setShowCreateUser((visible) => !visible);
                    setShowCreateConversation(false);
                  }}
                >
                  <span aria-hidden="true">♙</span><span aria-hidden="true">+</span>
                </button>
              )}
              <button
                className="icon-button"
                type="button"
                aria-label="Create conversation"
                aria-expanded={showCreateConversation}
                onClick={() => {
                  setShowCreateConversation((visible) => !visible);
                  setShowCreateUser(false);
                }}
              >
                +
              </button>
            </div>
          </div>

          {showCreateUser && (
            <CreateUserForm onCancel={() => setShowCreateUser(false)} onCreate={createUser} />
          )}

          {showCreateConversation && (
            <CreateConversationForm
              users={users.filter((user) => user.id !== session.user.id)}
              onCancel={() => setShowCreateConversation(false)}
              onCreate={createConversation}
            />
          )}

          <nav className="conversation-list" aria-label="Conversation list">
            {conversations.length === 0 ? (
              <p className="empty-copy">No conversations yet. Create one to get started.</p>
            ) : (
              conversations.map((conversation) => (
                <button
                  type="button"
                  key={conversation.id}
                  className={`conversation-row ${conversation.id === activeConversationId ? "active" : ""}`}
                  aria-current={conversation.id === activeConversationId ? "page" : undefined}
                  onClick={() => setActiveConversationId(conversation.id)}
                >
                  <span className="conversation-icon" aria-hidden="true">
                    {conversation.kind === "channel" ? "#" : conversation.kind === "direct" ? "@" : "◇"}
                  </span>
                  <span className="conversation-copy">
                    <strong>{conversationTitle(conversation)}</strong>
                    <small>{conversation.kind} · {conversation.visibility}</small>
                  </span>
                  {(conversation.unread_count || 0) > 0 && (
                    <span className="unread-badge" aria-label={`${conversation.unread_count} unread messages`}>
                      {conversation.unread_count}
                    </span>
                  )}
                </button>
              ))
            )}
          </nav>
        </aside>

        <section className="conversation-pane" aria-label={activeConversation ? conversationTitle(activeConversation) : "Messages"}>
          {activeConversation ? (
            <>
              <header className="conversation-header">
                <div>
                  <span className="eyebrow">{activeConversation.kind}</span>
                  <h2>{conversationTitle(activeConversation)}</h2>
                </div>
                <div className="connection-summary" aria-live="polite">
                  <span className={`status-dot ${connectionStatus}`} aria-hidden="true" />
                  <span>{connectionLabel(connectionStatus)}</span>
                  {onlineUsers > 0 && <small>{onlineUsers} online</small>}
                </div>
              </header>

              <div className="message-scroll" aria-busy={messagesLoading}>
                {messagesLoading && messages.length === 0 ? (
                  <div className="inline-loading"><span className="spinner" aria-hidden="true" />Loading messages…</div>
                ) : messages.length === 0 ? (
                  <div className="empty-state">
                    <span className="empty-mark" aria-hidden="true">✦</span>
                    <h3>Start the conversation</h3>
                    <p>Messages are durable, ordered, and replayed when you reconnect.</p>
                  </div>
                ) : (
                  <ol className="message-list" aria-live="polite" aria-relevant="additions text">
                    {messages.map((message) => (
                      <MessageItem
                        key={message.id}
                        message={message}
                        currentUserId={session.user.id}
                        sender={usersById.get(message.sender_user_id)}
                        seenCount={Object.entries(readCursors).filter(
                          ([userId, sequence]) => userId !== session.user.id && sequence >= message.conversation_sequence
                        ).length}
                        onReaction={(emoji) => void toggleReaction(message, emoji)}
                        onAttachment={(attachment) => void openAttachment(attachment)}
                      />
                    ))}
                  </ol>
                )}
                <div ref={messagesEndRef} />
              </div>

              <div className="typing-line" aria-live="polite">
                {activeTyping.length > 0 ? `${activeTyping.join(", ")} ${activeTyping.length === 1 ? "is" : "are"} typing…` : "\u00a0"}
              </div>

              <form className="composer" onSubmit={(event) => void sendMessage(event)}>
                {pendingAttachments.length > 0 && (
                  <div className="pending-files" aria-label="Files ready to attach">
                    {pendingAttachments.map(({ attachment, localName }) => (
                      <span className="file-chip" key={attachment.id}>
                        <span aria-hidden="true">▤</span> {localName}
                        <button
                          type="button"
                          aria-label={`Remove ${localName}`}
                          onClick={() =>
                            setPendingAttachments((current) =>
                              current.filter((item) => item.attachment.id !== attachment.id)
                            )
                          }
                        >×</button>
                      </span>
                    ))}
                  </div>
                )}
                <label className="sr-only" htmlFor="message-composer">Message</label>
                <textarea
                  id="message-composer"
                  value={composer}
                  onChange={composerChanged}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" && !event.shiftKey) {
                      event.preventDefault();
                      event.currentTarget.form?.requestSubmit();
                    }
                  }}
                  rows={2}
                  maxLength={65_535}
                  placeholder={`Message ${conversationTitle(activeConversation)}`}
                  disabled={sending}
                />
                <div className="composer-actions">
                  <label className={`attachment-button ${uploading ? "disabled" : ""}`}>
                    <input
                      type="file"
                      multiple
                      disabled={uploading || sending}
                      onChange={(event) => void filesSelected(event)}
                      accept="image/*,text/*,application/pdf,application/zip,application/json"
                    />
                    <span aria-hidden="true">＋</span> {uploading ? "Uploading…" : "Attach"}
                  </label>
                  <span className="composer-hint">Enter to send · Shift+Enter for a new line</span>
                  <button className="button primary send-button" type="submit" disabled={sending || uploading || !composer.trim()}>
                    {sending ? "Sending…" : "Send"}
                    <span aria-hidden="true">↗</span>
                  </button>
                </div>
              </form>
            </>
          ) : (
            <div className="empty-state full-height">
              <span className="empty-mark" aria-hidden="true">◇</span>
              <h2>Select a conversation</h2>
              <p>Choose a channel or create a new group.</p>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}

function AuthScreen({
  api,
  onAuthenticated
}: {
  api: ApiClient;
  onAuthenticated: (session: Session, preferredConversationId?: string) => void;
}) {
  const [mode, setMode] = useState<"login" | "bootstrap">("login");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submitLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    const input: LoginInput = {
      tenant_slug: stringValue(values, "tenant_slug"),
      email: stringValue(values, "email"),
      password: stringValue(values, "password"),
      device: { name: browserName(), platform: "web" }
    };
    setBusy(true);
    setError(null);
    try {
      onAuthenticated(await api.login(input));
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  async function submitBootstrap(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    const input: BootstrapInput = {
      tenant_name: stringValue(values, "tenant_name"),
      tenant_slug: stringValue(values, "tenant_slug"),
      display_name: stringValue(values, "display_name"),
      email: stringValue(values, "email"),
      password: stringValue(values, "password"),
      device_name: browserName(),
      device_platform: "web"
    };
    setBusy(true);
    setError(null);
    try {
      const result = await api.bootstrap(input);
      onAuthenticated(result, result.conversation.id);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-story" aria-labelledby="welcome-title">
        <Brand />
        <div className="auth-story-copy">
          <span className="eyebrow light">Durable conversation infrastructure</span>
          <h1 id="welcome-title">Stay in sync,<br />even after the signal drops.</h1>
          <p>K-Comms keeps messages ordered, tenant-scoped, and ready to replay across every device.</p>
        </div>
        <ul className="feature-list" aria-label="Platform capabilities">
          <li><span>01</span> Durable ordered delivery</li>
          <li><span>02</span> Realtime reconnect and replay</li>
          <li><span>03</span> Direct secure attachments</li>
        </ul>
      </section>

      <section className="auth-panel" aria-labelledby="auth-heading">
        <div className="auth-card">
          <span className="eyebrow">Welcome to K-Comms</span>
          <h2 id="auth-heading">{mode === "login" ? "Sign in to your workspace" : "Create a development workspace"}</h2>
          <p className="muted">
            {mode === "login"
              ? "Use your workspace slug and account credentials."
              : "Bootstrap must be enabled by the server administrator."}
          </p>

          <div className="auth-tabs" role="tablist" aria-label="Authentication options">
            <button type="button" role="tab" aria-selected={mode === "login"} onClick={() => setMode("login")}>Sign in</button>
            <button type="button" role="tab" aria-selected={mode === "bootstrap"} onClick={() => setMode("bootstrap")}>Create workspace</button>
          </div>

          {error && <div className="form-error" role="alert">{error}</div>}

          {mode === "login" ? (
            <form className="auth-form" onSubmit={(event) => void submitLogin(event)}>
              <Field label="Workspace slug" name="tenant_slug" autoComplete="organization" required />
              <Field label="Email address" name="email" type="email" autoComplete="username" required />
              <Field label="Password" name="password" type="password" autoComplete="current-password" required />
              <button className="button primary full" type="submit" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
            </form>
          ) : (
            <form className="auth-form" onSubmit={(event) => void submitBootstrap(event)}>
              <div className="field-pair">
                <Field label="Workspace name" name="tenant_name" minLength={2} maxLength={120} autoComplete="organization" required />
                <Field label="Workspace slug" name="tenant_slug" minLength={2} maxLength={80} pattern="[a-z0-9-]+" title="Lowercase letters, numbers, and hyphens" required />
              </div>
              <Field label="Your name" name="display_name" maxLength={120} autoComplete="name" required />
              <Field label="Email address" name="email" type="email" autoComplete="username" required />
              <Field label="Password" name="password" type="password" minLength={12} maxLength={256} autoComplete="new-password" hint="At least 12 characters" required />
              <button className="button primary full" type="submit" disabled={busy}>{busy ? "Creating workspace…" : "Create development workspace"}</button>
            </form>
          )}
        </div>
      </section>
    </main>
  );
}

function CreateConversationForm({
  users,
  onCancel,
  onCreate
}: {
  users: User[];
  onCancel: () => void;
  onCreate: (input: CreateConversationInput) => Promise<void>;
}) {
  const [selectedUsers, setSelectedUsers] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    setBusy(true);
    try {
      await onCreate({
        title: stringValue(values, "title"),
        kind: stringValue(values, "kind") as "group" | "channel",
        visibility: stringValue(values, "visibility") as "private" | "tenant",
        member_ids: selectedUsers
      });
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="create-conversation" onSubmit={(event) => void submit(event)}>
      <h2>New conversation</h2>
      <Field label="Title" name="title" maxLength={160} required />
      <div className="field-pair">
        <label className="field">Type<select name="kind" defaultValue="group"><option value="group">Group</option><option value="channel">Channel</option></select></label>
        <label className="field">Visibility<select name="visibility" defaultValue="private"><option value="private">Private</option><option value="tenant">Workspace</option></select></label>
      </div>
      {users.length > 0 && (
        <fieldset className="member-picker">
          <legend>Add people</legend>
          {users.map((user) => (
            <label key={user.id}>
              <input
                type="checkbox"
                checked={selectedUsers.includes(user.id)}
                onChange={(event) =>
                  setSelectedUsers((current) =>
                    event.target.checked ? [...current, user.id] : current.filter((id) => id !== user.id)
                  )
                }
              />
              <span>{user.display_name}<small>{user.email}</small></span>
            </label>
          ))}
        </fieldset>
      )}
      <div className="form-actions">
        <button className="button ghost compact" type="button" onClick={onCancel}>Cancel</button>
        <button className="button primary compact" type="submit" disabled={busy}>{busy ? "Creating…" : "Create"}</button>
      </div>
    </form>
  );
}

function CreateUserForm({
  onCancel,
  onCreate
}: {
  onCancel: () => void;
  onCreate: (input: CreateUserInput) => Promise<void>;
}) {
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    setBusy(true);
    try {
      await onCreate({
        display_name: stringValue(values, "display_name"),
        email: stringValue(values, "email"),
        password: stringValue(values, "password"),
        role: stringValue(values, "role") as "member" | "admin"
      });
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="create-conversation" onSubmit={(event) => void submit(event)}>
      <span className="eyebrow">Workspace access</span>
      <h2>Create teammate</h2>
      <Field label="Display name" name="display_name" maxLength={120} autoComplete="name" required />
      <Field label="Email" name="email" type="email" autoComplete="email" required />
      <Field label="Temporary password" name="password" type="password" minLength={12} maxLength={256} autoComplete="new-password" hint="At least 12 characters" required />
      <label className="field">
        Role
        <select name="role" defaultValue="member">
          <option value="member">Member</option>
          <option value="admin">Administrator</option>
        </select>
      </label>
      <div className="form-actions">
        <button className="button ghost compact" type="button" onClick={onCancel}>Cancel</button>
        <button className="button primary compact" type="submit" disabled={busy}>{busy ? "Creating…" : "Create teammate"}</button>
      </div>
    </form>
  );
}

function MessageItem({
  message,
  currentUserId,
  sender,
  seenCount,
  onReaction,
  onAttachment
}: {
  message: Message;
  currentUserId: string;
  sender?: User;
  seenCount: number;
  onReaction: (emoji: string) => void;
  onAttachment: (attachment: Attachment) => void;
}) {
  const mine = message.sender_user_id === currentUserId;
  const groups = groupReactions(message, currentUserId);

  return (
    <li className={`message ${mine ? "mine" : ""}`}>
      {!mine && <span className="avatar small" aria-hidden="true">{initials(sender?.display_name || "Unknown")}</span>}
      <article className="message-content">
        <header>
          <strong>{mine ? "You" : sender?.display_name || "Unknown user"}</strong>
          <time dateTime={message.inserted_at}>{formatTime(message.inserted_at)}</time>
          {message.edited_at && <span>edited</span>}
        </header>
        <div className={`message-bubble ${message.status !== "active" ? "removed" : ""}`}>
          {message.status === "active" ? message.body : "Message removed"}
        </div>
        {message.attachments.length > 0 && (
          <div className="message-attachments">
            {message.attachments.map((attachment) => (
              <button type="button" key={attachment.id} onClick={() => onAttachment(attachment)}>
                <span aria-hidden="true">▤</span>
                <span><strong>{attachment.file_name}</strong><small>{formatBytes(attachment.byte_size)}</small></span>
              </button>
            ))}
          </div>
        )}
        <div className="reaction-row">
          {groups.map(({ emoji, count, mine: reacted }) => (
            <button
              type="button"
              key={emoji}
              className={reacted ? "reacted" : ""}
              aria-pressed={reacted}
              aria-label={`${reacted ? "Remove" : "Add"} ${emoji} reaction; ${count} total`}
              onClick={() => onReaction(emoji)}
            >{emoji} <span>{count}</span></button>
          ))}
          {message.status === "active" && (
            <span className="quick-reactions" aria-label="Quick reactions">
              {quickReactions.filter((emoji) => !groups.some((group) => group.emoji === emoji)).map((emoji) => (
                <button type="button" key={emoji} aria-label={`React with ${emoji}`} onClick={() => onReaction(emoji)}>{emoji}</button>
              ))}
            </span>
          )}
        </div>
        {mine && seenCount > 0 && <small className="seen-copy">Seen by {seenCount}</small>}
      </article>
    </li>
  );
}

function Field({ label, hint, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }) {
  return (
    <label className="field">
      <span>{label}</span>
      <input {...props} />
      {hint && <small>{hint}</small>}
    </label>
  );
}

function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`brand ${compact ? "compact" : ""}`} aria-label="K-Comms">
      <span className="brand-mark" aria-hidden="true"><i /><i /><i /></span>
      <span>K<span>—</span>COMMS</span>
    </div>
  );
}

function groupReactions(message: Message, currentUserId: string) {
  const grouped = new Map<string, { emoji: string; count: number; mine: boolean }>();
  for (const reaction of message.reactions) {
    const value = grouped.get(reaction.emoji) || { emoji: reaction.emoji, count: 0, mine: false };
    value.count += 1;
    value.mine ||= reaction.user_id === currentUserId;
    grouped.set(reaction.emoji, value);
  }
  return [...grouped.values()];
}

function conversationTitle(conversation: Conversation): string {
  return conversation.title?.trim() || (conversation.kind === "direct" ? "Direct message" : "Untitled conversation");
}

function connectionLabel(status: ConnectionStatus): string {
  if (status === "live") return "Live";
  if (status === "connecting") return "Connecting";
  if (status === "reconnecting") return "Reconnecting";
  return "Offline";
}

function initials(value: string): string {
  return value.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "?";
}

function formatTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "" : new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(date);
}

function formatBytes(value: number): string {
  if (value < 1_000) return `${value} B`;
  if (value < 1_000_000) return `${(value / 1_000).toFixed(1)} KB`;
  return `${(value / 1_000_000).toFixed(1)} MB`;
}

function clientMessageId(): string {
  return window.crypto.randomUUID ? window.crypto.randomUUID() : `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function browserName(): string {
  return `Web · ${navigator.platform || "browser"}`;
}

function stringValue(form: FormData, key: string): string {
  return String(form.get(key) || "").trim();
}

function errorText(reason: unknown): string {
  if (reason instanceof ApiError) return reason.message;
  if (reason instanceof Error) return reason.message;
  return "Something went wrong. Please try again.";
}
