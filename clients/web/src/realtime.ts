import { Socket } from "phoenix";
import type { Channel } from "phoenix";
import type {
  ConnectionStatus,
  ConversationActivityEvent,
  ConversationMembershipEvent,
  Message,
  MembershipEvent,
  NotificationAvailableEvent,
  ReactionEvent,
  ReadCursorEvent
} from "./types";

interface DynamicSocket extends Socket {
  channel(topic: string, params: Record<string, unknown> | (() => Record<string, unknown>)): Channel;
}

export interface RealtimeInboxCallbacks {
  onConnected: () => void;
  onActivity: (event: ConversationActivityEvent) => void;
  onMembership: (event: ConversationMembershipEvent) => void;
  onNotification: (event: NotificationAvailableEvent) => void;
  onError: (message: string) => void;
  onReconnectRequired: () => void;
}

export class RealtimeInbox {
  private readonly socket: Socket;
  private readonly channel: Channel;
  private stopped = false;
  private reconnectRequested = false;

  constructor(
    endpoint: string,
    socketTicket: string,
    userId: string,
    private readonly callbacks: RealtimeInboxCallbacks
  ) {
    this.socket = new Socket(endpoint, {
      params: { socket_ticket: socketTicket },
      reconnectAfterMs: () => 60_000,
      rejoinAfterMs: (tries) => [1_000, 2_000, 5_000, 10_000][tries - 1] ?? 15_000
    });
    this.channel = (this.socket as DynamicSocket).channel(`user:${userId}`, { protocol_version: 1 });
    this.channel.on("conversation.activity.v1", (payload?: unknown) => {
      if (isConversationActivityEvent(payload)) this.callbacks.onActivity(payload);
    });
    this.channel.on("conversation.membership.v1", (payload?: unknown) => {
      if (isConversationMembershipEvent(payload)) this.callbacks.onMembership(payload);
    });
    this.channel.on("notification.available.v1", (payload?: unknown) => {
      if (isNotificationAvailableEvent(payload)) this.callbacks.onNotification(payload);
    });
    this.socket.onError(() => this.requestReconnect());
    this.socket.onClose(() => this.requestReconnect());
    this.channel.onError(() => this.requestReconnect());
  }

  connect(): void {
    this.socket.connect();
    this.channel
      .join()
      .receive("ok", () => {
        if (!this.stopped) this.callbacks.onConnected();
      })
      .receive("error", (response?: unknown) => {
        if (!this.stopped) {
          this.callbacks.onError(readReason(response, "Unable to join the user inbox"));
          this.requestReconnect();
        }
      })
      .receive("timeout", () => this.requestReconnect());
  }

  disconnect(): void {
    this.stopped = true;
    this.channel.leave();
    this.socket.disconnect();
  }

  private requestReconnect(): void {
    if (this.stopped || this.reconnectRequested) return;
    this.reconnectRequested = true;
    this.socket.disconnect();
    this.callbacks.onReconnectRequired();
  }
}

export interface RealtimeCallbacks {
  onStatus: (status: ConnectionStatus) => void;
  onMessages: (messages: Message[]) => void;
  onReactionAdded: (event: ReactionEvent) => void;
  onReactionRemoved: (event: ReactionEvent) => void;
  onRead: (event: ReadCursorEvent) => void;
  onMembershipChanged: (event: MembershipEvent) => void;
  onConversationChanged: () => void;
  onCatchUpRequired: (afterSequence: number) => void;
  onTyping: (userId: string, active: boolean) => void;
  onPresence: (onlineUsers: number) => void;
  onError: (message: string) => void;
  onReconnectRequired: () => void;
}

export class RealtimeConversation {
  private readonly socket: Socket;
  private readonly channel: Channel;
  private stopped = false;
  private onlineUsers = 0;
  private reconnectRequested = false;

  constructor(
    endpoint: string,
    socketTicket: string,
    conversationId: string,
    private readonly afterSequence: () => number,
    private readonly callbacks: RealtimeCallbacks
  ) {
    this.socket = new Socket(endpoint, {
      params: { socket_ticket: socketTicket },
      reconnectAfterMs: () => 60_000,
      rejoinAfterMs: (tries) => [1_000, 2_000, 5_000, 10_000][tries - 1] ?? 15_000
    });

    this.channel = (this.socket as DynamicSocket).channel(`conversation:${conversationId}`, () => ({
      protocol_version: 1,
      after_sequence: this.afterSequence(),
      client_capabilities: ["message_revisions", "attachment_v2"]
    }));

    this.bindEvents();
  }

