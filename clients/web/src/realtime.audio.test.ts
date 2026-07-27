import { beforeEach, describe, expect, it, vi } from "vitest";
import { RealtimeConversation } from "./realtime";
import type { RealtimeCallbacks } from "./realtime";

const phoenix = vi.hoisted(() => ({
  handlers: new Map<string, (payload?: unknown) => void>(),
  joinResponse: undefined as unknown,
  joinParams: null as Record<string, unknown> | null
}));

vi.mock("phoenix", () => ({
  Presence: class MockPresence {
    private sync: (() => void) | null = null;
    private readonly keys = new Set<string>();

    constructor(channel: {
      on: (event: string, callback: (payload?: unknown) => void) => void;
    }) {
      channel.on("presence_state", (payload?: unknown) => {
        this.keys.clear();
        if (payload && typeof payload === "object") {
          Object.keys(payload).forEach((key) => this.keys.add(key));
        }
        this.sync?.();
      });
      channel.on("presence_diff", (payload?: unknown) => {
        const diff =
          payload && typeof payload === "object"
            ? payload as { joins?: object; leaves?: object }
            : {};
        Object.keys(diff.joins || {}).forEach((key) => this.keys.add(key));
        Object.keys(diff.leaves || {}).forEach((key) => this.keys.delete(key));
        this.sync?.();
      });
    }

    onSync(callback: () => void) { this.sync = callback; }
    list() { return [...this.keys]; }
  },
  Socket: class MockSocket {
    channel(
      _topic: string,
      params: Record<string, unknown> | (() => Record<string, unknown>)
    ) {
      return {
        on: (event: string, callback: (payload?: unknown) => void) => {
          phoenix.handlers.set(event, callback);
        },
        onError: () => undefined,
        join: () => {
          phoenix.joinParams =
            typeof params === "function" ? params() : params;
          const push = {
            receive: (
              status: string,
              callback: (payload?: unknown) => void
            ) => {
              if (status === "ok") callback(phoenix.joinResponse);
              return push;
            }
          };
          return push;
        },
        leave: () => undefined,
        push: () => ({ receive: () => undefined })
      };
    }
    onOpen() { /* test double */ }
    onError() { /* test double */ }
    onClose() { /* test double */ }
    connect() { /* test double */ }
    disconnect() { /* test double */ }
  }
}));

function callbacks(): RealtimeCallbacks {
  return {
    onStatus: vi.fn(),
    onMessages: vi.fn(),
    onReactionAdded: vi.fn(),
    onReactionRemoved: vi.fn(),
    onRead: vi.fn(),
    onMembershipChanged: vi.fn(),
    onConversationChanged: vi.fn(),
    onAudioCallStarted: vi.fn(),
    onAudioCallEnded: vi.fn(),
    onCatchUpRequired: vi.fn(),
    onTyping: vi.fn(),
    onPresence: vi.fn(),
    onError: vi.fn(),
    onReconnectRequired: vi.fn()
  };
}

