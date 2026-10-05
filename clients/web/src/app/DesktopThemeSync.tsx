import { useEffect, useState } from "react";
import { getDesktopShellBridge, syncDesktopShellTheme } from "../lib/desktop-shell";
import type { DesktopShellTheme } from "../lib/desktop-shell";

/** Mirror the existing CSS theme authority; retain the host's system updates. */
export function DesktopThemeSync() {
  const [bridge] = useState(getDesktopShellBridge);
  useEffect(() => {
    if (!bridge) return;
    const root = document.documentElement;
    const previousNativeMarker = root.getAttribute("data-native-desktop");
    root.setAttribute("data-native-desktop", "true");
    let previous: DesktopShellTheme | undefined;
    const sync = () => {
      const requested = root.getAttribute("data-theme");
      const theme = requested === "light" || requested === "dark" ? requested : "system";
      if (theme === previous) return;
      previous = theme;
      // An unavailable cosmetic bridge must not affect authentication, media,
      // or the theme that the application's CSS has already selected.
      void syncDesktopShellTheme(theme).catch(() => undefined);
    };
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      observer.disconnect();
      if (root.getAttribute("data-native-desktop") !== "true") return;
      if (previousNativeMarker === null) root.removeAttribute("data-native-desktop");
      else root.setAttribute("data-native-desktop", previousNativeMarker);
    };
  }, [bridge]);
  return null;
}
