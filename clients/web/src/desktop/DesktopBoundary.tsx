import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { desktopStorageFailed, isDesktopClient, subscribeDesktopStorageFailure } from "./session";

export function DesktopBoundary({ children }: { children: ReactNode }) {
  const [blocked, setBlocked] = useState(desktopStorageFailed);
  useEffect(() => subscribeDesktopStorageFailure(() => setBlocked(true)), []);
  if (blocked) return <DesktopUnavailable />;
  return <>{isDesktopClient() && <aside role="status" style={{ padding: "0.5rem 1rem", background: "#fff4cf", color: "#3f3300" }}>
    Unsigned desktop evaluation · Automatic updates are off. Platform camera, microphone and screen capture qualification is pending. Use the authorized web client for corporate sign in.
  </aside>}{children}</>;
}
export function DesktopUnavailable() {
  return <main style={{ margin: "2rem auto", maxWidth: "36rem", padding: "1rem" }}><h1>Secure desktop setup required</h1><p role="alert">Encrypted operating-system credential storage and an available authorized HTTPS service are required. Saved access must be confirmed before this client opens. No plaintext or browser-storage fallback is available.</p><p>Close this evaluation client, check OS secure storage and service availability, and reopen it. Use your authorized web client while desktop setup is unavailable.</p></main>;
}
