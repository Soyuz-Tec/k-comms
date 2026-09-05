import { useCallback, useEffect, useRef, useState } from "react";

const IDLE_MS = 8_000;
const EDGE_DWELL_MS = 250;
const EDGE_WIDTH = 6;

/** Menu activity, not work in the canvas, extends the dock's visible lifetime. */
export function useAutoHideNavigation(enabled: boolean, pinned: boolean, keyboardFocused: boolean) {
  const sidebarRef = useRef<HTMLElement>(null);
  const [hidden, setHidden] = useState(false);
  const renewIdleRef = useRef(() => {});
  const hide = useCallback(() => {
    const active = document.activeElement;
    if (active instanceof HTMLElement && sidebarRef.current?.contains(active)) active.blur();
    setHidden(true);
  }, []);
  const reveal = useCallback(() => {
    setHidden(false);
    renewIdleRef.current();
  }, []);

  useEffect(() => {
    if (!enabled) return;
    let idleTimer: number | undefined;
    let edgeTimer: number | undefined;
    let pointerDown = false;
    let lastPoint: string | undefined;
    const hasOpenMenu = () => Boolean(sidebarRef.current?.querySelector(
      "details[open], .notification-trigger[aria-expanded='true']"
    ));
    const hasModal = () => Boolean(document.querySelector("[role='dialog'][aria-modal='true'], dialog[open]"));
    function renewIdle() {
      window.clearTimeout(idleTimer);
      if (pinned || keyboardFocused) return;
      idleTimer = window.setTimeout(() => {
        if (hasOpenMenu() || pointerDown) renewIdle();
        else hide();
      }, IDLE_MS);
    }
    function cancelEdgeReveal() {
      window.clearTimeout(edgeTimer);
      edgeTimer = undefined;
    }
    function isMenuTarget(target: EventTarget | null) {
      return target instanceof Element && (
        sidebarRef.current?.contains(target) ||
        target.closest(".workspace-navigation-reveal") ||
        (hasOpenMenu() && target.closest(".notification-panel"))
      );
    }
    function move(event: PointerEvent) {
      const point = `${event.clientX},${event.clientY}`;
      if (lastPoint === point) return;
      lastPoint = point;
      if (isMenuTarget(event.target)) renewIdle();
      // Ignore touch, dragging and unrelated modal surfaces at the edge.
      if (event.pointerType === "touch" || event.buttons !== 0 || event.clientX > EDGE_WIDTH ||
          hasModal()) {
        cancelEdgeReveal();
      } else if (edgeTimer === undefined) {
        edgeTimer = window.setTimeout(() => {
          edgeTimer = undefined;
          if (!hasModal()) reveal();
        }, EDGE_DWELL_MS);
      }
    }
    function press(event: PointerEvent) {
      cancelEdgeReveal();
      pointerDown = Boolean(isMenuTarget(event.target));
      if (pointerDown) renewIdle();
      else if (!pinned && !hasOpenMenu()) hide();
    }
    function release() {
      if (pointerDown) renewIdle();
      pointerDown = false;
    }
    renewIdleRef.current = renewIdle;
    renewIdle();
    document.addEventListener("pointermove", move, { passive: true });
    document.addEventListener("pointerdown", press);
    document.addEventListener("pointerup", release);
    document.addEventListener("pointercancel", release);
    document.documentElement.addEventListener("pointerleave", cancelEdgeReveal);
    return () => {
      window.clearTimeout(idleTimer);
      cancelEdgeReveal();
      renewIdleRef.current = () => {};
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerdown", press);
      document.removeEventListener("pointerup", release);
      document.removeEventListener("pointercancel", release);
      document.documentElement.removeEventListener("pointerleave", cancelEdgeReveal);
    };
  }, [enabled, pinned, keyboardFocused, hide, reveal]);

  return { sidebarRef, hidden: enabled && !pinned && !keyboardFocused && hidden, hide, reveal };
}
