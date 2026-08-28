import { describe, expect, it } from "vitest";
import {
  availableTravel,
  clampPlacement,
  matchingPreset,
  nudgePlacement,
  OVERLAY_EDGE_GAP,
  OVERLAY_PRESETS,
  parseStoredPlacement,
  placementToPosition,
  positionToPlacement
} from "./overlay-placement";

const surface = { width: 200, height: 100 };
const bounds = { top: 0, left: 0, width: 1000, height: 600 };

describe("availableTravel", () => {
  it("is the space left over once the overlay and both gaps are removed", () => {
    expect(availableTravel(surface, bounds)).toEqual({
      width: 1000 - 200 - OVERLAY_EDGE_GAP * 2,
      height: 600 - 100 - OVERLAY_EDGE_GAP * 2
    });
  });

  it("never goes negative when the overlay is larger than its bounds", () => {
    expect(availableTravel({ width: 2000, height: 900 }, bounds)).toEqual({ width: 0, height: 0 });
  });
});

describe("placement round-trips", () => {
  it("puts 0 against the start edge and 1 against the end edge", () => {
    expect(placementToPosition({ x: 0, y: 0 }, surface, bounds)).toEqual({
      left: OVERLAY_EDGE_GAP,
      top: OVERLAY_EDGE_GAP
    });
    expect(placementToPosition({ x: 1, y: 1 }, surface, bounds)).toEqual({
      left: 1000 - 200 - OVERLAY_EDGE_GAP,
      top: 600 - 100 - OVERLAY_EDGE_GAP
    });
  });

  it("survives a round trip through pixels", () => {
    const placement = { x: 0.25, y: 0.75 };
    const position = placementToPosition(placement, surface, bounds);
    expect(positionToPlacement(position, surface, bounds)).toEqual(placement);
  });

  it("stays in bounds at a viewport the placement was never saved at", () => {
    // The reason placement is normalized at all: a pixel offset from a large
    // monitor puts the overlay off the edge of a small one.
    const saved = { x: 1, y: 1 };
    const small = { top: 0, left: 0, width: 320, height: 480 };
    const position = placementToPosition(saved, surface, small);
    expect(position.left + surface.width).toBeLessThanOrEqual(small.width);
    expect(position.top + surface.height).toBeLessThanOrEqual(small.height);
    expect(position.left).toBeGreaterThanOrEqual(0);
    expect(position.top).toBeGreaterThanOrEqual(0);
  });

  it("respects a bounds origin that is not the viewport origin", () => {
    // Safe-area insets move the origin; the overlay must sit inside them.
    const inset = { top: 44, left: 16, width: 800, height: 500 };
    expect(placementToPosition({ x: 0, y: 0 }, surface, inset)).toEqual({
      left: 16 + OVERLAY_EDGE_GAP,
      top: 44 + OVERLAY_EDGE_GAP
    });
  });

  it("collapses an axis with no travel to zero rather than NaN", () => {
    const wide = { width: 1000, height: 100 };
    const placement = positionToPlacement({ top: 20, left: 500 }, wide, bounds);
    expect(placement.x).toBe(0);
    expect(Number.isNaN(placement.x)).toBe(false);
    expect(placementToPosition({ x: 1, y: 0 }, wide, bounds).left).toBe(OVERLAY_EDGE_GAP);
  });

  it("clamps a position pushed past either edge", () => {
    expect(positionToPlacement({ top: -500, left: -500 }, surface, bounds)).toEqual({ x: 0, y: 0 });
    expect(positionToPlacement({ top: 9_999, left: 9_999 }, surface, bounds)).toEqual({ x: 1, y: 1 });
  });
});

describe("nudgePlacement", () => {
  it("moves by a pixel step converted through the current travel", () => {
    const travel = availableTravel(surface, bounds);
    const moved = nudgePlacement({ x: 0, y: 0 }, { x: 8, y: 0 }, surface, bounds);
    expect(moved.x).toBeCloseTo(8 / travel.width);
    expect(moved.y).toBe(0);
  });

  it("cannot be nudged out of bounds", () => {
    expect(nudgePlacement({ x: 1, y: 1 }, { x: 500, y: 500 }, surface, bounds)).toEqual({ x: 1, y: 1 });
    expect(nudgePlacement({ x: 0, y: 0 }, { x: -500, y: -500 }, surface, bounds)).toEqual({ x: 0, y: 0 });
  });

  it("is inert on an axis with no travel", () => {
    expect(nudgePlacement({ x: 0, y: 0 }, { x: 40, y: 0 }, { width: 1000, height: 10 }, bounds).x).toBe(0);
  });
});

describe("matchingPreset", () => {
  it("names the preset a placement is sitting on", () => {
    expect(matchingPreset(OVERLAY_PRESETS["bottom-right"])).toBe("bottom-right");
    expect(matchingPreset({ x: 0, y: 0 })).toBe("top-left");
  });

  it("returns null between presets, so nothing is marked active while dragging", () => {
    expect(matchingPreset({ x: 0.5, y: 0.5 })).toBeNull();
  });
});

describe("parseStoredPlacement", () => {
  it("reads a placement it wrote", () => {
    expect(parseStoredPlacement(JSON.stringify({ x: 0.4, y: 0.6 }))).toEqual({ x: 0.4, y: 0.6 });
  });

  it("treats every malformed value as no preference", () => {
    // Storage is shared with other tabs, older builds and the user, so this
    // is untrusted input: a bad record must never become a NaN placement.
    for (const raw of [
      null,
      "",
      "not json",
      "null",
      "[]",
      "42",
      JSON.stringify({ x: 1 }),
      JSON.stringify({ x: "1", y: "0" }),
      JSON.stringify({ x: Number.NaN, y: 0 })
    ]) {
      expect(parseStoredPlacement(raw)).toBeNull();
    }
  });

  it("clamps a stored value that is out of range", () => {
    expect(parseStoredPlacement(JSON.stringify({ x: 9, y: -9 }))).toEqual({ x: 1, y: 0 });
  });
});

describe("clampPlacement", () => {
  it("rejects non-finite input rather than propagating it", () => {
    expect(clampPlacement({ x: Number.NaN, y: Number.POSITIVE_INFINITY })).toEqual({ x: 0, y: 1 });
  });
});