  connect(): void {
    this.callbacks.onStatus("connecting");
    this.socket.connect();
    this.channel
      .join()
      .receive("ok", (response?: unknown) => {
        if (this.stopped) return;
        const { messages, hasMore, nextAfterSequence } = readReplay(response);
        if (messages.length > 0) this.callbacks.onMessages(messages);
        if (hasMore) this.callbacks.onCatchUpRequired(nextAfterSequence);
        this.callbacks.onStatus("live");
      })
      .receive("error", (response?: unknown) => {
        this.callbacks.onStatus("reconnecting");
        this.callbacks.onError(readReason(response, "Unable to join the conversation"));
        this.requestReconnect();
      })
      .receive("timeout", () => {
        this.callbacks.onStatus("reconnecting");
        this.requestReconnect();
      });
  }

  disconnect(): void {
    this.stopped = true;
    this.channel.leave();
    this.socket.disconnect();
    this.callbacks.onStatus("offline");
  }

  sendMessage(input: {
    client_message_id: string;
    body: string;
    attachment_ids: string[];
    reply_to_message_id?: string | null;
    mentioned_user_ids?: string[];
  }): Promise<Message> {
    const { client_message_id: commandId, ...payload } = input;
    return this.command<Message>("message.send.v1", payload, commandId);
  }

  markRead(sequence: number): Promise<ReadCursorEvent> {
    return this.command<ReadCursorEvent>("conversation.read.v1", { sequence });
  }

  setTyping(active: boolean): void {
    this.channel.push("command", commandEnvelope(active ? "typing.start.v1" : "typing.stop.v1", {}));
  }

  private bindEvents(): void {
    this.socket.onOpen(() => {
      if (!this.stopped) this.callbacks.onStatus("connecting");
    });
    this.socket.onError(() => {
      if (!this.stopped) {
        this.callbacks.onStatus("reconnecting");
        this.requestReconnect();
      }
    });
    this.socket.onClose(() => {
      if (!this.stopped) {
        this.callbacks.onStatus("reconnecting");
        this.requestReconnect();
      }
    });
    this.channel.onError(() => {
      if (!this.stopped) {
        this.callbacks.onStatus("reconnecting");
        this.requestReconnect();
      }
    });

    for (const event of ["message.created.v1", "message.updated.v1", "message.deleted.v1"]) {
      this.channel.on(event, (payload?: unknown) => {
        if (isMessage(payload)) this.callbacks.onMessages([payload]);
      });
    }
    this.channel.on("message.reaction_added.v1", (payload?: unknown) => {
      if (isReactionEvent(payload)) this.callbacks.onReactionAdded(payload);
    });
    this.channel.on("message.reaction_removed.v1", (payload?: unknown) => {
      if (isReactionEvent(payload)) this.callbacks.onReactionRemoved(payload);
    });
    this.channel.on("conversation.read.v1", (payload?: unknown) => {
      if (isReadCursorEvent(payload)) this.callbacks.onRead(payload);
    });
    this.channel.on("membership.changed.v1", (payload?: unknown) => {
      if (isMembershipEvent(payload)) this.callbacks.onMembershipChanged(payload);
    });
    this.channel.on("conversation.updated.v1", () => this.callbacks.onConversationChanged());
    this.channel.on("conversation.archived.v1", () => this.callbacks.onConversationChanged());
    this.channel.on("typing.start", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      if (userId) this.callbacks.onTyping(userId, true);
    });
    this.channel.on("typing.stop", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      if (userId) this.callbacks.onTyping(userId, false);
    });
    this.channel.on("typing.v1", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      const state = readString(payload, "state");
      if (userId && (state === "started" || state === "stopped")) {
        this.callbacks.onTyping(userId, state === "started");
      }
    });
    this.channel.on("presence_state", (payload?: unknown) => {
      this.onlineUsers = recordSize(payload);
      this.callbacks.onPresence(this.onlineUsers);
    });
    this.channel.on("presence_diff", (payload?: unknown) => {
      const joins = readRecord(payload, "joins");
      const leaves = readRecord(payload, "leaves");
      this.onlineUsers = Math.max(0, this.onlineUsers + recordSize(joins) - recordSize(leaves));
      this.callbacks.onPresence(this.onlineUsers);
    });
  }

  private push<T>(event: string, payload: Record<string, unknown>): Promise<T> {
    return new Promise((resolve, reject) => {
      this.channel
        .push(event, payload)
        .receive("ok", (response?: unknown) => resolve(response as T))
        .receive("error", (response?: unknown) =>
          reject(new Error(readReason(response, `Realtime command ${event} failed`)))
        )
        .receive("timeout", () => reject(new Error(`Realtime command ${event} timed out`)));
    });
  }

  private command<T>(
    type: "message.send.v1" | "conversation.read.v1",
    payload: Record<string, unknown>,
    id = commandId()
  ): Promise<T> {
    return this.push<T>("command", commandEnvelope(type, payload, id));
  }

  private requestReconnect(): void {
    if (this.stopped || this.reconnectRequested) return;
    this.reconnectRequested = true;
    this.socket.disconnect();
    this.callbacks.onReconnectRequired();
  }
}

