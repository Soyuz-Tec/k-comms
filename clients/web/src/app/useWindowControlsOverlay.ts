import { useEffect, useState } from "react";

const overlayQuery = "(display-mode: window-controls-overlay)";

/** Installed PWA titlebar availability is independent of viewport dimensions. */
export function useWindowControlsOverlay(): boolean {
  const [query] = useState(() => typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia(overlayQuery) : null);
  const [overlay, setOverlay] = useState(() => query?.matches === true);
  useEffect(() => {
    if (!query) return;
    const update = () => setOverlay(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, [query]);
  return overlay;
}
