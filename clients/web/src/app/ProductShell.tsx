import { Suspense, useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router";
import { AppIcon } from "../components/AppIcon";
import { AvatarBadge } from "../components/AvatarBadge";
import { MemberAreaLinks } from "../components/MemberAreaLinks";
import { canAccessWorkspaceAdmin, canOperate } from "../lib/roles";
import {
  CallSessionProvider,
  useCallSession
} from "../features/calls/CallSessionProvider";
import {
  ExperienceModeProvider,
  useExperienceMode
} from "../features/experience/ExperienceModeProvider";
import { TelephonyProvider } from "../features/telephony/TelephonyProvider";
import { NotificationCenter } from "../features/notifications/NotificationCenter";
import { useSession } from "./session";
import { useWorkspaceData } from "./workspace-data";
import { beginNewInstantRoomVisit } from "../features/instant-room/idempotency";
import { clearMemberInstantRoomContinuity } from "../features/instant-room/memberContinuity";
import { usePwa } from "../pwa/PwaProvider";
import { useAutoHideNavigation } from "./useAutoHideNavigation";
import { WorkspaceSwitcher } from "./WorkspaceSwitcher";
import { RouteRecoveryBoundary } from "./RouteRecoveryBoundary";
import { DesktopShellHeader } from "../components/DesktopShellHeader";
import { DesktopActivityRail } from "../components/DesktopActivityRail";
import { isDesktopClient } from "../desktop/session";
import { useRouterHistory } from "./router-history";
import { useWindowControlsOverlay } from "./useWindowControlsOverlay";
import { ContextualNavigationProvider } from "./ContextualNavigation";
import { WorkspaceToolNavigation } from "./WorkspaceToolNavigation";

const WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY =
  "k-comms.workspace-sidebar-collapsed.v1";

function readWorkspaceSidebarPinned(): boolean {
  try {
    return window.localStorage.getItem(
      WORKSPACE_SIDEBAR_COLLAPSED_STORAGE_KEY
    ) !== "false";
  } catch {
    return true;
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
      <TelephonyProvider>
        <ExperienceModeProvider>
          <ProductShellContent />
        </ExperienceModeProvider>
      </TelephonyProvider>
    </CallSessionProvider>
  );
}

function ProductShellContent() {
  const navigate = useNavigate();
  const location = useLocation();
  const history = useRouterHistory();
  const { session, logout } = useSession();
  const { teardownCall } = useCallSession();
  const { mode } = useExperienceMode();
  const { error, setError, refreshAll, conversations } = useWorkspaceData();
  const { updateAvailable, applyUpdate, dismissUpdate } = usePwa();
  const [retrying, setRetrying] = useState(false);
  const [switcherOpen, setSwitcherOpen] = useState(false);
  useEffect(() => setSwitcherOpen(false), [location.key]);
  useEffect(() => {
    // Browser history can return before a lazy route commits its location key.
    const closeSwitcher = () => setSwitcherOpen(false);
    window.addEventListener("popstate", closeSwitcher);
    return () => window.removeEventListener("popstate", closeSwitcher);
  }, []);
  const [workspaceSidebarPinned, setWorkspaceSidebarPinned] = useState(
    readWorkspaceSidebarPinned
  );
  const [workspaceSidebarFocused, setWorkspaceSidebarFocused] = useState(false);
  const workspaceSidebarPointerRef = useRef(false);
  const desktopShell = useDesktopShell();
  const windowControlsOverlay = useWindowControlsOverlay();
  const desktopAccountRef = useRef<HTMLDetailsElement | null>(null);
  const [sidebarTarget, setSidebarTarget] = useState<HTMLDivElement | null>(null);
  const navigationFocusRequested = useRef(false);
  const navigation = useAutoHideNavigation(
    desktopShell && mode !== "immersive" && Boolean(session), workspaceSidebarPinned, workspaceSidebarFocused || switcherOpen
  );

  useEffect(() => {
    function quickSwitch(event: KeyboardEvent) {
      if (event.defaultPrevented || event.isComposing || event.altKey || event.shiftKey ||
          !(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "k") return;
      // Preserve editor link shortcuts and never open over consent/confirmation dialogs.
      if (event.target instanceof Element && event.target.closest("input, textarea, [contenteditable='true']")) return;
      if (document.querySelector("[aria-modal='true'], dialog[open]")) return;
      event.preventDefault();
      setSwitcherOpen(true);
    }
    document.addEventListener("keydown", quickSwitch);
    return () => document.removeEventListener("keydown", quickSwitch);
  }, []);

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
  useEffect(() => {
    if (!desktopShell || mode === "immersive") return;
    const sidebar = navigation.sidebarRef.current;
    if (!sidebar) return;
    // Portal events follow their React owner. Observe physical sidebar events
    // so its route-owned navigation receives the same focus and idle protection.
    function pointerDown() {
      workspaceSidebarPointerRef.current = true;
      window.setTimeout(() => { workspaceSidebarPointerRef.current = false; }, 0);
    }
    function focusIn() {
      if (!workspaceSidebarPointerRef.current) setWorkspaceSidebarFocused(true);
    }
    function focusOut(event: FocusEvent) {
      if (!(event.relatedTarget instanceof Node) || !sidebar?.contains(event.relatedTarget)) setWorkspaceSidebarFocused(false);
    }
    function activate(event: MouseEvent) {
      if (!workspaceSidebarPinned && event.target instanceof Element && event.target.closest("a, .workspace-instant-room")) setWorkspaceSidebarFocused(false);
    }
    function keyDown(event: KeyboardEvent) {
      if (event.key !== "Escape" || workspaceSidebarPinned || desktopAccountRef.current?.open || document.querySelector(".notification-panel")) return;
      setWorkspaceSidebarFocused(false);
      if (event.target instanceof HTMLElement) event.target.blur();
      navigation.hide();
    }
    sidebar.addEventListener("pointerdown", pointerDown, true);
    sidebar.addEventListener("focusin", focusIn);
    sidebar.addEventListener("focusout", focusOut);
    sidebar.addEventListener("click", activate, true);
    sidebar.addEventListener("keydown", keyDown);
    return () => {
      sidebar.removeEventListener("pointerdown", pointerDown, true);
      sidebar.removeEventListener("focusin", focusIn);
      sidebar.removeEventListener("focusout", focusOut);
      sidebar.removeEventListener("click", activate, true);
      sidebar.removeEventListener("keydown", keyDown);
    };
  }, [desktopShell, mode, navigation.sidebarRef, navigation.hide, workspaceSidebarPinned]);
  if (!session) return null;
  const showAdmin = canAccessWorkspaceAdmin(session.user);
  const showOperations = canOperate(session.user.platform_role, session.user.platform_role_expires_at);
  const administrationMode = (location.pathname === "/admin" && showAdmin)
    || (location.pathname === "/ops" && showOperations);
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
  const nativeDesktop = isDesktopClient();
  const showDesktopChrome = !immersive && (desktopShell || windowControlsOverlay || nativeDesktop);
  const workspaceSidebarExpanded = workspaceSidebarPinned || workspaceSidebarFocused;
  const accountMenu = (
    <details ref={desktopAccountRef} className="workspace-account-menu">
      <summary
        role="button"
        className="workspace-account-trigger"
        aria-label={`Account menu for ${session.user.display_name}`}
        title={session.user.display_name}
      >
        <AvatarBadge name={session.user.display_name} avatarUrl={session.user.avatar_url} size="small" />
        <span className="workspace-account-copy">
          <strong>{session.user.display_name}</strong>
          <small>{session.user.role}</small>
        </span>
        <AppIcon name="chevronDown" className="workspace-account-chevron" />
      </summary>
      <section className="desktop-account-panel" aria-label="Signed-in account">
        <div className="desktop-account-heading">
          <AvatarBadge name={session.user.display_name} avatarUrl={session.user.avatar_url} size="small" />
          <span>
            <strong>{session.user.display_name}</strong>
            <small>{session.tenant.name} · {session.user.role}</small>
          </span>
        </div>
        <nav className="desktop-role-links" aria-label="Personal settings">
          <NavLink to="/app/you?section=profile" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Profile &amp; settings</NavLink>
          <NavLink to="/app/you?section=audio-video" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Audio &amp; video</NavLink>
        </nav>
        {(showAdmin || showOperations) && (
          <nav className="desktop-role-links" aria-label="Role tools">
            {showAdmin && <NavLink to="/admin" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Workspace administration</NavLink>}
            {showOperations && <NavLink to="/ops" onClick={() => { if (desktopAccountRef.current) desktopAccountRef.current.open = false; }}>Service operations</NavLink>}
          </nav>
        )}
        <button className="button ghost compact desktop-signout" type="button" onClick={signOut}>Sign out</button>
      </section>
    </details>
  );
  return (
    <ContextualNavigationProvider
      target={desktopShell && !immersive ? sidebarTarget : null}
      hasSidebarNavigation={desktopShell && !immersive && workspaceSidebarPinned}
    >
    <div className={`app-shell ${workspaceSidebarExpanded ? "workspace-sidebar-expanded" : "workspace-sidebar-collapsed"}${showDesktopChrome ? " desktop-chrome" : ""}${desktopShell && !immersive && workspaceSidebarPinned ? " workspace-navigation-pinned" : ""}${administrationMode ? " administration-shell" : ""}`}>
        <a className="skip-link" href="#main-content">Skip to content</a>
        {(showDesktopChrome || nativeDesktop) && <DesktopShellHeader
          hideChrome={immersive}
          sidebarExpanded={workspaceSidebarPinned}
          onToggleSidebar={() => desktopShell && !immersive ? setWorkspaceSidebarPinned((pinned) => !pinned) : setSwitcherOpen(true)}
          onNewInstantRoom={() => { beginNewInstantRoomVisit(); navigate("/"); }}
          onOpenWorkspace={() => setSwitcherOpen(true)}
          onOpenSearch={() => setSwitcherOpen(true)}
          onOpenSettings={() => navigate("/app/you")}
          workspaceName={session.tenant.name}
          showWorkspaceName={!desktopShell || navigation.hidden || !workspaceSidebarExpanded}
          navigation={history}
        />}
        {desktopShell && !immersive && <DesktopActivityRail user={session.user} accountMenu={accountMenu} />}
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
        ><AppIcon name="menu" /></button>}
        {desktopShell && !immersive && <aside
          ref={navigation.sidebarRef}
          id="workspace-navigation"
          className={`workspace-sidebar ${workspaceSidebarExpanded ? "is-expanded" : "is-collapsed"}${navigation.hidden ? " is-hidden" : ""}`}
          aria-label="Workspace navigation"
          aria-hidden={navigation.hidden || undefined}
          inert={navigation.hidden}

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
                <small>{administrationMode ? "Administration" : "Workspace"}</small>
                <strong>{session.tenant.name}</strong>
              </span>
            </div>
          </div>
          <button className="workspace-switcher-trigger" type="button" aria-label="Switch conversation or screen"
            title="Switch conversation or screen (Ctrl / ⌘ K)" aria-keyshortcuts="Control+k Meta+k"
            onClick={() => setSwitcherOpen(true)}>
            <AppIcon name="search" /><span>Go to…</span><kbd>⌘ / Ctrl K</kbd>
          </button>
          {!administrationMode && <button
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
          </button>}
          {administrationMode ? <nav className="workspace-sidebar-nav administration-destinations" aria-label="Administration navigation">
            <NavLink to="/app/" end title="Return to workspace"><AppIcon name="arrowLeft" /><span>Return to workspace</span></NavLink>
          </nav> : <WorkspaceToolNavigation compact={!workspaceSidebarExpanded} />}
          <div ref={setSidebarTarget} className="workspace-context-navigation" />
          <div className="workspace-sidebar-spacer" />
          <div className="workspace-sidebar-notifications">
            <NotificationCenter conversations={conversations} />
            <span>Notifications</span>
          </div>
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
        <RouteRecoveryBoundary>
          <Suspense fallback={<main id="main-content" className="route-loading" role="status" aria-busy="true">Loading page…</main>}>
            <Outlet />
          </Suspense>
        </RouteRecoveryBoundary>
        {switcherOpen && <WorkspaceSwitcher session={session} conversations={conversations ?? []} onClose={() => setSwitcherOpen(false)} />}
        {!desktopShell && !immersive && (
          <nav className="mobile-primary-nav" aria-label="Primary navigation">
            <MemberAreaLinks variant="mobile-primary" />
          </nav>
        )}
    </div>
    </ContextualNavigationProvider>
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
