import { Presence, Socket } from "phoenix";
import type { Channel } from "phoenix";
import type {
  CallRealtimeEvent,
  ConnectionStatus,
  ConversationActivityEvent,
  ConversationMembershipEvent,
  Message,
  MessageDeliveryCursor,
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
      if (!this.stopped && isConversationActivityEvent(payload)) this.callbacks.onActivity(payload);
    });
    this.channel.on("conversation.membership.v1", (payload?: unknown) => {
      if (!this.stopped && isConversationMembershipEvent(payload)) this.callbacks.onMembership(payload);
    });
    this.channel.on("notification.available.v1", (payload?: unknown) => {
      if (!this.stopped && isNotificationAvailableEvent(payload)) this.callbacks.onNotification(payload);
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
  onDelivery?: (event: MessageDeliveryCursor) => void;
  onMembershipChanged: (event: MembershipEvent) => void;
  onConversationChanged: () => void;
  onCallStarted?: (event: CallRealtimeEvent) => void;
  onCallEnded?: (event: CallRealtimeEvent) => void;
  onAudioCallStarted: (event: CallRealtimeEvent) => void;
  onAudioCallEnded: (event: CallRealtimeEvent) => void;
  onCatchUpRequired: (afterSequence: number) => void;
  onTyping: (userId: string, active: boolean) => void;
  onPresence: (onlineUsers: number, onlineUserIds: string[]) => void;
  onError: (message: string) => void;
  onReconnectRequired: () => void;
}

export class RealtimeConversation {
  private readonly socket: Socket;
  private readonly channel: Channel;
  private readonly presence: Presence;
  private stopped = false;
  private reconnectRequested = false;
  private joinAfterSequence = 0;
  private readonly deliveredCallEvents = new Set<string>();

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
      after_sequence: this.joinAfterSequence,
      client_capabilities: ["message_revisions", "attachment_v2"]
    }));
    this.presence = new Presence(this.channel);
    this.presence.onSync(() => {
      if (this.stopped) return;
      // Phoenix Presence resolves state/diff ordering and per-key metas before
      // this callback. Counting the final keys avoids drift when one person has
      // several tabs or a leave and join cross during reconnect.
      const onlineUserIds = this.presence.list((userId) => userId);
      this.callbacks.onPresence(onlineUserIds.length, onlineUserIds);
    });

    this.bindEvents();
  }

  connect(): void {
    const preReplaySequence = this.afterSequence();
    this.joinAfterSequence = preReplaySequence;
    this.callbacks.onStatus("connecting");
    this.socket.connect();
    this.channel
      .join()
      .receive("ok", (response?: unknown) => {
        if (this.stopped) return;
        const { messages, hasMore } = readReplay(response);
        if (messages.length > 0) this.callbacks.onMessages(messages);
        // The closed v1 replay messages intentionally contain no embedded
        // sender projection. Re-read the same authorized sequence range via
        // REST so its sender-label sidecar can reconcile departed identities.
        // Consumers merge by message ID, so this does not duplicate messages.
        if (messages.length > 0 || hasMore) {
          this.callbacks.onCatchUpRequired(preReplaySequence);
        }
        this.callbacks.onStatus("live");
      })
      .receive("error", (response?: unknown) => {
        if (this.stopped) return;
        this.callbacks.onStatus("reconnecting");
        this.callbacks.onError(readReason(response, "Unable to join the conversation"));
        this.requestReconnect();
      })
      .receive("timeout", () => {
        if (this.stopped) return;
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
    if (this.stopped) return;
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
        if (!this.stopped && isMessage(payload)) this.callbacks.onMessages([payload]);
      });
    }
    this.channel.on("message.reaction_added.v1", (payload?: unknown) => {
      if (!this.stopped && isReactionEvent(payload)) this.callbacks.onReactionAdded(payload);
    });
    this.channel.on("message.reaction_removed.v1", (payload?: unknown) => {
      if (!this.stopped && isReactionEvent(payload)) this.callbacks.onReactionRemoved(payload);
    });
    this.channel.on("conversation.read.v1", (payload?: unknown) => {
      if (!this.stopped && isReadCursorEvent(payload)) this.callbacks.onRead(payload);
    });
    this.channel.on("message.delivery.v1", (payload?: unknown) => {
      if (!this.stopped && isDeliveryCursor(payload)) this.callbacks.onDelivery?.(payload);
    });
    this.channel.on("membership.changed.v1", (payload?: unknown) => {
      if (!this.stopped && isMembershipEvent(payload)) this.callbacks.onMembershipChanged(payload);
    });
    this.channel.on("conversation.updated.v1", () => {
      if (!this.stopped) this.callbacks.onConversationChanged();
    });
    this.channel.on("conversation.archived.v1", () => {
      if (!this.stopped) this.callbacks.onConversationChanged();
    });
    this.channel.on("call.started.v1", (payload?: unknown) => {
      if (!this.stopped && isCallRealtimeEvent(payload, "active", true)) this.deliverCallEvent(payload);
    });
    this.channel.on("call.ended.v1", (payload?: unknown) => {
      if (!this.stopped && isCallRealtimeEvent(payload, "ended", true)) this.deliverCallEvent(payload);
    });
    this.channel.on("audio_call.started.v1", (payload?: unknown) => {
      if (!this.stopped && isCallRealtimeEvent(payload, "active")) {
        if (!this.callbacks.onCallStarted) this.callbacks.onAudioCallStarted(payload);
        this.deliverCallEvent({ ...payload, media_kind: "audio" });
      }
    });
    this.channel.on("audio_call.ended.v1", (payload?: unknown) => {
      if (!this.stopped && isCallRealtimeEvent(payload, "ended")) {
        if (!this.callbacks.onCallEnded) this.callbacks.onAudioCallEnded(payload);
        this.deliverCallEvent({ ...payload, media_kind: "audio" });
      }
    });
    this.channel.on("typing.start", (payload?: unknown) => {
      if (this.stopped) return;
      const userId = readString(payload, "user_id");
      if (userId) this.callbacks.onTyping(userId, true);
    });
    this.channel.on("typing.stop", (payload?: unknown) => {
      if (this.stopped) return;
      const userId = readString(payload, "user_id");
      if (userId) this.callbacks.onTyping(userId, false);
    });
    this.channel.on("typing.v1", (payload?: unknown) => {
      if (this.stopped) return;
      const userId = readString(payload, "user_id");
      const state = readString(payload, "state");
      if (userId && (state === "started" || state === "stopped")) {
        this.callbacks.onTyping(userId, state === "started");
      }
    });
  }

  private deliverCallEvent(event: CallRealtimeEvent): void {
    if (this.stopped) return;
    const key = `${event.id}:${event.status}`;
    if (this.deliveredCallEvents.has(key)) return;
    this.deliveredCallEvents.add(key);
    if (event.status === "active") this.callbacks.onCallStarted?.(event);
    else this.callbacks.onCallEnded?.(event);
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

export interface RealtimeCallCallbacks {
  onReady: (raisedUserIds: string[]) => void;
  onHand: (userId: string, raised: boolean) => void;
  onReaction: (event: { userId: string; emoji: string; occurredAt: string }) => void;
  onParticipantMuted: (userId: string) => void;
  onParticipantRemoved: (userId: string) => void;
  onDirectReady?: (configuration: DirectAudioConfiguration | null) => void;
  onDirectPeers?: (peers: DirectAudioPeer[]) => void;
  onDirectSignal?: (event: DirectAudioSignalEvent) => void;
  onDisconnected?: () => void;
  onError: (message: string) => void;
}

export interface DirectAudioConfiguration {
  peerId: string;
  iceServers: RTCIceServer[];
}

export interface DirectAudioPeer {
  peerId: string;
  userId: string;
}

export type RealtimeDirectAudioSignal =
  | { kind: "offer" | "answer"; sdp: string }
  | { kind: "ice"; candidate: string; sdp_mid: string | null; sdp_mline_index: number | null }
  | { kind: "media"; enabled: boolean }
  | { kind: "fallback" };

export interface DirectAudioSignalEvent {
  fromPeerId: string;
  fromUserId: string;
  signal: RealtimeDirectAudioSignal;
}

export class RealtimeCall {
  private readonly socket: Socket;
  private readonly channel: Channel;
  private stopped = false;

  constructor(
    endpoint: string,
    socketTicket: string,
    callId: string,
    conversationId: string,
    private readonly callbacks: RealtimeCallCallbacks,
    directAudio = false
  ) {
    this.socket = new Socket(endpoint, {
      params: { socket_ticket: socketTicket },
      reconnectAfterMs: (tries) => [1_000, 2_000, 5_000, 10_000][tries - 1] ?? 15_000
    });
    this.channel = (this.socket as DynamicSocket).channel(`call:${callId}`, {
      conversation_id: conversationId,
      direct_audio: directAudio
    });
    this.channel.on("call.hand.v1", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      const raised = readBoolean(payload, "raised");
      if (!this.stopped && userId && raised !== null) callbacks.onHand(userId, raised);
    });
    this.channel.on("call.reaction.v1", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      const emoji = readString(payload, "emoji");
      const occurredAt = readString(payload, "occurred_at");
      if (!this.stopped && userId && emoji && occurredAt) callbacks.onReaction({ userId, emoji, occurredAt });
    });
    this.channel.on("call.participant_muted.v1", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      if (!this.stopped && userId) callbacks.onParticipantMuted(userId);
    });
    this.channel.on("call.participant_removed.v1", (payload?: unknown) => {
      const userId = readString(payload, "user_id");
      if (!this.stopped && userId) callbacks.onParticipantRemoved(userId);
    });
    this.channel.on("call.direct.peers.v1", (payload?: unknown) => {
      if (!this.stopped) callbacks.onDirectPeers?.(readDirectPeers(payload));
    });
    this.channel.on("call.direct.disabled.v1", () => {
      if (this.stopped) return;
      callbacks.onDirectReady?.(null);
      callbacks.onDirectPeers?.([]);
    });
    this.channel.on("call.direct.signal.v1", (payload?: unknown) => {
      const event = readDirectSignalEvent(payload);
      if (!this.stopped && event) callbacks.onDirectSignal?.(event);
    });
    this.channel.onClose(() => {
      if (!this.stopped) callbacks.onDisconnected?.();
    });
  }

  connect(): void {
    this.socket.connect();
    this.channel.join()
      .receive("ok", (response?: unknown) => {
        if (this.stopped) return;
        const values = response && typeof response === "object"
          ? (response as { raised_user_ids?: unknown }).raised_user_ids
          : [];
        this.callbacks.onReady(Array.isArray(values) ? values.filter((value): value is string => typeof value === "string") : []);
        this.callbacks.onDirectReady?.(readDirectConfiguration(response));
      })
      .receive("error", (response?: unknown) => {
        if (!this.stopped) this.callbacks.onError(readReason(response, "Call collaboration is unavailable"));
      })
      .receive("timeout", () => {
        if (!this.stopped) this.callbacks.onError("Call collaboration connection timed out");
      });
  }

  disconnect(): void {
    this.stopped = true;
    this.channel.leave();
    this.socket.disconnect();
  }

  setHand(raised: boolean): Promise<void> {
    return this.push("call.hand.set.v1", { raised });
  }

  react(emoji: string): Promise<void> {
    return this.push("call.reaction.v1", { emoji });
  }

  sendDirectSignal(targetPeerId: string, signal: RealtimeDirectAudioSignal): Promise<void> {
    return this.push("call.direct.signal.v1", { target_peer_id: targetPeerId, signal });
  }

  disableDirectAudio(): Promise<void> {
    return this.push("call.direct.disable.v1", {});
  }

  private push(event: string, payload: Record<string, unknown>): Promise<void> {
    return new Promise((resolve, reject) => {
      if (this.stopped) {
        reject(new Error("Call collaboration is disconnected"));
        return;
      }

      this.channel.push(event, payload)
        .receive("ok", () => resolve())
        .receive("error", (response?: unknown) => reject(new Error(readReason(response, `${event} failed`))))
        .receive("timeout", () => reject(new Error(`${event} timed out`)));
    });
  }
}

