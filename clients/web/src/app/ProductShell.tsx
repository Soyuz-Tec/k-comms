import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router";
import { AppIcon } from "../components/AppIcon";
import {
  AppMenuCloseButton,
  AppMenuTrigger,
  AppSurfaceControlButton
} from "../components/AppMenuControls";
import { MemberAreaLinks } from "../components/MemberAreaLinks";
import { useModalDialog } from "../components/useModalDialog";
import { initials } from "../lib/format";
import { canAccessAdmin, canOperate } from "../lib/roles";
import {
  CallSessionProvider,
  useCallSession
} from "../features/calls/CallSessionProvider";
import { NotificationCenter } from "../features/notifications/NotificationCenter";
import { useSession } from "./session";
import { useWorkspaceData } from "./workspace-data";
import { beginNewInstantRoomVisit } from "../features/instant-room/idempotency";
import { clearMemberInstantRoomContinuity } from "../features/instant-room/memberContinuity";
import { usePwa, type PwaInstallMode } from "../pwa/PwaProvider";

type ManualInstallMode = Extract<PwaInstallMode, "manual-ios" | "manual-browser">;

export function ProductShell() {
  const { session } = useSession();
  if (!session) return null;
  return (
    <CallSessionProvider>
      <ProductShellContent />
    </CallSessionProvider>
  );
}

