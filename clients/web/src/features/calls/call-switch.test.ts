import { describe, expect, it } from "vitest";
import {
  callSwitchReducer,
  initialCallSwitchState,
  previousCallReleased,
  switchFailureMessage,
  type CallSwitchState,
  type PendingCallSwitch
} from "./call-switch";
import type { CallPanelSessionState, CallPhase } from "./callContracts";

const pending: PendingCallSwitch = {
  conversationId: "conversation-2",
  conversationTitle: "Design",
  kind: "audio",
  readinessMode: null,
  leavingTitle: "Standup"
};

function sessionAt(phase: CallPhase): CallPanelSessionState {
  return {
    conversationId: "conversation-1",
    callId: "call-1",
    phase,
    mediaKind: "audio",
    joined: phase === "connected",
    microphoneEnabled: true,
    cameraEnabled: false,
    screenShareEnabled: false,
    canEnd: false,
    accessRevoked: false,
    transportMode: "livekit"
  };
}

const confirming = callSwitchReducer(initialCallSwitchState, { type: "REQUEST", pending });
const leaving = callSwitchReducer(confirming, { type: "CONFIRM" });

describe("callSwitchReducer", () => {
  it("starts idle and asks before doing anything", () => {
    expect(initialCallSwitchState.phase).toBe("idle");
    expect(confirming.phase).toBe("confirming");
    expect(confirming.pending).toEqual(pending);
  });

  it("leaves the current call untouched when the switch is declined", () => {
    expect(callSwitchReducer(confirming, { type: "CANCEL" })).toEqual(initialCallSwitchState);
  });

  it("only starts leaving after an explicit confirmation", () => {
    // No path from a request straight to leaving: switching requires
    // confirmation, not merely an attempt to call someone else.
    expect(callSwitchReducer(confirming, { type: "RELEASED" })).toBe(confirming);
    expect(leaving.phase).toBe("leaving");
  });

  it("returns to idle once the previous call has released", () => {
    expect(callSwitchReducer(leaving, { type: "RELEASED" })).toEqual(initialCallSwitchState);
  });

  it("reports a failure instead of proceeding, and keeps the target named", () => {
    const failed = callSwitchReducer(leaving, { type: "FAILED", reason: "timed out" });
    expect(failed.phase).toBe("failed");
    expect(failed.failure).toBe("timed out");
    // Kept so the message can name the call that was not joined.
    expect(failed.pending).toEqual(pending);
  });

  it("cannot be released or failed except while leaving", () => {
    // Guards against a stale timer or a late state change resurrecting a
    // switch the user already cancelled.
    for (const state of [initialCallSwitchState, confirming] as CallSwitchState[]) {
      expect(callSwitchReducer(state, { type: "RELEASED" })).toBe(state);
      expect(callSwitchReducer(state, { type: "FAILED", reason: "x" })).toBe(state);
    }
  });

  it("ignores a new request while a leave is already in flight", () => {
    // Queueing a second target mid-leave is how you end up joining the wrong
    // call, or two of them.
    expect(
      callSwitchReducer(leaving, {
        type: "REQUEST",
        pending: { ...pending, conversationId: "conversation-3" }
      })
    ).toBe(leaving);
  });

  it("replaces the target when a new request arrives while merely confirming", () => {
    const next = callSwitchReducer(confirming, {
      type: "REQUEST",
      pending: { ...pending, conversationId: "conversation-3", conversationTitle: "Ops" }
    });
    expect(next.phase).toBe("confirming");
    expect(next.pending?.conversationTitle).toBe("Ops");
  });

  it("clears a failure when dismissed", () => {
    const failed = callSwitchReducer(leaving, { type: "FAILED", reason: "timed out" });
    expect(callSwitchReducer(failed, { type: "DISMISS" })).toEqual(initialCallSwitchState);
  });
});

describe("previousCallReleased", () => {
  it("is true when there is no call at all", () => {
    expect(previousCallReleased(null)).toBe(true);
  });

  it.each(["ended", "idle", "error"] as CallPhase[])(
    "treats %s as released",
    (phase) => {
      // `error` counts because an errored call is not holding a room. That is
      // not the same as a successful leave, which is why the predicate is not
      // named for one.
      expect(previousCallReleased(sessionAt(phase))).toBe(true);
    }
  );

  it.each(["prejoin", "joining", "connected", "reconnecting", "leaving"] as CallPhase[])(
    "treats %s as still holding the room",
    (phase) => {
      expect(previousCallReleased(sessionAt(phase))).toBe(false);
    }
  );

  it("does not treat a leave in progress as done", () => {
    // The precise case the contract forbids: joining while the leave is
    // pending would put two rooms on the wire.
    expect(previousCallReleased(sessionAt("leaving"))).toBe(false);
  });
});

describe("switchFailureMessage", () => {
  it("names both calls and says which one you are still in", () => {
    const message = switchFailureMessage(pending);
    expect(message).toContain("Standup");
    expect(message).toContain("Design");
    expect(message).toContain("still in Standup");
  });

  it("stays truthful without a target", () => {
    expect(switchFailureMessage(null)).toContain("still in");
  });
});