function readDirectConfiguration(value: unknown): DirectAudioConfiguration | null {
  if (!value || typeof value !== "object") return null;
  const direct = (value as { direct_audio?: unknown }).direct_audio;
  if (!direct || typeof direct !== "object") return null;
  const record = direct as { enabled?: unknown; peer_id?: unknown; ice_servers?: unknown };
  if (record.enabled !== true || typeof record.peer_id !== "string") return null;
  return {
    peerId: record.peer_id,
    iceServers: Array.isArray(record.ice_servers)
      ? record.ice_servers.filter(isRtcIceServer)
      : []
  };
}

function readDirectPeers(value: unknown): DirectAudioPeer[] {
  if (!value || typeof value !== "object") return [];
  const peers = (value as { peers?: unknown }).peers;
  if (!Array.isArray(peers)) return [];
  return peers.flatMap((peer) => {
    if (!peer || typeof peer !== "object") return [];
    const peerId = readString(peer, "peer_id");
    const userId = readString(peer, "user_id");
    return peerId && userId ? [{ peerId, userId }] : [];
  });
}

function readDirectSignalEvent(value: unknown): DirectAudioSignalEvent | null {
  if (!value || typeof value !== "object") return null;
  const fromPeerId = readString(value, "from_peer_id");
  const fromUserId = readString(value, "from_user_id");
  const signal = (value as { signal?: unknown }).signal;
  if (!fromPeerId || !fromUserId || !isDirectAudioSignal(signal)) return null;
  return { fromPeerId, fromUserId, signal };
}

