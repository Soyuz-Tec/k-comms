/**
 * Placement maths for movable overlays.
 *
 * Kept separate from any component so the rules that matter -- what "in
 * bounds" means, and what survives a reload -- can be tested without a DOM,
 * a pointer, or a React tree.
 *
 * Placement is stored **normalized**, as a fraction of the travel available
 * to the overlay, never as raw pixels (§6.1). The difference is not
 * cosmetic: a pixel offset saved on a 2560px monitor puts the overlay off
 * the edge of a laptop, and a saved offset that was valid before a phone
 * rotated is invalid after. A fraction of available travel is in bounds at
 * every size by construction, which is what makes "clamps after viewport or
 * safe-area change, and never restores off-screen" a property rather than a
 * hope.
 */

export interface NormalizedPlacement {
  /** 0 = against the start edge, 1 = against the end edge. */
  x: number;
  y: number;
}

export interface Box {
  width: number;
  height: number;
}

export interface Bounds extends Box {
  top: number;
  left: number;
}

/** Breathing room kept between an overlay and the edge it is pushed against. */
export const OVERLAY_EDGE_GAP = 8;

/**
 * Where an overlay can be placed, in preset form.
 *
 * §6.1 requires placement by handle, keyboard *and* preset control --
 * "dragging is an enhancement, not the only placement mechanism". Corners are
 * what the collision rules actually need: the point of moving the companion is
 * to get it off the composer, the captions, or a whiteboard control, and a
 * corner is the coarse, reliable way to say which.
 */
export const OVERLAY_PRESETS = {
  "top-left": { x: 0, y: 0 },
  "top-right": { x: 1, y: 0 },
  "bottom-left": { x: 0, y: 1 },
  "bottom-right": { x: 1, y: 1 }
} as const satisfies Record<string, NormalizedPlacement>;

export type OverlayPresetName = keyof typeof OVERLAY_PRESETS;

export const OVERLAY_PRESET_LABELS: Record<OverlayPresetName, string> = {
  "top-left": "Top left",
  "top-right": "Top right",
  "bottom-left": "Bottom left",
  "bottom-right": "Bottom right"
};

function clamp01(value: number): number {
  // Only NaN is meaningless. An infinity is "past that edge", and Math.min /
  // Math.max already resolve it to the edge -- treating it as invalid would
  // quietly send an overlay to the top-left instead of where it was pushed.
  if (Number.isNaN(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

/**
 * The pixel travel available on each axis.
 *
 * Zero -- or negative, when the overlay is wider than its bounds -- means the
 * axis cannot move. Callers must not divide by this without checking.
 */
export function availableTravel(surface: Box, bounds: Box): Box {
  return {
    width: Math.max(0, bounds.width - surface.width - OVERLAY_EDGE_GAP * 2),
    height: Math.max(0, bounds.height - surface.height - OVERLAY_EDGE_GAP * 2)
  };
}

/** Normalized placement -> the top-left pixel position within the bounds. */
export function placementToPosition(
  placement: NormalizedPlacement,
  surface: Box,
  bounds: Bounds
): { top: number; left: number } {
  const travel = availableTravel(surface, bounds);
  return {
    left: bounds.left + OVERLAY_EDGE_GAP + clamp01(placement.x) * travel.width,
    top: bounds.top + OVERLAY_EDGE_GAP + clamp01(placement.y) * travel.height
  };
}

/** A pixel position -> normalized placement, clamped into range. */
export function positionToPlacement(
  position: { top: number; left: number },
  surface: Box,
  bounds: Bounds
): NormalizedPlacement {
  const travel = availableTravel(surface, bounds);
  return {
    // An axis with no travel collapses to 0 rather than NaN. Dividing by a
    // zero-width axis is the one arithmetic hazard in here.
    x: travel.width === 0 ? 0 : clamp01((position.left - bounds.left - OVERLAY_EDGE_GAP) / travel.width),
    y: travel.height === 0 ? 0 : clamp01((position.top - bounds.top - OVERLAY_EDGE_GAP) / travel.height)
  };
}

/**
 * Move a placement by a pixel step, for keyboard placement.
 *
 * The step is expressed in pixels because that is what a person pressing an
 * arrow key means; converting through the current travel keeps a keypress
 * moving the same visible distance whatever the viewport is.
 */
export function nudgePlacement(
  placement: NormalizedPlacement,
  step: { x: number; y: number },
  surface: Box,
  bounds: Box
): NormalizedPlacement {
  const travel = availableTravel(surface, bounds);
  return {
    x: travel.width === 0 ? 0 : clamp01(placement.x + step.x / travel.width),
    y: travel.height === 0 ? 0 : clamp01(placement.y + step.y / travel.height)
  };
}

export function clampPlacement(placement: NormalizedPlacement): NormalizedPlacement {
  return { x: clamp01(placement.x), y: clamp01(placement.y) };
}

/**
 * The preset a placement currently sits on, or null when it is between them.
 *
 * Used to mark the active preset control, so a person can see where they are
 * without inferring it from the overlay's position.
 */
export function matchingPreset(
  placement: NormalizedPlacement,
  tolerance = 0.02
): OverlayPresetName | null {
  for (const [name, preset] of Object.entries(OVERLAY_PRESETS) as [OverlayPresetName, NormalizedPlacement][]) {
    if (Math.abs(preset.x - placement.x) <= tolerance && Math.abs(preset.y - placement.y) <= tolerance) {
      return name;
    }
  }
  return null;
}

/**
 * Reads a persisted placement, rejecting anything that is not a usable pair
 * of numbers.
 *
 * Storage is shared with the user, other tabs, and older builds of this app,
 * so the stored value is untrusted input: a malformed or partial record must
 * read as "no preference", never as a placement of NaN.
 */
export function parseStoredPlacement(raw: string | null): NormalizedPlacement | null {
  if (!raw) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) return null;
    const { x, y } = parsed as Partial<NormalizedPlacement>;
    if (typeof x !== "number" || typeof y !== "number") return null;
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
    return clampPlacement({ x, y });
  } catch {
    return null;
  }
}
