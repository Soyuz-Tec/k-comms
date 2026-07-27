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
      <nav className="you-section-chooser" aria-label="Profile and settings sections">
        <span>Jump to</span>
        <a href="#profile-settings">Profile</a>
        <a href="#password-settings">Security</a>
        <a href="#notification-settings">Notifications</a>
      </nav>
      {(showAdmin || showOperations) && (
        <nav className="you-role-shortcuts" aria-label="Role tools">
          <span>Role tools</span>
          <div className="you-role-card-grid">
            {showPeople && (
              <Link to="/admin?section=people">
                <strong>People & invitations</strong>
                <small>Add teammates or update workspace access.</small>
              </Link>
            )}
            {showSafety && (
              <Link to="/admin?section=safety">
                <strong>Safety review</strong>
                <small>Open moderation and attachment safety queues.</small>
              </Link>
            )}
            {showAdmin && (
              <Link to="/admin">
                <strong>Workspace administration</strong>
                <small>Manage the rest of your tenant-scoped controls.</small>
              </Link>
            )}
            {showOperations && (
              <Link to="/ops">
                <strong>Service operations</strong>
                <small>Open content-blind platform health and triage.</small>
              </Link>
            )}
          </div>
        </nav>
      )}
      <SettingsPage />
    </div>
  );
}