export function socketEndpoint(apiBase: string): string {
  const configured = import.meta.env.VITE_SOCKET_URL;
  if (configured) return configured;
  if (!apiBase) return "/socket";
  try {
    const url = new URL("/socket", new URL(apiBase, window.location.origin));
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return url.toString();
  } catch {
    return "/socket";
  }
}

function readReplay(value: unknown): {
  messages: Message[];
  hasMore: boolean;
  nextAfterSequence: number;
} {
  if (!value || typeof value !== "object") {
    return { messages: [], hasMore: false, nextAfterSequence: 0 };
  }
  const response = value as {
    messages?: unknown;
    has_more?: unknown;
    next_after_sequence?: unknown;
  };
  const messages = Array.isArray(response.messages) ? response.messages.filter(isMessage) : [];
  const lastSequence = messages.at(-1)?.conversation_sequence || 0;
  return {
    messages,
    hasMore: response.has_more === true,
    nextAfterSequence:
      typeof response.next_after_sequence === "number"
        ? response.next_after_sequence
        : lastSequence
  };
}

function isMembershipEvent(value: unknown): value is MembershipEvent {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<MembershipEvent>;
  return (
    typeof candidate.user_id === "string" &&
    (candidate.action === "added" || candidate.action === "removed" || candidate.action === "role_changed")
  );
}

function isConversationActivityEvent(value: unknown): value is ConversationActivityEvent {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<ConversationActivityEvent>;
  return (
    typeof candidate.conversation_id === "string" &&
    typeof candidate.latest_sequence === "number" &&
    typeof candidate.event_type === "string"
  );
}

function isConversationMembershipEvent(value: unknown): value is ConversationMembershipEvent {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<ConversationMembershipEvent>;
  return (
    typeof candidate.conversation_id === "string" &&
    (candidate.action === "added" || candidate.action === "removed")
  );
}

function isNotificationAvailableEvent(value: unknown): value is NotificationAvailableEvent {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<NotificationAvailableEvent>;
  return (
    typeof candidate.notification_id === "string" &&
    typeof candidate.event_type === "string" &&
    typeof candidate.unread_count === "number"
  );
}

function isMessage(value: unknown): value is Message {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<Message>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.conversation_id === "string" &&
    typeof candidate.conversation_sequence === "number"
  );
}

function isReactionEvent(value: unknown): value is ReactionEvent {
  return Boolean(
    value &&
      typeof value === "object" &&
      typeof (value as Partial<ReactionEvent>).message_id === "string" &&
      typeof (value as Partial<ReactionEvent>).emoji === "string" &&
      typeof (value as Partial<ReactionEvent>).user_id === "string"
  );
}

function isReadCursorEvent(value: unknown): value is ReadCursorEvent {
  return Boolean(
    value &&
      typeof value === "object" &&
      typeof (value as Partial<ReadCursorEvent>).user_id === "string" &&
      typeof (value as Partial<ReadCursorEvent>).sequence === "number"
  );
}

function readString(value: unknown, key: string): string | null {
  if (!value || typeof value !== "object") return null;
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "string" ? candidate : null;
}

function readRecord(value: unknown, key: string): Record<string, unknown> {
  if (!value || typeof value !== "object") return {};
  const candidate = (value as Record<string, unknown>)[key];
  return candidate && typeof candidate === "object" ? (candidate as Record<string, unknown>) : {};
}

function recordSize(value: unknown): number {
  return value && typeof value === "object" ? Object.keys(value).length : 0;
}

function readReason(value: unknown, fallback: string): string {
  if (!value || typeof value !== "object") return fallback;
  const reason = (value as { reason?: unknown }).reason;
  return typeof reason === "string" ? reason : fallback;
}

function commandEnvelope(type: string, payload: Record<string, unknown>, id = commandId()) {
  return {
    command_id: id,
    type,
    payload,
    client_time: new Date().toISOString()
  };
}

function commandId(): string {
  return globalThis.crypto.randomUUID
    ? globalThis.crypto.randomUUID()
    : `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