describe("RealtimeConversation audio call events", () => {
  beforeEach(() => {
    phoenix.handlers.clear();
    phoenix.joinResponse = undefined;
    phoenix.joinParams = null;
  });

  it("reconciles socket replay through REST from the pre-replay sequence", () => {
    const listener = callbacks();
    let afterSequence = 7;
    const replayed = {
      id: "message-8",
      tenant_id: "tenant-1",
      conversation_id: "conversation-1",
      sender_user_id: "departed-guest",
      sender_device_id: "device-1",
      client_message_id: "client-8",
      conversation_sequence: 8,
      body: "Replayed message",
      metadata: {},
      status: "active",
      inserted_at: "2026-07-25T10:00:00Z",
      attachments: [],
      reactions: []
    };
    phoenix.joinResponse = {
      messages: [replayed],
      has_more: false,
      next_after_sequence: 8
    };
    vi.mocked(listener.onMessages).mockImplementation(() => {
      afterSequence = 8;
    });
    const realtime = new RealtimeConversation(
      "/socket",
      "ticket",
      "conversation-1",
      () => afterSequence,
      listener
    );

    realtime.connect();

    expect(phoenix.joinParams).toMatchObject({ after_sequence: 7 });
    expect(listener.onMessages).toHaveBeenCalledWith([replayed]);
    expect(listener.onCatchUpRequired).toHaveBeenCalledWith(7);
    expect(listener.onCatchUpRequired).toHaveBeenCalledTimes(1);
  });

  it("binds the versioned start and end broadcasts and validates their status", () => {
    const listener = callbacks();
    new RealtimeConversation("/socket", "ticket", "conversation-1", () => 0, listener);
    const active = {
      id: "call-1",
      conversation_id: "conversation-1",
      started_by_user_id: "user-1",
      status: "active",
      started_at: "2026-07-15T10:00:00Z",
      expires_at: "2026-07-15T11:00:00Z"
    };

    phoenix.handlers.get("audio_call.started.v1")?.(active);
    phoenix.handlers.get("audio_call.ended.v1")?.({
      ...active,
      status: "ended",
      ended_at: "2026-07-15T10:30:00Z",
      end_reason: "ended_by_user"
    });
    phoenix.handlers.get("audio_call.started.v1")?.({ ...active, status: "ended" });

    expect(listener.onAudioCallStarted).toHaveBeenCalledTimes(1);
    expect(listener.onAudioCallStarted).toHaveBeenCalledWith(active);
    expect(listener.onAudioCallEnded).toHaveBeenCalledTimes(1);
    expect(listener.onAudioCallEnded).toHaveBeenCalledWith(expect.objectContaining({ id: "call-1", status: "ended" }));
  });

  it("normalizes legacy audio events and deduplicates dual canonical broadcasts", () => {
    const listener = { ...callbacks(), onCallStarted: vi.fn(), onCallEnded: vi.fn() };
    new RealtimeConversation("/socket", "ticket", "conversation-1", () => 0, listener);
    const active = {
      id: "call-2",
      conversation_id: "conversation-1",
      started_by_user_id: "user-1",
      media_kind: "audio" as const,
      status: "active" as const,
      started_at: "2026-07-15T10:00:00Z",
      expires_at: "2026-07-15T11:00:00Z"
    };
    const legacyActive = { ...active, media_kind: undefined };

    phoenix.handlers.get("call.started.v1")?.(active);
    phoenix.handlers.get("audio_call.started.v1")?.(legacyActive);
    phoenix.handlers.get("call.ended.v1")?.({ ...active, status: "ended" });
    phoenix.handlers.get("audio_call.ended.v1")?.({ ...legacyActive, status: "ended" });

    expect(listener.onCallStarted).toHaveBeenCalledTimes(1);
    expect(listener.onCallEnded).toHaveBeenCalledTimes(1);
    expect(listener.onAudioCallStarted).not.toHaveBeenCalled();
    expect(listener.onAudioCallEnded).not.toHaveBeenCalled();
  });

  it("reports the final Presence key count instead of accumulating diff arithmetic", () => {
    const listener = callbacks();
    new RealtimeConversation("/socket", "ticket", "conversation-1", () => 0, listener);

    phoenix.handlers.get("presence_state")?.({
      "user-1": { metas: [{ phx_ref: "one" }, { phx_ref: "two" }] },
      "user-2": { metas: [{ phx_ref: "three" }] }
    });
    phoenix.handlers.get("presence_diff")?.({
      joins: { "user-1": { metas: [{ phx_ref: "four" }] } },
      leaves: { "already-gone": { metas: [{ phx_ref: "old" }] } }
    });

    expect(listener.onPresence).toHaveBeenNthCalledWith(
      1,
      2,
      ["user-1", "user-2"]
    );
    expect(listener.onPresence).toHaveBeenNthCalledWith(
      2,
      2,
      ["user-1", "user-2"]
    );
  });

  it("drops buffered channel and Presence callbacks after disconnect", () => {
    const listener = callbacks();
    const realtime = new RealtimeConversation(
      "/socket",
      "ticket",
      "conversation-1",
      () => 0,
      listener
    );
    realtime.disconnect();
    vi.mocked(listener.onStatus).mockClear();

    phoenix.handlers.get("presence_state")?.({
      "user-1": { metas: [{ phx_ref: "one" }] }
    });
    phoenix.handlers.get("typing.start")?.({ user_id: "user-1" });
    phoenix.handlers.get("membership.changed.v1")?.({
      conversation_id: "conversation-1",
      action: "added"
    });

    expect(listener.onPresence).not.toHaveBeenCalled();
    expect(listener.onTyping).not.toHaveBeenCalled();
    expect(listener.onMembershipChanged).not.toHaveBeenCalled();
    expect(listener.onStatus).not.toHaveBeenCalled();
  });
});
