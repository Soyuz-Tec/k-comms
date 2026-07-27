import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router";
import { Brand } from "../components/Brand";
import { MemberAreaLinks, MobileBottomNav } from "../components/MobileBottomNav";
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
  const { session, logout } = useSession();
  const { teardownCall } = useCallSession();
  const { error, setError, refreshAll } = useWorkspaceData();
  const [retrying, setRetrying] = useState(false);
  const desktopShell = useDesktopShell();
  const desktopAccountRef = useRef<HTMLDetailsElement | null>(null);
  const mobileAccountRef = useRef<HTMLDetailsElement | null>(null);

  useEffect(() => {
    function closeOutside(event: PointerEvent) {
      if (!(event.target instanceof Node)) return;
      for (const menu of [desktopAccountRef.current, mobileAccountRef.current]) {
        if (menu?.open && !menu.contains(event.target)) menu.open = false;
      }
    }

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      for (const menu of [desktopAccountRef.current, mobileAccountRef.current]) {
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
          <div className="desktop-rail-brand">
            <Brand compact />
          </div>
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
            <span aria-hidden="true">＋</span>
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
          <Brand compact />
          <div className="workspace-name">
            <span className="eyebrow">Workspace</span>
            <strong>{session.tenant.name}</strong>
          </div>
          <nav className="product-nav member-product-nav" aria-label="Member areas">
            <MemberAreaLinks />
          </nav>
          <button
            className="button primary compact instant-room-launch"
            type="button"
            onClick={() => {
              beginNewInstantRoomVisit();
              navigate("/");
            }}
          >
            <span aria-hidden="true">＋</span>
            <span>Start instant room</span>
          </button>
          <NotificationCenter />
          <div className="account-menu">
            <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
            <span className="account-copy">
              <strong>{session.user.display_name}</strong>
              <small>{session.user.role}</small>
            </span>
            <button className="button ghost compact" type="button" onClick={signOut}>Sign out</button>
          </div>
          <details ref={mobileAccountRef} className="mobile-account-menu">
            <summary className="mobile-account-trigger" aria-label="Account menu">
              <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
            </summary>
            <section className="mobile-account-panel" aria-label="Signed-in account">
              <dl className="mobile-account-details">
                <div><dt>User</dt><dd>{session.user.display_name}</dd></div>
                <div><dt>Workspace</dt><dd>{session.tenant.name}</dd></div>
                <div><dt>Role</dt><dd>{session.user.role}</dd></div>
              </dl>
              {(showAdmin || showOperations) && (
                <nav className="mobile-role-links" aria-label="Role tools">
                  {showAdmin && <NavLink to="/admin" onClick={() => { if (mobileAccountRef.current) mobileAccountRef.current.open = false; }}>Workspace administration</NavLink>}
                  {showOperations && <NavLink to="/ops" onClick={() => { if (mobileAccountRef.current) mobileAccountRef.current.open = false; }}>Service operations</NavLink>}
                </nav>
              )}
              <button className="button ghost compact mobile-signout" type="button" onClick={signOut}>Sign out</button>
            </section>
          </details>
        </header>}

        {error && (
          <div className="banner error-banner" role="alert">
            <span><strong>Workspace could not refresh.</strong> {error}</span>
            <button className="button ghost compact" type="button" disabled={retrying} onClick={() => { setRetrying(true); void refreshAll().finally(() => setRetrying(false)); }}>{retrying ? "Retrying…" : "Retry"}</button>
            <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}>×</button>
          </div>
        )}
        <Outlet />
        <MobileBottomNav />
    </div>
  );
}

function useDesktopShell() {
  const [desktop, setDesktop] = useState(() =>
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(min-width: 761px)").matches
  );

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const media = window.matchMedia("(min-width: 761px)");
    const update = () => setDesktop(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return desktop;
}
