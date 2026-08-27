import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router";
import { AppIcon } from "../components/AppIcon";
import { MemberAreaLinks } from "../components/MemberAreaLinks";
import { initials } from "../lib/format";
import { canAccessAdmin, canOperate } from "../lib/roles";
import {
  CallSessionProvider,
  useCallSession
} from "../features/calls/CallSessionProvider";
import {
  ExperienceModeProvider,
  useExperienceMode
} from "../features/experience/ExperienceModeProvider";
import { NotificationCenter } from "../features/notifications/NotificationCenter";
import { useSession } from "./session";
import { useWorkspaceData } from "./workspace-data";
import { beginNewInstantRoomVisit } from "../features/instant-room/idempotency";
import { clearMemberInstantRoomContinuity } from "../features/instant-room/memberContinuity";
import { usePwa } from "../pwa/PwaProvider";

const WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY =
  "k-comms.workspace-sidebar-collapsed.v1";

function readWorkspaceSidebarCollapsed(): boolean {
  try {
    return window.localStorage.getItem(
      WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY
    ) === "true";
  } catch {
    return false;
  }
}

export function ProductShell() {
  const { session } = useSession();
  if (!session) return null;
  /*
   * ExperienceModeProvider sits inside CallSessionProvider because it observes
   * the live call, and inside WorkspaceDataProvider (mounted above this route)
   * because it reads both capability channels. The call session itself stays
   * above the outlet so navigating between routes never remounts the media
   * tree.
   */
  return (
    <CallSessionProvider>
      <ExperienceModeProvider>
        <ProductShellContent />
      </ExperienceModeProvider>
    </CallSessionProvider>
  );
}

