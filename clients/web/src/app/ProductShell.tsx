import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet } from "react-router-dom";
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
  const { session, logout } = useSession();
  const { teardownCall } = useCallSession();
  const { error, setError, refreshAll } = useWorkspaceData();
  const [retrying, setRetrying] = useState(false);
  const mobileAccountRef = useRef<HTMLDetailsElement | null>(null);

  useEffect(() => {
    function closeOutside(event: PointerEvent) {
      const menu = mobileAccountRef.current;
      if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) menu.open = false;
    }

    function closeOnEscape(event: KeyboardEvent) {
      const menu = mobileAccountRef.current;
      if (event.key !== "Escape" || !menu?.open) return;
      menu.open = false;
      menu.querySelector<HTMLElement>("summary")?.focus();
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
    void logout();
  };

  return (
    <div className="app-shell">
        <a className="skip-link" href="#main-content">Skip to content</a>
        <header className="topbar">
          <Brand compact />
          <div className="workspace-name">
            <span className="eyebrow">Workspace</span>
            <strong>{session.tenant.name}</strong>
          </div>
          <nav className="product-nav member-product-nav" aria-label="Member areas">
            <MemberAreaLinks />
          </nav>
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
        </header>

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
