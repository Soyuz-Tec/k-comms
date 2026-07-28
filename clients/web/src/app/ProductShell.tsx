import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router";
import { AppIcon } from "../components/AppIcon";
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
  const [retrying, setRetrying] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
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

  return (
    <div className="app-shell">
        <a className="skip-link" href="#main-content">Skip to content</a>
        {desktopShell && <aside className="desktop-workspace-rail" aria-label="Workspace navigation">
          <div
            className="desktop-workspace-identity"
            title={session.tenant.name}
          >
            <span aria-hidden="true">{initials(session.tenant.name).slice(0, 1)}</span>
            <span className="visually-hidden">Current workspace: {session.tenant.name}</span>
          </div>
          <nav className="desktop-rail-nav" aria-label="Member areas">
            <MemberAreaLinks compact />
          </nav>
          <button
            className="desktop-instant-room"
            type="button"
            aria-label="Start instant room"
            title="Start instant room"
            onClick={() => {
              beginNewInstantRoomVisit();
              navigate("/");
            }}
          >
            <AppIcon name="plus" />
          </button>
          <div className="desktop-rail-spacer" />
          <NotificationCenter />
          <details ref={desktopAccountRef} className="desktop-account-menu">
            <summary
              className="desktop-account-trigger"
              aria-label={`Account menu for ${session.user.display_name}`}
              title={session.user.display_name}
            >
              <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
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
          <button
            className="mobile-menu-trigger"
            type="button"
            aria-label="Open main menu"
            aria-expanded={mobileMenuOpen}
            aria-controls="mobile-product-menu"
            onClick={() => setMobileMenuOpen(true)}
          >
            <AppIcon name="menu" />
          </button>
          <div className="mobile-workspace-heading">
            <span>Workspace</span>
            <strong>{session.tenant.name}</strong>
          </div>
          <button
            className="button primary compact instant-room-launch"
            type="button"
            aria-label="Start instant room"
            onClick={() => {
              beginNewInstantRoomVisit();
              navigate("/");
            }}
          >
            <AppIcon name="plus" />
            <span>Start instant room</span>
          </button>
          <NotificationCenter />
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
            onSignOut={() => {
              setMobileMenuOpen(false);
              signOut();
            }}
          />,
          document.body
        )}

        {error && (
          <div className="banner error-banner" role="alert">
            <span><strong>Workspace could not refresh.</strong> {error}</span>
            <button className="button ghost compact" type="button" disabled={retrying} onClick={() => { setRetrying(true); void refreshAll().finally(() => setRetrying(false)); }}>{retrying ? "Retrying…" : "Retry"}</button>
            <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}><AppIcon name="x" /></button>
          </div>
        )}
        <Outlet />
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
  onSignOut
}: {
  showAdmin: boolean;
  showOperations: boolean;
  tenantName: string;
  userName: string;
  userRole: string;
  onClose: () => void;
  onInstantRoom: () => void;
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
            <span className="eyebrow">Workspace menu</span>
            <h2 id="mobile-product-menu-title">{tenantName}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            data-initial-focus
            aria-label="Close main menu"
            onClick={onClose}
          >
            <AppIcon name="x" />
          </button>
        </header>
        <nav
          className="mobile-menu-member-links"
          aria-label="All product areas"
          onClick={(event) => {
            if (event.target instanceof Element && event.target.closest("a")) onClose();
          }}
        >
          <MemberAreaLinks />
        </nav>
        <button className="mobile-menu-action" type="button" onClick={onInstantRoom}>
          Start instant room
        </button>
        {(showAdmin || showOperations) && (
          <nav className="mobile-menu-role-links" aria-label="Role tools">
            {showAdmin && <NavLink to="/admin" onClick={onClose}>Workspace administration</NavLink>}
            {showOperations && <NavLink to="/ops" onClick={onClose}>Service operations</NavLink>}
          </nav>
        )}
        <section className="mobile-menu-account" aria-label="Signed-in account">
          <dl>
            <div><dt>User</dt><dd>{userName}</dd></div>
            <div><dt>Role</dt><dd>{userRole}</dd></div>
          </dl>
          <button className="button ghost mobile-signout" type="button" onClick={onSignOut}>Sign out</button>
        </section>
      </aside>
    </div>
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
