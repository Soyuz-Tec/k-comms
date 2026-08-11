import { beforeEach, describe, expect, it, vi } from "vitest";
import { RealtimeCall, type RealtimeCallCallbacks } from "./realtime";

const phoenix = vi.hoisted(() => ({
  handlers: new Map<string, (payload?: unknown) => void>(),
  joinResponse: undefined as unknown,
  joinParams: null as Record<string, unknown> | null,
  pushed: [] as Array<{ event: string; payload: Record<string, unknown> }>,
  closeCallback: null as (() => void) | null
}));

vi.mock("phoenix", () => ({
  Presence: class MockPresence {},
  Socket: class MockSocket {
    channel(_topic: string, params: Record<string, unknown>) {
      phoenix.joinParams = params;
      return {
        on: (event: string, callback: (payload?: unknown) => void) => {
          phoenix.handlers.set(event, callback);
        },
        onClose: (callback: () => void) => {
          phoenix.closeCallback = callback;
        },
        join: () => {
          const push = {
            receive: (status: string, callback: (payload?: unknown) => void) => {
              if (status === "ok") callback(phoenix.joinResponse);
              return push;
            }
          };
          return push;
        },
        leave: vi.fn(),
        push: (event: string, payload: Record<string, unknown>) => {
          phoenix.pushed.push({ event, payload });
          const push = {
            receive: (status: string, callback: (payload?: unknown) => void) => {
              if (status === "ok") callback(undefined);
              return push;
            }
          };
          return push;
        }
      };
    }
    connect() { /* test double */ }
    disconnect() { /* test double */ }
  }
}));

function callbacks(): RealtimeCallCallbacks {
  return {
    onReady: vi.fn(),
    onHand: vi.fn(),
    onReaction: vi.fn(),
    onParticipantMuted: vi.fn(),
    onParticipantRemoved: vi.fn(),
    onDirectReady: vi.fn(),
    onDirectPeers: vi.fn(),
    onDirectSignal: vi.fn(),
    onDisconnected: vi.fn(),
    onError: vi.fn()
  };
}

describe("RealtimeCall direct audio", () => {
  beforeEach(() => {
    phoenix.handlers.clear();
    phoenix.joinParams = null;
    phoenix.pushed = [];
    phoenix.closeCallback = null;
    phoenix.joinResponse = {
      raised_user_ids: ["user-2"],
      direct_audio: {
        enabled: true,
        peer_id: "local-peer-id-12345678",
        ice_servers: [{ urls: ["stun:stun.cloudflare.com:3478"] }]
      }
    };
  });

  it("opts in at join and parses only bounded direct collaboration envelopes", async () => {
    const listener = callbacks();
    const realtime = new RealtimeCall(
      "/socket",
      "ticket",
      "call-1",
      "conversation-1",
      listener,
      true
    );

    realtime.connect();
    expect(phoenix.joinParams).toEqual({
      conversation_id: "conversation-1",
      direct_audio: true
    });
    expect(listener.onReady).toHaveBeenCalledWith(["user-2"]);
    expect(listener.onDirectReady).toHaveBeenCalledWith({
      peerId: "local-peer-id-12345678",
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }]
    });

    phoenix.handlers.get("call.direct.peers.v1")?.({
      peers: [{ peer_id: "remote-peer-id-1234567", user_id: "user-2" }]
    });
    expect(listener.onDirectPeers).toHaveBeenCalledWith([
      { peerId: "remote-peer-id-1234567", userId: "user-2" }
    ]);

    phoenix.handlers.get("call.direct.signal.v1")?.({
      from_peer_id: "remote-peer-id-1234567",
      from_user_id: "user-2",
      signal: { kind: "offer", sdp: "v=0\r\n" }
    });
    expect(listener.onDirectSignal).toHaveBeenCalledWith({
      fromPeerId: "remote-peer-id-1234567",
      fromUserId: "user-2",
      signal: { kind: "offer", sdp: "v=0\r\n" }
    });

    await realtime.sendDirectSignal("remote-peer-id-1234567", { kind: "fallback" });
    expect(phoenix.pushed).toContainEqual({
      event: "call.direct.signal.v1",
      payload: {
        target_peer_id: "remote-peer-id-1234567",
        signal: { kind: "fallback" }
      }
    });

    phoenix.handlers.get("call.direct.disabled.v1")?.({ reason: "peer_limit" });
    expect(listener.onDirectReady).toHaveBeenLastCalledWith(null);
    expect(listener.onDirectPeers).toHaveBeenLastCalledWith([]);

    await realtime.disableDirectAudio();
    expect(phoenix.pushed).toContainEqual({
      event: "call.direct.disable.v1",
      payload: {}
    });

    phoenix.closeCallback?.();
    expect(listener.onDisconnected).toHaveBeenCalledTimes(1);
  });
});
