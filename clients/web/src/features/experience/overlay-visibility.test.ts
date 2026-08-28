import { describe, expect, it } from "vitest";
import {
  activeKeepVisibleReasons,
  isIntentionalMove,
  mayCollapse,
  NO_KEEP_VISIBLE_CONDITIONS,
  POINTER_JITTER_PX,
  type KeepVisibleReason
} from "./overlay-visibility";

const EVERY_REASON: KeepVisibleReason[] = [
  "alwaysShow",
  "dragging",
  "hovering",
  "focusWithin",
  "menuOpen",
  "pendingAction",
  "pinned",
  "blockingAlert"
];

describe("keep-visible conditions", () => {
  it("allows collapse only when nothing is holding the controls open", () => {
    expect(mayCollapse(NO_KEEP_VISIBLE_CONDITIONS)).toBe(true);
  });

  it("is held open by every condition the contract lists, on its own", () => {
    // Each is enumerated rather than spot-checked: a condition dropped from
    // the type would otherwise pass silently.
    for (const reason of EVERY_REASON) {
      const conditions = { ...NO_KEEP_VISIBLE_CONDITIONS, [reason]: true };
      expect(mayCollapse(conditions), `${reason} should hold the controls open`).toBe(false);
      expect(activeKeepVisibleReasons(conditions)).toEqual([reason]);
    }
  });

  it("covers exactly the conditions the contract names", () => {
    expect(Object.keys(NO_KEEP_VISIBLE_CONDITIONS).sort()).toEqual([...EVERY_REASON].sort());
  });

  it("reports several reasons at once, in a stable order", () => {
    const reasons = activeKeepVisibleReasons({
      ...NO_KEEP_VISIBLE_CONDITIONS,
      hovering: true,
      pinned: true,
      dragging: true
    });
    expect(reasons).toEqual(["dragging", "hovering", "pinned"]);
  });
});

describe("isIntentionalMove", () => {
  it("treats the first movement as intent", () => {
    expect(isIntentionalMove(null, { x: 0, y: 0 })).toBe(true);
  });

  it("ignores movement below the jitter floor", () => {
    // A resting hand and a high-polling-rate mouse both emit these
    // continuously; counting them resets the timer forever.
    expect(isIntentionalMove({ x: 100, y: 100 }, { x: 101, y: 101 })).toBe(false);
    expect(isIntentionalMove({ x: 100, y: 100 }, { x: 102, y: 102 })).toBe(false);
  });

  it("counts movement at or beyond the floor", () => {
    expect(isIntentionalMove({ x: 100, y: 100 }, { x: 100 + POINTER_JITTER_PX, y: 100 })).toBe(true);
    expect(isIntentionalMove({ x: 100, y: 100 }, { x: 140, y: 130 })).toBe(true);
  });

  it("measures from the last intentional point, not the previous event", () => {
    // A one-pixel-per-event drift crosses the room without any single step
    // clearing the threshold. Anchoring to the last accepted point is what
    // makes the accumulated distance count.
    const anchor = { x: 0, y: 0 };
    expect(isIntentionalMove(anchor, { x: 1, y: 0 })).toBe(false);
    expect(isIntentionalMove(anchor, { x: 2, y: 0 })).toBe(false);
    expect(isIntentionalMove(anchor, { x: 3, y: 0 })).toBe(false);
    expect(isIntentionalMove(anchor, { x: 4, y: 0 })).toBe(true);
  });

  it("honours a caller-supplied floor", () => {
    expect(isIntentionalMove({ x: 0, y: 0 }, { x: 6, y: 0 }, 10)).toBe(false);
    expect(isIntentionalMove({ x: 0, y: 0 }, { x: 12, y: 0 }, 10)).toBe(true);
  });
});
