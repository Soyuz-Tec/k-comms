import { Link } from "react-router";
import { useSession } from "../../app/session";
import {
  canAccessAdmin,
  canManageUsers,
  canModerate,
  canOperate
} from "../../lib/roles";
import { SettingsPage } from "../settings/SettingsPage";

export function YouPage() {
  const { session } = useSession();
  if (!session) return null;
  const showAdmin = canAccessAdmin(session.user.role);
  const showOperations = canOperate(
    session.user.platform_role,
    session.user.platform_role_expires_at
  );
  const showPeople = canManageUsers(session.user.role);
  const showSafety = canModerate(session.user.role);

  return (
    <div className="you-page">
      <SettingsPage
        roleTools={(showAdmin || showOperations) ? (
          <nav className="you-role-shortcuts" aria-label="Role tools">
            <span>Workspace tools</span>
            <div className="you-role-card-grid">
              {showPeople && <Link to="/admin?section=people">People & invitations</Link>}
              {showSafety && <Link to="/admin?section=safety">Safety review</Link>}
              {showAdmin && <Link to="/admin">Workspace administration</Link>}
              {showOperations && <Link to="/ops">Service operations</Link>}
            </div>
          </nav>
        ) : undefined}
      />
    </div>
  );
}
