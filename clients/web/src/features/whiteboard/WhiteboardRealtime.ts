import { Socket } from "phoenix";
import type { Channel } from "phoenix";
import type {
  WhiteboardOperation,
  WhiteboardPresenceEvent
} from "../../types";

interface DynamicSocket extends Socket {
  channel(
    topic: string,
    params: Record<string, unknown>
  ): Channel;
}

export interface WhiteboardRealtimeCallbacks {
  onOperation: (operation: WhiteboardOperation) => void;
  onPresence: (presence: WhiteboardPresenceEvent) => void;
  onStatus: (status: "connecting" | "live" | "offline") => void;
  onError: (message: string) => void;
}

export class WhiteboardRealtime {
  private readonly socket: Socket;
  private readonly channel: Channel;
  private stopped = false;

  constructor(
    endpoint: string,
    socketTicket: string,
    conversationId: string,
    private readonly callbacks: WhiteboardRealtimeCallbacks
  ) {
    this.socket = new Socket(endpoint, {
      params: { socket_ticket: socketTicket },
      reconnectAfterMs: () => 60_000,
      rejoinAfterMs: (tries) =>
        [1_000, 2_000, 5_000, 10_000][tries - 1] ?? 15_000
    });
    this.channel = (this.socket as DynamicSocket).channel(
      `whiteboard:${conversationId}`,
      { protocol_version: 1 }
    );
    this.bindEvents();
  }

  connect(): Promise<void> {
    this.callbacks.onStatus("connecting");
    this.socket.connect();

    return new Promise((resolve, reject) => {
      this.channel
        .join()
        .receive("ok", () => {
          if (this.stopped) return;
          this.callbacks.onStatus("live");
          resolve();
        })
        .receive("error", (response?: unknown) => {
          const reason = readReason(response, "Unable to join the whiteboard");
          this.callbacks.onError(reason);
          reject(new Error(reason));
        })
        .receive("timeout", () => {
          const reason = "Whiteboard connection timed out";
          this.callbacks.onError(reason);
          reject(new Error(reason));
        });
    });
  }

  sendPresence(input: {
    pointer: { x: number; y: number; tool: "pointer" | "laser" };
    button: "up" | "down";
    selected_element_ids: string[];
  }): void {
    if (this.stopped) return;
    this.channel.push("whiteboard.presence.v1", input);
  }

  disconnect(notify = true): void {
    this.stopped = true;
    this.channel.leave();
    this.socket.disconnect();
    if (notify) this.callbacks.onStatus("offline");
  }

  private bindEvents(): void {
    this.channel.on(
      "whiteboard.operation_applied.v1",
      (payload?: unknown) => {
        if (!this.stopped && isWhiteboardOperation(payload)) {
          this.callbacks.onOperation(payload);
        }
      }
    );
    this.channel.on("whiteboard.presence.v1", (payload?: unknown) => {
      if (!this.stopped && isWhiteboardPresence(payload)) {
        this.callbacks.onPresence(payload);
      }
    });
    this.socket.onError(() => this.fail("Whiteboard connection was interrupted"));
    this.socket.onClose(() => this.fail("Whiteboard connection closed"));
    this.channel.onError(() => this.fail("Whiteboard channel was interrupted"));
  }

  private fail(message: string): void {
    if (this.stopped) return;
    this.callbacks.onStatus("offline");
    this.callbacks.onError(message);
  }
}

function isWhiteboardOperation(value: unknown): value is WhiteboardOperation {
  if (!value || typeof value !== "object") return false;
  const operation = value as Partial<WhiteboardOperation>;
  return (
    typeof operation.id === "string" &&
    typeof operation.conversation_id === "string" &&
    typeof operation.sequence === "number" &&
    (operation.kind === "scene.update" || operation.kind === "board.clear") &&
    Boolean(operation.payload && typeof operation.payload === "object")
  );
}

function isWhiteboardPresence(value: unknown): value is WhiteboardPresenceEvent {
  if (!value || typeof value !== "object") return false;
  const presence = value as Partial<WhiteboardPresenceEvent>;
  return (
    typeof presence.user_id === "string" &&
    typeof presence.device_id === "string" &&
    Boolean(presence.pointer) &&
    typeof presence.pointer?.x === "number" &&
    typeof presence.pointer?.y === "number" &&
    (presence.pointer?.tool === "pointer" || presence.pointer?.tool === "laser") &&
    typeof presence.button === "boolean" &&
    Array.isArray(presence.selected_element_ids) &&
    presence.selected_element_ids.every((id) => typeof id === "string")
  );
}

function readReason(value: unknown, fallback: string): string {
  if (!value || typeof value !== "object") return fallback;
  const reason = (value as { reason?: unknown }).reason;
  return typeof reason === "string" && reason ? reason : fallback;
}
