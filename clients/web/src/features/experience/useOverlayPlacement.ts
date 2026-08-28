import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, KeyboardEvent, PointerEvent } from "react";
import {
  clampPlacement,
  matchingPreset,
  nudgePlacement,
  OVERLAY_PRESETS,
  parseStoredPlacement,
  placementToPosition,
  positionToPlacement,
  type Bounds,
  type NormalizedPlacement,
  type OverlayPresetName
} from "./overlay-placement";

/** Keyboard step in CSS pixels; Shift takes the coarse one. */
const KEYBOARD_STEP = 8;
const KEYBOARD_STEP_COARSE = 32;

/**
 * Below this many pixels a pointer movement is treated as a press rather than
 * a drag, so a slightly unsteady click on the handle does not nudge the
 * overlay and does not overwrite a saved placement.
 */
const DRAG_THRESHOLD = 3;

interface Options {
  /**
   * localStorage key for the persisted placement. Omitting it makes the
   * placement session-only.
   */
  storageKey?: string;
  defaultPreset?: OverlayPresetName;
  /** Called once per completed placement change, never per pointer frame. */
  onPlacementCommitted?: (placement: NormalizedPlacement) => void;
}

function readStored(storageKey: string | undefined): NormalizedPlacement | null {
  if (!storageKey) return null;
  try {
    return parseStoredPlacement(window.localStorage.getItem(storageKey));
  } catch {
    // A constrained storage context must not stop an overlay from rendering.
    return null;
  }
}

function writeStored(storageKey: string | undefined, placement: NormalizedPlacement) {
  if (!storageKey) return;
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(placement));
  } catch {
    // Losing a saved position is a smaller harm than interrupting a call to
    // report it.
  }
}

function viewportBounds(): Bounds {
  return { top: 0, left: 0, width: window.innerWidth, height: window.innerHeight };
}

/**
 * Owns where a movable overlay sits.
 *
 * Two rules from the performance contract shape the whole hook:
 *
 *   "Keep high-frequency pointer coordinates in refs. Commit React state only
 *   on semantic changes." So a drag writes a compositor transform straight to
 *   the element and touches no state until the pointer is released. A render
 *   per pointermove is what makes dragging drop frames, and it is what the
 *   existing DraggableSurface does today.
 *
 *   "Overlay changes cause no LiveKit reconnect, track republish, track
 *   restart, or renegotiation." Nothing here touches the media tree; it moves
 *   a box, and the box happens to contain one.
 */
