import { useState } from "react";
import type { ReactNode } from "react";
import { useLocation, useNavigate } from "react-router";
import { DesktopShellHeader } from "../components/DesktopShellHeader";
import { beginNewInstantRoomVisit } from "../features/instant-room/idempotency";
import { getDesktopShellBridge } from "../lib/desktop-shell";
import { useRouterHistory } from "./router-history";
import { useSession } from "./session";
import { useWindowControlsOverlay } from "./useWindowControlsOverlay";

/** The installed client's OS titlebar remains available before authentication. */
export function PublicDesktopShell({ children }: { children: ReactNode }) {
  const [bridge] = useState(getDesktopShellBridge);
  const windowControlsOverlay = useWindowControlsOverlay();
  const { session, transportPolicyReady } = useSession();
  const { pathname } = useLocation();
  const navigate = useNavigate();
  const navigation = useRouterHistory();
  const normalizedPath = pathname.replace(/\/+$/, "") || "/";
  const memberRoute = normalizedPath === "/app" || normalizedPath.startsWith("/app/") ||
    normalizedPath === "/admin" || normalizedPath === "/ops";

  const showHeader = Boolean(bridge || windowControlsOverlay) && !(session && transportPolicyReady && memberRoute);

  function newInstantRoom() {
    beginNewInstantRoomVisit();
    void navigate("/");
  }

  // A display-mode change adjusts chrome, never the draft/auth/media subtree.
  // Retain both this wrapper and the children's sibling position in all modes.
  return <div className={`public-desktop-shell${showHeader ? " native-public-shell" : ""}`}>
    {showHeader ? <DesktopShellHeader
      navigation={navigation}
      workspaceMenuLabel="Open workspace"
      onNewInstantRoom={newInstantRoom}
      onOpenWorkspace={() => { void navigate("/app/"); }}
      onOpenSearch={() => { void navigate("/app/"); }}
    /> : null}
    {children}
  </div>;
}
