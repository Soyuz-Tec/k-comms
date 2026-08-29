/**
 * When routine overlay controls are allowed to collapse.
 *
 * The decision is kept pure and separate from the timers that drive it,
 * because the interesting part is not "has three seconds passed" -- it is the
 * list of reasons three seconds is not enough. Those reasons are named rather
 * than collapsed into one boolean so a test can assert *which* one held the
 * controls open, and so the surface can publish it for debugging.
 *
 * What collapses is only ever the routine controls. Microphone, camera,
 * screen-sharing, recording/consent and connection state stay perceivable in
 * compact form whatever this module decides -- the contract is explicit, and a
 * call that hides whether the microphone is live is worse than one that never
 * tidies its controls away.
 */

export interface KeepVisibleConditions {
  /** The accessibility preference. Nothing overrides a person asking for this. */
  alwaysShow: boolean;
  /** A drag in progress: the thing being moved must stay visible. */
  dragging: boolean;
  /** The pointer is over the control system. */
  hovering: boolean;
  /**
   * Keyboard focus is inside the control system. Hiding controls out from
   * under a keyboard user loses their place entirely -- there is no
   * equivalent of "move the mouse to bring it back".
   */
  focusWithin: boolean;
  /** An open menu or dialog belonging to the overlay. */
  menuOpen: boolean;
  /** An action the user started that has not resolved -- do not hide the outcome. */
  pendingAction: boolean;
  /** The user explicitly pinned the controls open. */
  pinned: boolean;
  /** A blocking alert, permission prompt or consent state. */
  blockingAlert: boolean;
}

export type KeepVisibleReason = keyof KeepVisibleConditions;

export const NO_KEEP_VISIBLE_CONDITIONS: KeepVisibleConditions = {
  alwaysShow: false,
  dragging: false,
  hovering: false,
  focusWithin: false,
  menuOpen: false,
  pendingAction: false,
  pinned: false,
  blockingAlert: false
};

/** How long the controls stay up after the last intentional input. */
export const OVERLAY_IDLE_MS = 3_000;

/**
 * Pointer movement below this many CSS pixels is not treated as intent.
 *
 * "Ignore pointer jitter; do not reset the timer for every pixel of movement."
 * A resting hand, a trackpad, and a high-polling-rate mouse all emit small
 * movements continuously; without a floor the idle timer is reset forever and
 * the controls never collapse at all.
 */
export const POINTER_JITTER_PX = 4;

/** The reasons currently holding the controls open, in a stable order. */
export function activeKeepVisibleReasons(
  conditions: KeepVisibleConditions
): KeepVisibleReason[] {
  return (Object.keys(NO_KEEP_VISIBLE_CONDITIONS) as KeepVisibleReason[]).filter(
    (reason) => conditions[reason]
  );
}

/** Whether routine controls may collapse right now. */
export function mayCollapse(conditions: KeepVisibleConditions): boolean {
  return activeKeepVisibleReasons(conditions).length === 0;
}

/**
 * Whether a pointer movement is intent rather than jitter.
 *
 * Measured from the last position that counted as intent, not from the
 * previous event: a slow drift of one pixel per event would otherwise never
 * cross the threshold on any single step while still crossing the room.
 */
export function isIntentionalMove(
  from: { x: number; y: number } | null,
  to: { x: number; y: number },
  jitterPx: number = POINTER_JITTER_PX
): boolean {
  if (!from) return true;
  return Math.hypot(to.x - from.x, to.y - from.y) >= jitterPx;
}