function ProductShellContent() {
  const navigate = useNavigate();
  const location = useLocation();
  const { session, logout } = useSession();
  const { teardownCall } = useCallSession();
  const { error, setError, refreshAll } = useWorkspaceData();
  const {
    installMode,
    updateAvailable,
    requestInstall,
    applyUpdate,
    dismissUpdate
  } = usePwa();
  const [retrying, setRetrying] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [installHelpMode, setInstallHelpMode] = useState<ManualInstallMode | null>(null);
  const desktopShell = useDesktopShell();
  const desktopAccountRef = useRef<HTMLDetailsElement | null>(null);

  useEffect(() => {
    setMobileMenuOpen(false);
  }, [desktopShell, location.pathname, location.search]);

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
  const installKComms = async () => {
    if (installMode === "manual-ios" || installMode === "manual-browser") {
      setInstallHelpMode(installMode);
      return;
    }
    if (installMode !== "native-prompt") return;
    const result = await requestInstall();
    if (result === "manual-ios" || result === "manual-browser") {
      setInstallHelpMode(result);
    }
  };
  const showInstallAction = installMode !== "installed" && installMode !== "unavailable";

  return (
    <div className="app-shell">
        <a className="skip-link" href="#main-content">Skip to content</a>
        {desktopShell && <aside className="workspace-sidebar" aria-label="Workspace navigation">
          <div className="workspace-sidebar-brand">
            <span className="workspace-mark" aria-hidden="true">K</span>
            <span className="workspace-brand-copy">
              <strong>K-Comms</strong>
              <small>Communication workspace</small>
            </span>
          </div>
          <div className="workspace-sidebar-identity" title={session.tenant.name}>
            <span className="workspace-avatar" aria-hidden="true">{initials(session.tenant.name).slice(0, 1)}</span>
            <span className="workspace-identity-copy">
              <small>Workspace</small>
              <strong>{session.tenant.name}</strong>
            </span>
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
        {!desktopShell && <header className="topbar">
          <div className="mobile-workspace-brand">
            <span className="workspace-mark" aria-hidden="true">K</span>
            <span className="mobile-workspace-heading">
              <strong>K-Comms</strong>
              <small>{session.tenant.name}</small>
            </span>
          </div>
          <div className="topbar-control-cluster">
            <NotificationCenter />
            <AppMenuTrigger
              className="mobile-menu-trigger"
              accessibleLabel="Open more menu"
              expanded={mobileMenuOpen}
              controls="mobile-product-menu"
              onClick={() => setMobileMenuOpen(true)}
            />
          </div>
        </header>}
        {!desktopShell && mobileMenuOpen && createPortal(
          <MobileProductMenu
            showAdmin={showAdmin}
            showOperations={showOperations}
            tenantName={session.tenant.name}
            userName={session.user.display_name}
            userRole={session.user.role}
            onClose={() => setMobileMenuOpen(false)}
            onInstantRoom={() => {
              setMobileMenuOpen(false);
              beginNewInstantRoomVisit();
              navigate("/");
            }}
            showInstall={showInstallAction}
            onInstall={() => void installKComms()}
            onSignOut={() => {
              setMobileMenuOpen(false);
              signOut();
            }}
          />,
          document.body
        )}

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
        {!desktopShell && (
          <nav className="mobile-primary-nav" aria-label="Primary navigation">
            <MemberAreaLinks variant="mobile-primary" />
          </nav>
        )}
        {installHelpMode && (
          <PwaInstallHelpDialog
            mode={installHelpMode}
            onClose={() => setInstallHelpMode(null)}
          />
        )}
    </div>
  );
}

function MobileProductMenu({
  showAdmin,
  showOperations,
  tenantName,
  userName,
  userRole,
  onClose,
  onInstantRoom,
  showInstall,
  onInstall,
  onSignOut
}: {
  showAdmin: boolean;
  showOperations: boolean;
  tenantName: string;
  userName: string;
  userRole: string;
  onClose: () => void;
  onInstantRoom: () => void;
  showInstall: boolean;
  onInstall: () => void;
  onSignOut: () => void;
}) {
  const dialogRef = useModalDialog(onClose);

  return (
    <div
      className="mobile-menu-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <aside
        ref={dialogRef}
        className="mobile-product-menu"
        id="mobile-product-menu"
        role="dialog"
        aria-modal="true"
        aria-labelledby="mobile-product-menu-title"
      >
        <header>
          <div>
            <span className="eyebrow">{tenantName}</span>
            <h2 id="mobile-product-menu-title">More</h2>
          </div>
          <AppMenuCloseButton
            data-initial-focus
            accessibleLabel="Close more menu"
            onClick={onClose}
          />
        </header>
        <span className="mobile-menu-section-label">Collaboration</span>
        <nav
          className="mobile-menu-member-links"
          aria-label="More product areas"
          onClick={(event) => {
            if (event.target instanceof Element && event.target.closest("a")) onClose();
          }}
        >
          <MemberAreaLinks variant="mobile-more" />
        </nav>
        <button className="mobile-menu-action" type="button" onClick={onInstantRoom}>
          <AppIcon name="plus" />
          Start instant room
        </button>
        {showInstall && (
          <button className="mobile-menu-action" type="button" onClick={onInstall}>
            <AppIcon name="download" />
            Install K-Comms
          </button>
        )}
        {(showAdmin || showOperations) && (
          <nav className="mobile-menu-role-links" aria-label="Role tools">
            {showAdmin && <NavLink to="/admin" onClick={onClose}>
              <AppIcon name="settings" />
              Workspace administration
            </NavLink>}
            {showOperations && <NavLink to="/ops" onClick={onClose}>
              <AppIcon name="activity" />
              Service operations
            </NavLink>}
          </nav>
        )}
        <section className="mobile-menu-account" aria-label="Signed-in account">
          <dl>
            <div><dt>User</dt><dd>{userName}</dd></div>
            <div><dt>Role</dt><dd>{userRole}</dd></div>
          </dl>
          <button className="button ghost mobile-signout" type="button" onClick={onSignOut}>
            <AppIcon name="logOut" />
            Sign out
          </button>
        </section>
      </aside>
    </div>
  );
}

export function PwaInstallHelpDialog({
  mode,
  onClose
}: {
  mode: ManualInstallMode;
  onClose: () => void;
}) {
  const dialogRef = useModalDialog(onClose);

  return createPortal(
    <div
      className="modal-backdrop pwa-install-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <section
        ref={dialogRef}
        className="modal-dialog pwa-install-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="pwa-install-help-title"
        aria-describedby="pwa-install-help-copy"
      >
        <div className="pwa-install-dialog-heading">
          <div>
            <span className="eyebrow">No App Store needed</span>
            <h2 id="pwa-install-help-title">Install K-Comms</h2>
          </div>
          <AppSurfaceControlButton
            data-initial-focus
            accessibleLabel="Close install instructions"
            kind="close"
            onClick={onClose}
          />
        </div>
        {mode === "manual-ios" ? (
          <p id="pwa-install-help-copy">
            On iPhone or iPad, tap <strong>Share → Add to Home Screen</strong>.
            Keep <strong>Open as Web App</strong> enabled, then tap Add.
          </p>
        ) : (
          <p id="pwa-install-help-copy">
            Open your browser menu, then choose <strong>Install app</strong> or{" "}
            <strong>Add to Home screen</strong>.
          </p>
        )}
        <button className="button primary pwa-install-done" type="button" onClick={onClose}>
          Done
        </button>
      </section>
    </div>,
    document.body
  );
}

function useDesktopShell() {
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
