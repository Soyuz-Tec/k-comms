import { NavLink, Outlet } from "react-router-dom";
import { Brand } from "../components/Brand";
import { initials } from "../lib/format";
import { canAccessAdmin, canOperate } from "../lib/roles";
import { NotificationCenter } from "../features/notifications/NotificationCenter";
import { useSession } from "./session";
import { useWorkspaceData } from "./workspace-data";

export function ProductShell() {
  const { session, logout } = useSession();
  const { error, setError } = useWorkspaceData();
  if (!session) return null;
  const showAdmin = canAccessAdmin(session.user.role);
  const showOperations = canOperate(session.user.platform_role);

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">Skip to content</a>
      <header className="topbar">
        <Brand compact />
        <div className="workspace-name">
          <span className="eyebrow">Workspace</span>
          <strong>{session.tenant.name}</strong>
        </div>
        <nav className="product-nav" aria-label="Product areas">
          <NavLink to="/app" end>Messages</NavLink>
          <NavLink to="/app/settings">Settings</NavLink>
          {showAdmin && <NavLink to="/admin">Admin</NavLink>}
          {showOperations && <NavLink to="/ops">Operations</NavLink>}
        </nav>
        <NotificationCenter />
        <div className="account-menu">
          <span className="avatar" aria-hidden="true">{initials(session.user.display_name)}</span>
          <span className="account-copy">
            <strong>{session.user.display_name}</strong>
            <small>{session.user.role}</small>
          </span>
          <button className="button ghost compact" type="button" onClick={() => void logout()}>Sign out</button>
        </div>
      </header>

      {error && (
        <div className="banner error-banner" role="alert">
          <span>{error}</span>
          <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}>×</button>
        </div>
      )}
      <Outlet />
      <nav className="mobile-product-nav" aria-label="Mobile product areas">
        <NavLink to="/app" end><span aria-hidden="true">◇</span>Messages</NavLink>
        <NavLink to="/app/settings"><span aria-hidden="true">⚙</span>Settings</NavLink>
        {showAdmin && <NavLink to="/admin"><span aria-hidden="true">⌘</span>Admin</NavLink>}
        {showOperations && <NavLink to="/ops"><span aria-hidden="true">◉</span>Ops</NavLink>}
      </nav>
    </div>
  );
}
