import { Link, useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { AppIcon } from "../../components/AppIcon";
import { memberDestinations } from "../../components/MemberAreaLinks";
import {
  canAccessWorkspaceAdmin,
  canManageUsers,
  canModerate,
  canOperate
} from "../../lib/roles";
import { useOptionalCallSession } from "../calls/CallSessionProvider";
import { beginNewInstantRoomVisit } from "../instant-room/idempotency";
import { clearMemberInstantRoomContinuity } from "../instant-room/memberContinuity";
import { CalendarConnectionsPanel } from "../calendar-sync/CalendarConnectionsPanel";
import { SettingsPage } from "../settings/SettingsPage";

export function YouPage() {
  const { session, logout } = useSession();
  const callSession = useOptionalCallSession();
  const navigate = useNavigate();
  if (!session) return null;
  const showAdmin = canAccessWorkspaceAdmin(session.user);
  const showOperations = canOperate(
    session.user.platform_role,
    session.user.platform_role_expires_at
  );
  const showPeople = showAdmin && canManageUsers(session.user.role);
  const showSafety = showAdmin && canModerate(session.user.role);

  const signOut = () => {
    callSession?.teardownCall();
    clearMemberInstantRoomContinuity();
    void logout().finally(() => {
      navigate("/sign-in", { replace: true });
    });
  };

  return (
    <div className="you-page">
      <SettingsPage
        roleTools={(
          <>
            <nav className="you-role-shortcuts" aria-label="Workspace">
              <h2>Workspace shortcuts</h2>
              <div className="you-role-card-grid">
                {memberDestinations.filter(({ mobilePrimary }) => !mobilePrimary).map(({ path, icon, label }) => <Link key={path} to={path}><AppIcon name={icon} /><span>{label}</span><AppIcon name="arrowUpRight" /></Link>)}
                <button
                  className="you-shortcut-button"
                  type="button"
                  onClick={() => {
                    beginNewInstantRoomVisit();
                    navigate("/");
                  }}
                >
                  <AppIcon name="plus" /><span>Start instant room</span><AppIcon name="arrowUpRight" />
                </button>
              </div>
            </nav>
            <CalendarConnectionsPanel />
            {(showAdmin || showOperations) && <nav className="you-role-shortcuts you-administration-shortcuts" aria-label="Administration and operations">
              <h2>Administration and operations</h2>
              <p>Tools available for your workspace and service responsibilities.</p>
              <div className="you-role-card-grid">
                {showPeople && <Link to="/admin?section=people"><AppIcon name="userPlus" /><span>People &amp; invitations</span><AppIcon name="arrowUpRight" /></Link>}
                {showSafety && <Link to="/admin?section=safety"><AppIcon name="flag" /><span>Safety review</span><AppIcon name="arrowUpRight" /></Link>}
                {showAdmin && <Link to="/admin"><AppIcon name="settings" /><span>Workspace administration</span><AppIcon name="arrowUpRight" /></Link>}
                {showOperations && <Link to="/ops"><AppIcon name="activity" /><span>Service operations</span><AppIcon name="arrowUpRight" /></Link>}
              </div>
            </nav>}
            <section className="you-account-actions" aria-label="Signed-in account">
              <dl>
                <div><dt>User</dt><dd>{session.user.display_name}</dd></div>
                <div><dt>Role</dt><dd>{session.user.role}</dd></div>
              </dl>
              <button className="button ghost you-signout" type="button" onClick={signOut}>
                <AppIcon name="logOut" />
                Sign out
              </button>
            </section>
          </>
        )}
      />
    </div>
  );
}
