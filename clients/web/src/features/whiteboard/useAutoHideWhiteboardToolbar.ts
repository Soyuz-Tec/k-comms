import { useCallback, useEffect, useRef, useState } from "react";

const IDLE_MS = 8_000;
const EDGE_DWELL_MS = 250;
const TOOLS = ".shapes-section, .App-top-bar";

/** Hide idle tools while preserving deliberate pointer, touch and keyboard access. */
export function useAutoHideWhiteboardToolbar() {
  const surfaceRef = useRef<HTMLDivElement | null>(null);
  const [hidden, setHidden] = useState(false);
  const renewRef = useRef<() => void>(() => undefined);
  const reveal = useCallback(() => {
    setHidden(false);
    renewRef.current();
  }, []);

  useEffect(() => {
    for (const tools of surfaceRef.current?.querySelectorAll<HTMLElement>(TOOLS) ?? []) {
      tools.setAttribute("aria-hidden", String(hidden));
      tools.inert = hidden;
    }
  }, [hidden]);

  useEffect(() => {
    const surface = surfaceRef.current;
    if (!surface) return;
    let idleTimer: number | undefined;
    let edgeTimer: number | undefined;
    let overTools = false;
    let dragging = false;
    const inTools = (target: EventTarget | null) =>
      target instanceof Element && surface.contains(target) && Boolean(target.closest(TOOLS));
    const blocked = () => dragging || overTools || inTools(document.activeElement) || Boolean(
      document.querySelector("[aria-modal='true'], dialog[open], .canvas-controls-panel") ||
      surface.querySelector(".dropdown-menu, textarea:focus, input[type='text']:focus, [contenteditable='true']:focus")
    );
    const renew = () => {
      window.clearTimeout(idleTimer);
      idleTimer = window.setTimeout(() => {
        if (blocked()) renew();
        else setHidden(true);
      }, IDLE_MS);
    };
    renewRef.current = renew;
    const cancelEdge = () => {
      window.clearTimeout(edgeTimer);
      edgeTimer = undefined;
    };
    const onMove = (event: PointerEvent) => {
      const wasOverTools = overTools;
      overTools = inTools(event.target);
      if (overTools || wasOverTools) renew();
      const bounds = surface.getBoundingClientRect();
      const atEdge = event.clientX >= bounds.left && event.clientX <= bounds.right &&
        event.clientY >= bounds.top && event.clientY <= bounds.top + 10;
      if (!atEdge || event.pointerType === "touch" || event.buttons !== 0 || blocked()) {
        cancelEdge();
        return;
      }
      if (edgeTimer !== undefined) return;
      edgeTimer = window.setTimeout(() => {
        edgeTimer = undefined;
        if (!blocked()) reveal();
      }, EDGE_DWELL_MS);
    };
    const onDown = (event: PointerEvent) => {
      cancelEdge();
      dragging = event.target instanceof Node && surface.contains(event.target);
      if (inTools(event.target)) reveal();
    };
    const onUp = () => {
      dragging = false;
      renew();
    };
    const onFocus = (event: FocusEvent) => {
      if (inTools(event.target)) reveal();
      else renew();
    };
    renew();
    document.addEventListener("pointermove", onMove, { passive: true });
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("pointerup", onUp);
    document.addEventListener("pointercancel", onUp);
    document.addEventListener("focusin", onFocus);
    document.addEventListener("focusout", onFocus);
    return () => {
      window.clearTimeout(idleTimer);
      cancelEdge();
      renewRef.current = () => undefined;
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("pointerup", onUp);
      document.removeEventListener("pointercancel", onUp);
      document.removeEventListener("focusin", onFocus);
      document.removeEventListener("focusout", onFocus);
    };
  }, [reveal]);

  return { surfaceRef, hidden, reveal };
}