function ProductShellContent() {
  const navigate = useNavigate();
  const { session, logout } = useSession();
  const { teardownCall } = useCallSession();
  const { mode } = useExperienceMode();
  const { error, setError, refreshAll } = useWorkspaceData();
  const { updateAvailable, applyUpdate, dismissUpdate } = usePwa();
  const [retrying, setRetrying] = useState(false);
  const [workspaceSidebarCollapsed, setWorkspaceSidebarCollapsed] = useState(
    readWorkspaceSidebarCollapsed
  );
  const desktopShell = useDesktopShell();
  const desktopAccountRef = useRef<HTMLDetailsElement | null>(null);

  useEffect(() => {
    try {
      window.localStorage.setItem(
        WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY,
        String(workspaceSidebarCollapsed)
      );
    } catch {
      // A constrained storage context must not block workspace navigation.
    }
  }, [workspaceSidebarCollapsed]);

  useEffect(() => {
    function closeOutside(event: PointerEvent) {
      if (!(event.target instanceof Node)) return;
      for (const menu of [desktopAccountRef.current]) {
        if (menu?.open && !menu.contains(event.target)) menu.open = false;
      }
    }

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      for (const menu of [desktopAccountRef.current]) {
        if (!menu?.open) continue;
        menu.open = false;
        menu.querySelector<HTMLElement>("summary")?.focus();
      }
    }

    document.addEventListener("pointerdown", closeOutside);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOutside);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, []);
  if (!session) return null;
  const showAdmin = canAccessAdmin(session.user.role);
  const showOperations = canOperate(session.user.platform_role, session.user.platform_role_expires_at);
  const signOut = () => {
    teardownCall();
    clearMemberInstantRoomContinuity();
    void logout().finally(() => {
      navigate("/sign-in", { replace: true });
    });
  };

  /*
   * Phones render no shell chrome above the content at all. The previous
   * design carried a global top bar that named the surface, but it resolved
   * that name from the pathname alone — and a conversation is addressed by
   * query string, so the bar read "Inbox" while you were reading a room. The
   * bottom bar already says which destination you are in, and a leaf view says
   * its own name in its own header, so the third statement was both redundant
   * and the only one that could be wrong.
   */
  /*
   * The mode is published as an attribute rather than a class so the styling
   * reads as one state with three values, and so a surface can never be in two
   * modes at once by accumulating class names. Every rule that responds to it
   * lives in experience-mode.css.
   */
  const immersive = mode === "immersive";
  return (
    <div
      className={`app-shell ${workspaceSidebarCollapsed ? "workspace-sidebar-collapsed" : ""}`}
      data-experience-mode={mode}
    >
        {desktopShell && !immersive && (
          <div className="window-titlebar-drag-region" aria-hidden="true" />
        )}
        <a className="skip-link" href="#main-content">Skip to content</a>
        {desktopShell && !immersive && <aside className={`workspace-sidebar ${workspaceSidebarCollapsed ? "is-collapsed" : ""}`} aria-label="Workspace navigation">
          {/*
            * One row, not two. The brand row said "K-Comms / Communication
            * workspace" and the identity row underneath said "Workspace /
            * <tenant>" — 92px of chrome to name the product you are already
            * inside, and then to label the tenant with a word the reader can
            * see for themselves. The mark carries the product, the name
            * carries the tenant, and "Workspace" stays as the accessible label
            * for the row rather than as a visible caption.
            */}
          <div className="workspace-sidebar-header">
            <div className="workspace-sidebar-identity" title={session.tenant.name}>
              <span className="workspace-mark" aria-hidden="true">K</span>
              <span className="workspace-identity-copy">
                <small>Workspace</small>
                <strong>{session.tenant.name}</strong>
              </span>
            </div>
            <button
              className="workspace-sidebar-toggle"
              type="button"
              aria-label={workspaceSidebarCollapsed ? "Expand navigation sidebar" : "Collapse navigation sidebar"}
              aria-pressed={workspaceSidebarCollapsed}
              title={workspaceSidebarCollapsed ? "Expand navigation sidebar" : "Collapse navigation sidebar"}
              onClick={() => setWorkspaceSidebarCollapsed((collapsed) => !collapsed)}
            >
              <AppIcon name={workspaceSidebarCollapsed ? "panelLeftOpen" : "panelLeftClose"} />
            </button>
          </div>
          <button
            className="workspace-instant-room"
            type="button"
            aria-label="New instant room"
            title="New instant room"
            onClick={() => {
              beginNewInstantRoomVisit();
              navigate("/");
            }}
          >
            <AppIcon name="plus" />
            <span>New instant room</span>
          </button>
          <nav className="workspace-sidebar-nav" aria-label="Member areas">
            <MemberAreaLinks variant="grouped" />
          </nav>
          <div className="workspace-sidebar-spacer" />
          <div className="workspace-sidebar-notifications">
            <NotificationCenter />
            <span>Notifications</span>
          </div>
          <details ref={desktopAccountRef} className="workspace-account-menu">
            <summary
              className="workspace-account-trigger"
              aria-label={`Account menu for ${session.user.display_name}`}
              title={session.user.display_name}
            >
              <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
              <span className="workspace-account-copy">
                <strong>{session.user.display_name}</strong>
                <small>{session.user.role}</small>
              </span>
              <AppIcon name="chevronDown" className="workspace-account-chevron" />
            </summary>
            <section className="desktop-account-panel" aria-label="Signed-in account">
              <div className="desktop-account-heading">
                <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
                <span>
                  <strong>{session.user.display_name}</strong>
                  <small>{session.tenant.name} · {session.user.role}</small>
                </span>
              </div>
              {(showAdmin || showOperations) && (
                <nav className="desktop-role-links" aria-label="Role tools">
                  {showAdmin && <NavLink to="/admin" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Workspace administration</NavLink>}
                  {showOperations && <NavLink to="/ops" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Service operations</NavLink>}
                </nav>
              )}
              <button className="button ghost compact desktop-signout" type="button" onClick={signOut}>Sign out</button>
            </section>
          </details>
        </aside>}

        {updateAvailable && (
          <section
            className="pwa-update-banner"
            role="status"
            aria-labelledby="pwa-update-title"
          >
            <div>
              <strong id="pwa-update-title">Update ready</strong>
              <p>Finish active calls and save any drafts before reloading K-Comms.</p>
            </div>
            <div className="pwa-update-actions">
              <button
                className="button primary compact"
                type="button"
                onClick={() => void applyUpdate()}
              >
                Reload
              </button>
              <button
                className="button ghost compact"
                type="button"
                onClick={dismissUpdate}
              >
                Later
              </button>
            </div>
          </section>
        )}
        {error && (
          <div className="banner error-banner" role="alert">
            <span><strong>Workspace could not refresh.</strong> {error}</span>
            <button className="button ghost compact" type="button" disabled={retrying} onClick={() => { setRetrying(true); void refreshAll().finally(() => setRetrying(false)); }}>{retrying ? "Retrying…" : "Retry"}</button>
            <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}><AppIcon name="x" /></button>
          </div>
        )}
        <Outlet />
        {!desktopShell && !immersive && (
          <nav className="mobile-primary-nav" aria-label="Primary navigation">
            <MemberAreaLinks variant="mobile-primary" />
          </nav>
        )}
    </div>
  );
}

export function useDesktopShell() {
  const [desktop, setDesktop] = useState(() =>
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(min-width: 761px) and (min-height: 561px)").matches
  );

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const media = window.matchMedia("(min-width: 761px) and (min-height: 561px)");
    const update = () => setDesktop(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return desktop;
}
