import { useSyncExternalStore } from "react";

/**
 * Where the call companion is allowed to sit when something protected is on
 * screen.
 *
 * The contract names the protected zones outright: on a standalone whiteboard
 * with a call running, the drawable plane and Excalidraw's own toolbars,
 * menus, zoom controls, dialogs, collaborator controls and text editor are
 * collision zones. The companion must prefer existing non-canvas page chrome,
 * collapse to the critical-status capsule in the top safe area when that space
 * is insufficient, and not float over the plane at all while pen input or a
 * text editor is active.
 *
 * The signals come from the surface that owns them rather than from sniffing
 * the DOM. A `document.querySelector(".whiteboard-room")` would have worked
 * and would have been wrong for the same reason the experience mode is not
 * read back off the root: the component that knows already knows, and asking
 * the DOM instead invents a second source of truth that can disagree.
 */
export interface ProtectedSurfaceState {
  /** A drawable canvas is on screen, whether or not it is being used. */
  canvasVisible: boolean;
  /**
   * Pen or stylus input, or an open text editor, on that canvas. The companion
   * must be nowhere near the plane while either is true.
   */
  canvasEditing: boolean;
  /** The virtual keyboard has taken part of the viewport. */
  keyboardOpen: boolean;
}

export const NO_PROTECTED_SURFACES: ProtectedSurfaceState = {
  canvasVisible: false,
  canvasEditing: false,
  keyboardOpen: false
};

export interface CompanionDisposition {
  /**
   * "free" leaves the companion wherever the user put it. "top" pins it to the
   * top safe area, which is the one strip the contract names as available:
   * page chrome above the canvas, clear of the composer, the keyboard and the
   * bottom navigation.
   */
  placement: "free" | "top";
  /** Reduce to the critical-status capsule rather than the fuller panel. */
  collapsed: boolean;
  /** Why, in a form a test can assert and a person can read. */
  reason: "none" | "canvas-visible" | "canvas-editing" | "keyboard-open";
}

/**
 * Collision priority, highest first:
 *
 *   blocking permission/consent state, captions, whiteboard editing and native
 *   controls, safety-critical call controls, then routine overlays.
 *
 * Only the middle three are decided here -- consent and captions are rendered
 * by surfaces that never move, and safety-critical call state is what the
 * capsule preserves in every case below. Editing outranks the keyboard because
 * a stylus stroke lands on the canvas immediately, while a keyboard has
 * already taken its space and is not going to take more.
 */
export function companionDisposition(
  surfaces: ProtectedSurfaceState
): CompanionDisposition {
  if (surfaces.canvasEditing) {
    return { placement: "top", collapsed: true, reason: "canvas-editing" };
  }
  if (surfaces.keyboardOpen) {
    return { placement: "top", collapsed: true, reason: "keyboard-open" };
  }
  if (surfaces.canvasVisible) {
    // Off the plane, but still the full companion: nothing is being drawn, so
    // there is no reason to take its controls away as well.
    return { placement: "top", collapsed: false, reason: "canvas-visible" };
  }
  return { placement: "free", collapsed: false, reason: "none" };
}

let state: ProtectedSurfaceState = NO_PROTECTED_SURFACES;
const listeners = new Set<() => void>();

function publish(next: ProtectedSurfaceState) {
  if (
    next.canvasVisible === state.canvasVisible &&
    next.canvasEditing === state.canvasEditing &&
    next.keyboardOpen === state.keyboardOpen
  ) {
    return;
  }
  state = next;
  for (const listener of listeners) listener();
}

export function setProtectedSurface(
  key: keyof ProtectedSurfaceState,
  value: boolean
): void {
  publish({ ...state, [key]: value });
}

export function getProtectedSurfaces(): ProtectedSurfaceState {
  return state;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Read by the call panel, which renders outside every surface that publishes
 * here -- the whiteboard is inside the route outlet, the panel is a sibling of
 * the shell.
 */
export function useProtectedSurfaces(): ProtectedSurfaceState {
  return useSyncExternalStore(subscribe, getProtectedSurfaces, getProtectedSurfaces);
}

export function resetProtectedSurfacesForTest(): void {
  state = NO_PROTECTED_SURFACES;
  listeners.clear();
}

/**
 * How much of the viewport the virtual keyboard has to take before it counts.
 *
 * Browser chrome collapsing on scroll also shrinks the visual viewport, by
 * rather less. A fixed pixel floor would misjudge a short phone, so this is a
 * fraction of the layout viewport.
 */
const KEYBOARD_VIEWPORT_FRACTION = 0.15;

/**
 * Watches the visual viewport and publishes whether the keyboard is up.
 *
 * There is no keyboard event on the web. The visual viewport shrinking well
 * below the layout viewport is the signal every platform actually gives, and
 * visualViewport is already what the placement hook re-measures on.
 *
 * Returns a cleanup, and clears the signal on the way out so a surface that
 * unmounts mid-edit does not leave the companion pinned forever.
 */
export function watchVirtualKeyboard(): () => void {
  const viewport = window.visualViewport;
  if (!viewport) return () => setProtectedSurface("keyboardOpen", false);

  const check = () => {
    const hidden = window.innerHeight - viewport.height;
    setProtectedSurface(
      "keyboardOpen",
      hidden > window.innerHeight * KEYBOARD_VIEWPORT_FRACTION
    );
  };

  check();
  viewport.addEventListener("resize", check);
  return () => {
    viewport.removeEventListener("resize", check);
    setProtectedSurface("keyboardOpen", false);
  };
}
