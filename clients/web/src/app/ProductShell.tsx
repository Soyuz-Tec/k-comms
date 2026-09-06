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
import { useAutoHideNavigation } from "./useAutoHideNavigation";

const WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY =
  "k-comms.workspace-sidebar-collapsed.v1";

function readWorkspaceSidebarPinned(): boolean {
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
  const [workspaceSidebarPinned, setWorkspaceSidebarPinned] = useState(
    readWorkspaceSidebarPinned
  );
  const [workspaceSidebarFocused, setWorkspaceSidebarFocused] = useState(false);
  const workspaceSidebarPointerRef = useRef(false);
  const desktopShell = useDesktopShell();
  const desktopAccountRef = useRef<HTMLDetailsElement | null>(null);
  const navigationFocusRequested = useRef(false);
  const navigation = useAutoHideNavigation(
    desktopShell && mode !== "immersive" && Boolean(session), workspaceSidebarPinned, workspaceSidebarFocused
  );

  useEffect(() => {
    if (navigation.hidden || !navigationFocusRequested.current) return;
    navigationFocusRequested.current = false;
    navigation.sidebarRef.current?.querySelector<HTMLButtonElement>("button")?.focus();
  }, [navigation.hidden, navigation.sidebarRef]);

  useEffect(() => {
    try {
      window.localStorage.setItem(
        WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY,
        String(workspaceSidebarPinned)
      );
    } catch {
      // A constrained storage context must not block workspace navigation.
    }
  }, [workspaceSidebarPinned]);

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
   * The mode drives the shell in two ways, and only two: this component
   * unmounts the chrome that Immersive must not reserve space for, and
   * experience-mode.css responds to the data-experience-mode attribute that
   * ExperienceModeProvider publishes on the document root. The attribute is
   * not repeated here -- one owner, so the two can never disagree.
   */
  const immersive = mode === "immersive";
  const workspaceSidebarExpanded = workspaceSidebarPinned || workspaceSidebarFocused;
  const workspaceSidebarToggleLabel = workspaceSidebarPinned
    ? "Use compact navigation"
    : "Keep navigation open";
  return (
    <div className={`app-shell ${workspaceSidebarExpanded ? "workspace-sidebar-expanded" : "workspace-sidebar-collapsed"}`}>
        {desktopShell && !immersive && (
          <div className="window-titlebar-drag-region" aria-hidden="true" />
        )}
        <a className="skip-link" href="#main-content">Skip to content</a>
        {desktopShell && !immersive && <button
          className="workspace-navigation-reveal"
          type="button"
          hidden={!navigation.hidden}
          aria-label="Show workspace navigation"
          aria-controls="workspace-navigation"
          aria-expanded={!navigation.hidden}
          title="Show navigation"
          onClick={() => {
            navigationFocusRequested.current = true;
            navigation.reveal();
          }}
        ><span aria-hidden="true" /></button>}
        {desktopShell && !immersive && <aside
          ref={navigation.sidebarRef}
          id="workspace-navigation"
          className={`workspace-sidebar ${workspaceSidebarExpanded ? "is-expanded" : "is-collapsed"}${navigation.hidden ? " is-hidden" : ""}`}
          aria-label="Workspace navigation"
          aria-hidden={navigation.hidden || undefined}
          inert={navigation.hidden}
          onClickCapture={(event) => {
            if (workspaceSidebarPinned) return;
            const target = event.target as HTMLElement;
            if (target.closest("a, .workspace-instant-room")) {
              setWorkspaceSidebarFocused(false);
            }
          }}
          onPointerDownCapture={() => {
            workspaceSidebarPointerRef.current = true;
            // Pointer focus happens in this event turn; a release outside the
            // dock must not suppress subsequent keyboard focus indefinitely.
            window.setTimeout(() => {
              workspaceSidebarPointerRef.current = false;
            }, 0);
          }}
          onFocusCapture={() => {
            if (!workspaceSidebarPointerRef.current) setWorkspaceSidebarFocused(true);
          }}
          onBlurCapture={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
              setWorkspaceSidebarFocused(false);
            }
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape" && !workspaceSidebarPinned &&
                !desktopAccountRef.current?.open && !document.querySelector(".notification-panel")) {
              setWorkspaceSidebarFocused(false);
              (event.target as HTMLElement).blur();
              navigation.hide();
            }
          }}
        >
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
              aria-label={workspaceSidebarToggleLabel}
              aria-expanded={workspaceSidebarExpanded}
              aria-pressed={workspaceSidebarPinned}
              title={workspaceSidebarToggleLabel}
              onClick={(event) => {
                const nextPinned = !workspaceSidebarPinned;
                setWorkspaceSidebarPinned(nextPinned);
                if (!nextPinned) {
                  setWorkspaceSidebarFocused(false);
                  event.currentTarget.blur();
                }
              }}
            >
              <AppIcon name={workspaceSidebarPinned ? "panelLeftClose" : "panelLeftOpen"} />
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
            <MemberAreaLinks variant="grouped" compact={!workspaceSidebarExpanded} />
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