function isRtcIceServer(value: unknown): value is RTCIceServer {
  if (!value || typeof value !== "object") return false;
  const urls = (value as { urls?: unknown }).urls;
  return typeof urls === "string" || (
    Array.isArray(urls) && urls.length > 0 && urls.every((url) => typeof url === "string")
  );
}

function isDirectAudioSignal(value: unknown): value is RealtimeDirectAudioSignal {
  if (!value || typeof value !== "object") return false;
  const signal = value as Record<string, unknown>;
  if ((signal.kind === "offer" || signal.kind === "answer") && typeof signal.sdp === "string") return true;
  if (signal.kind === "fallback") return true;
  if (signal.kind === "media" && typeof signal.enabled === "boolean") return true;
  return signal.kind === "ice" && typeof signal.candidate === "string";
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
} {
  if (!value || typeof value !== "object") {
    return { messages: [], hasMore: false };
  }
  const response = value as {
    messages?: unknown;
    has_more?: unknown;
  };
  const messages = Array.isArray(response.messages) ? response.messages.filter(isMessage) : [];
  return {
    messages,
    hasMore: response.has_more === true
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

function isCallRealtimeEvent(
  value: unknown,
  expectedStatus: CallRealtimeEvent["status"],
  mediaKindRequired = false
): value is CallRealtimeEvent {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<CallRealtimeEvent>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.conversation_id === "string" &&
    typeof candidate.started_by_user_id === "string" &&
    candidate.status === expectedStatus &&
    (!mediaKindRequired || candidate.media_kind === "audio" || candidate.media_kind === "video") &&
    typeof candidate.started_at === "string" &&
    typeof candidate.expires_at === "string"
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

function isDeliveryCursor(value: unknown): value is MessageDeliveryCursor {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<MessageDeliveryCursor>;
  return typeof candidate.recipient_user_id === "string"
    && typeof candidate.device_ref === "string"
    && typeof candidate.delivered_sequence === "number"
    && typeof candidate.read_sequence === "number";
}

function readString(value: unknown, key: string): string | null {
  if (!value || typeof value !== "object") return null;
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "string" ? candidate : null;
}

function readBoolean(value: unknown, key: string): boolean | null {
  if (!value || typeof value !== "object") return null;
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "boolean" ? candidate : null;
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
