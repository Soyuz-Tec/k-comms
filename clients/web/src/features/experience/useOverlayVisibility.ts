import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  activeKeepVisibleReasons,
  isIntentionalMove,
  mayCollapse,
  NO_KEEP_VISIBLE_CONDITIONS,
  OVERLAY_IDLE_MS,
  POINTER_JITTER_PX,
  type KeepVisibleConditions
} from "./overlay-visibility";
import {
  setCallControlPreference,
  useCallControlPreferences
} from "./call-control-preferences";

/*
 * alwaysShow now lives with the other two call control preferences rather than
 * here. It is the same kind of thing and the same storage convention, and one
 * owner is one fallback rule instead of three.
 */

interface Options {
  /** Auto-hide only applies where it was designed to; elsewhere, always visible. */
  enabled: boolean;
  /** Conditions the caller knows about: dragging, pending actions, alerts. */
  conditions?: Partial<KeepVisibleConditions>;
  idleMs?: number;
  jitterPx?: number;
}

/**
 * Reveals and collapses routine overlay controls.
 *
 * Reveal is synchronous with the input that caused it -- a state update in the
 * same task as the pointer, key or focus event -- so the 100 ms budget is met
 * by not deferring rather than by racing a timer.
 *
 * Only routine controls are involved. Critical microphone, camera,
 * screen-share, recording and connection state is rendered outside whatever
 * this hook hides, so a collapsed overlay still reports what the call is
 * doing.
 */
export function useOverlayVisibility({
  enabled,
  conditions,
  idleMs = OVERLAY_IDLE_MS,
  jitterPx = POINTER_JITTER_PX
}: Options) {
  const [visible, setVisible] = useState(true);
  const [hovering, setHovering] = useState(false);
  const [focusWithin, setFocusWithin] = useState(false);
  const [pinned, setPinned] = useState(false);
  const { alwaysShow } = useCallControlPreferences();

  const timerRef = useRef<number | undefined>(undefined);
  /**
   * The last pointer position that counted as intent. Held in a ref because it
   * changes with every pointer event and must not cause a render.
   */
  const intentAnchorRef = useRef<{ x: number; y: number } | null>(null);

  const resolved = useMemo<KeepVisibleConditions>(
    () => ({
      ...NO_KEEP_VISIBLE_CONDITIONS,
      ...conditions,
      alwaysShow,
      hovering,
      focusWithin,
      pinned
    }),
    [conditions, alwaysShow, hovering, focusWithin, pinned]
  );

  const clearTimer = useCallback(() => {
    if (timerRef.current !== undefined) {
      window.clearTimeout(timerRef.current);
      timerRef.current = undefined;
    }
  }, []);

  /**
   * Show the controls and restart the idle countdown.
   *
   * Called from the event that caused it, so the reveal lands in the same task
   * as the input rather than a frame or a timer later.
   */
  const reveal = useCallback(() => {
    setVisible(true);
    clearTimer();
    if (!enabled) return;
    if (!mayCollapse(resolved)) return;
    timerRef.current = window.setTimeout(() => setVisible(false), idleMs);
  }, [clearTimer, enabled, resolved, idleMs]);

  /*
   * A keep-visible condition appearing must cancel a countdown already in
   * flight, and one clearing must start a fresh one -- otherwise opening a
   * menu two seconds in still hides the controls a second later.
   */
  useEffect(() => {
    if (!enabled) {
      clearTimer();
      setVisible(true);
      return;
    }
    if (!mayCollapse(resolved)) {
      clearTimer();
      setVisible(true);
      return;
    }
    clearTimer();
    timerRef.current = window.setTimeout(() => setVisible(false), idleMs);
    return clearTimer;
  }, [enabled, resolved, idleMs, clearTimer]);

  useEffect(() => clearTimer, [clearTimer]);

  const onPointerMove = useCallback(
    (event: { clientX: number; clientY: number }) => {
      const point = { x: event.clientX, y: event.clientY };
      // Jitter must not reset the countdown, or a resting hand keeps the
      // controls up forever and they never collapse at all.
      if (!isIntentionalMove(intentAnchorRef.current, point, jitterPx)) return;
      intentAnchorRef.current = point;
      reveal();
    },
    [reveal, jitterPx]
  );

  const toggleAlwaysShow = useCallback(() => {
    setCallControlPreference("alwaysShow", !alwaysShow);
  }, [alwaysShow]);

  return {
    /** False only when routine controls have collapsed. */
    visible: visible || !enabled,
    reveal,
    alwaysShow,
    toggleAlwaysShow,
    pinned,
    setPinned,
    keepVisibleReasons: activeKeepVisibleReasons(resolved),
    /** Spread onto the surface that owns the controls. */
    surfaceProps: {
      onPointerMove,
      onPointerDown: reveal,
      onKeyDown: reveal,
      onFocus: () => {
        setFocusWithin(true);
        reveal();
      },
      onBlur: (event: { currentTarget: HTMLElement; relatedTarget: EventTarget | null }) => {
        // React's onBlur bubbles, so this fires for descendants too; only a
        // move outside the control system counts as focus leaving it.
        if (
          event.relatedTarget instanceof Node &&
          event.currentTarget.contains(event.relatedTarget)
        ) {
          return;
        }
        setFocusWithin(false);
      },
      onPointerEnter: () => {
        setHovering(true);
        reveal();
      },
      onPointerLeave: () => setHovering(false)
    }
  };
}
