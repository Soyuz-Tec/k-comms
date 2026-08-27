import { describe, expect, it, vi } from "vitest";
import {
  experienceReducer,
  initialExperienceState,
  type ExperienceState
} from "./experience-mode";
import {
  IMMERSIVE_JOIN_DEADLINE_MS,
  resolveImmersiveWithinDeadline,
  selectImmersiveEligibility
} from "./immersive-eligibility";
import type { ServiceStatus, UserCapabilities } from "../../types";

function status(immersive?: boolean): ServiceStatus {
  return {
    service: "k-comms",
    version: "test",
    status: "operational",
    capabilities: {
      administration: true,
      attachment_scanning: true,
      bootstrap: false,
      guest_links: true,
      immersive_mode: immersive,
      instant_rooms: true,
      notifications: true,
      realtime: true,
      secure_account_actions: true,
      secure_media_actions: true,
      webhooks: true
    }
  };
}

function capabilities(immersive?: boolean): UserCapabilities {
  return {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_immersive_mode: immersive,
    allow_public_channels: true,
    message_edit_window_seconds: 900,
    max_attachment_bytes: 1024
  };
}

describe("selectImmersiveEligibility", () => {
  it("requires both the deployment switch and the tenant switch", () => {
    expect(selectImmersiveEligibility(status(true), capabilities(true))).toBe(true);
    expect(selectImmersiveEligibility(status(false), capabilities(true))).toBe(false);
    expect(selectImmersiveEligibility(status(true), capabilities(false))).toBe(false);
  });

  it("treats a server that omits the switches as ineligible", () => {
    expect(selectImmersiveEligibility(status(undefined), capabilities(undefined))).toBe(false);
    expect(selectImmersiveEligibility(status(true), capabilities(undefined))).toBe(false);
  });

  it("treats missing status or capabilities as ineligible", () => {
    expect(selectImmersiveEligibility(null, capabilities(true))).toBe(false);
    expect(selectImmersiveEligibility(status(true), null)).toBe(false);
    expect(selectImmersiveEligibility(undefined, undefined)).toBe(false);
  });

  it("does not accept a truthy non-boolean as consent", () => {
    const malformed = { ...capabilities(), allow_immersive_mode: "yes" } as unknown as UserCapabilities;
    expect(selectImmersiveEligibility(status(true), malformed)).toBe(false);
  });
});

describe("resolveImmersiveWithinDeadline", () => {
  it("takes a positive decision that arrives before the deadline", async () => {
    await expect(resolveImmersiveWithinDeadline(Promise.resolve(true))).resolves.toBe(true);
  });

  it("selects the legacy UI when the decision is still pending at the deadline", async () => {
    vi.useFakeTimers();
    try {
      const never = new Promise<boolean>(() => {});
      const resolved = resolveImmersiveWithinDeadline(never, IMMERSIVE_JOIN_DEADLINE_MS);
      await vi.advanceTimersByTimeAsync(IMMERSIVE_JOIN_DEADLINE_MS);
      await expect(resolved).resolves.toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("treats a failed capability lookup as denied rather than propagating", async () => {
    await expect(
      resolveImmersiveWithinDeadline(Promise.reject(new Error("offline")))
    ).resolves.toBe(false);
  });
});

describe("experienceReducer", () => {
  const joined: ExperienceState = experienceReducer(initialExperienceState, {
    type: "CALL_JOINED",
    callId: "call-1",
    immersive: true
  });

  it("starts in workspace", () => {
    expect(initialExperienceState.mode).toBe("workspace");
  });

  it("enters immersive on an eligible join and workspace on an ineligible one", () => {
    expect(joined.mode).toBe("immersive");
    expect(
      experienceReducer(initialExperienceState, {
        type: "CALL_JOINED",
        callId: "call-1",
        immersive: false
      }).mode
    ).toBe("workspace");
  });

  it("keeps the decision sticky for the joined call", () => {
    // A late positive result must not upgrade a call that already started
    // legacy: that would remount the media tree mid-call.
    const legacy = experienceReducer(initialExperienceState, {
      type: "CALL_JOINED",
      callId: "call-1",
      immersive: false
    });
    const late = experienceReducer(legacy, {
      type: "CALL_JOINED",
      callId: "call-1",
      immersive: true
    });
    expect(late).toBe(legacy);
    expect(late.mode).toBe("workspace");
  });

  it("decides again for the next call", () => {
    const next = experienceReducer(joined, {
      type: "CALL_JOINED",
      callId: "call-2",
      immersive: false
    });
    expect(next.mode).toBe("workspace");
    expect(next.decidedForCallId).toBe("call-2");
  });

  it("returns to workspace and releases the binding when the call ends", () => {
    const left = experienceReducer(joined, { type: "CALL_LEFT" });
    expect(left.mode).toBe("workspace");
    expect(left.decidedForCallId).toBeNull();
  });

  it("ignores ENTER_FOCUS without the experiment flag", () => {
    expect(experienceReducer(initialExperienceState, { type: "ENTER_FOCUS" }))
      .toBe(initialExperienceState);
    expect(
      experienceReducer(initialExperienceState, { type: "ENTER_FOCUS", authorized: true }).mode
    ).toBe("focus");
  });

  it("lets a server disable block the next entry without disturbing the current call", () => {
    const withdrawn = experienceReducer(joined, { type: "WITHDRAW_ENTRY" });
    expect(withdrawn.mode).toBe("immersive");

    const next = experienceReducer(withdrawn, {
      type: "CALL_JOINED",
      callId: "call-2",
      immersive: true
    });
    expect(next.mode).toBe("workspace");
  });

  it("returns the same state object when nothing changes", () => {
    expect(experienceReducer(initialExperienceState, { type: "EXIT_TO_WORKSPACE" }))
      .toBe(initialExperienceState);
    expect(experienceReducer(initialExperienceState, { type: "CALL_LEFT" }))
      .toBe(initialExperienceState);
  });
});