export function useOverlayPlacement({
  storageKey,
  defaultPreset = "bottom-right",
  onPlacementCommitted
}: Options = {}) {
  const surfaceRef = useRef<HTMLElement | null>(null);
  const [placement, setPlacement] = useState<NormalizedPlacement>(
    () => readStored(storageKey) ?? OVERLAY_PRESETS[defaultPreset]
  );
  const [dragging, setDragging] = useState(false);
  const [geometry, setGeometry] = useState<{ measured: boolean; surface: Bounds | null; bounds: Bounds }>(
    () => ({
      measured: false,
      surface: null,
      bounds:
        typeof window === "undefined"
          ? { top: 0, left: 0, width: 0, height: 0 }
          : viewportBounds()
    })
  );

  const dragRef = useRef<{
    pointerId: number;
    startX: number;
    startY: number;
    moved: boolean;
    base: { top: number; left: number };
    surface: Bounds;
    bounds: Bounds;
  } | null>(null);

  const measure = useCallback(() => {
    const surface = surfaceRef.current;
    const rect = surface?.getBoundingClientRect();
    setGeometry({
      measured: true,
      surface: rect
        ? { top: rect.top, left: rect.left, width: rect.width, height: rect.height }
        : null,
      bounds: viewportBounds()
    });
  }, []);

  /*
   * Re-measuring on viewport change is what satisfies "clamps after
   * viewport/safe-area change, and never restores off-screen": the placement
   * itself never changes, but the pixels it maps to do. visualViewport also
   * fires for the mobile keyboard and for pinch-zoom, which resize alone
   * misses.
   */
  useEffect(() => {
    measure();
    window.addEventListener("resize", measure);
    window.addEventListener("orientationchange", measure);
    window.visualViewport?.addEventListener("resize", measure);
    return () => {
      window.removeEventListener("resize", measure);
      window.removeEventListener("orientationchange", measure);
      window.visualViewport?.removeEventListener("resize", measure);
    };
  }, [measure]);

  /*
   * The overlay's own size matters as much as the viewport's, because
   * placement is a fraction of the travel *between* them.
   *
   * Without this, a panel that expands and then collapses is positioned from
   * its expanded size: at 1000x600 a bottom-right companion measured while it
   * filled the viewport has zero travel on both axes, so it resolves to the
   * top-left corner instead. A ResizeObserver catches that, and every other
   * size change -- a reconnecting banner appearing, a longer room title --
   * without the panel having to tell us it changed.
   */
  useEffect(() => {
    const surface = surfaceRef.current;
    if (!surface || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(surface);
    return () => observer.disconnect();
  }, [measure]);

  const commit = useCallback(
    (next: NormalizedPlacement) => {
      const clamped = clampPlacement(next);
      setPlacement(clamped);
      writeStored(storageKey, clamped);
      onPlacementCommitted?.(clamped);
    },
    [storageKey, onPlacementCommitted]
  );

  const surfaceBox = useMemo(
    () => ({
      width: geometry.surface?.width ?? 0,
      height: geometry.surface?.height ?? 0
    }),
    [geometry.surface?.width, geometry.surface?.height]
  );

  /**
   * The committed position. Explicit top/left rather than a transform, so the
   * resting position is exact and the transform stays free for the drag.
   *
   * Nothing is returned before the first measurement: positioning against a
   * zero-sized surface would place the overlay wrongly for one frame.
   */
  const style = useMemo<CSSProperties>(() => {
    if (!geometry.measured || !geometry.surface) return {};
    const { top, left } = placementToPosition(placement, surfaceBox, geometry.bounds);
    return { top: `${top}px`, left: `${left}px`, right: "auto", bottom: "auto" };
  }, [placement, surfaceBox, geometry.bounds, geometry.measured, geometry.surface]);

  const onPointerDown = useCallback((event: PointerEvent<HTMLElement>) => {
    if (event.button !== 0) return;
    const surface = surfaceRef.current;
    if (!surface) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    const rect = surface.getBoundingClientRect();
    dragRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
      base: { top: rect.top, left: rect.left },
      surface: { top: rect.top, left: rect.left, width: rect.width, height: rect.height },
      bounds: viewportBounds()
    };
    setDragging(true);
  }, []);

  const onPointerMove = useCallback((event: PointerEvent<HTMLElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    const dx = event.clientX - drag.startX;
    const dy = event.clientY - drag.startY;
    if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
    drag.moved = true;

    /*
     * The whole point of the hook: no setState here, and no layout read. The
     * geometry captured at pointerdown is reused for every frame, and the
     * clamp is applied to the transform so the overlay cannot be dragged out
     * of reach.
     */
    const target = placementToPosition(
      positionToPlacement(
        { top: drag.base.top + dy, left: drag.base.left + dx },
        drag.surface,
        drag.bounds
      ),
      drag.surface,
      drag.bounds
    );
    const surface = surfaceRef.current;
    if (surface) {
      surface.style.transform =
        `translate3d(${target.left - drag.base.left}px, ${target.top - drag.base.top}px, 0)`;
    }
  }, []);

  const finishDrag = useCallback(
    (event: PointerEvent<HTMLElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      if (event.currentTarget.hasPointerCapture(event.pointerId)) {
        event.currentTarget.releasePointerCapture(event.pointerId);
      }
      dragRef.current = null;
      setDragging(false);

      const surface = surfaceRef.current;
      if (surface) surface.style.transform = "";
      // A press that never crossed the threshold leaves the saved placement
      // exactly as it was.
      if (!drag.moved) return;

      commit(
        positionToPlacement(
          {
            top: drag.base.top + (event.clientY - drag.startY),
            left: drag.base.left + (event.clientX - drag.startX)
          },
          drag.surface,
          drag.bounds
        )
      );
    },
    [commit]
  );

  const onKeyDown = useCallback(
    (event: KeyboardEvent<HTMLElement>) => {
      const direction = {
        ArrowDown: { x: 0, y: 1 },
        ArrowLeft: { x: -1, y: 0 },
        ArrowRight: { x: 1, y: 0 },
        ArrowUp: { x: 0, y: -1 }
      }[event.key];
      if (!direction) return;
      event.preventDefault();
      const step = event.shiftKey ? KEYBOARD_STEP_COARSE : KEYBOARD_STEP;
      commit(
        nudgePlacement(
          placement,
          { x: direction.x * step, y: direction.y * step },
          surfaceBox,
          geometry.bounds
        )
      );
    },
    [commit, placement, surfaceBox, geometry.bounds]
  );

  const applyPreset = useCallback(
    (name: OverlayPresetName) => {
      commit(OVERLAY_PRESETS[name]);
    },
    [commit]
  );

  return {
    surfaceRef,
    placement,
    dragging,
    style,
    applyPreset,
    activePreset: matchingPreset(placement),
    /** Spread onto the drag handle. Placement is never pointer-only. */
    handleProps: {
      onKeyDown,
      onPointerCancel: finishDrag,
      onPointerDown,
      onPointerMove,
      onPointerUp: finishDrag
    }
  };
}
