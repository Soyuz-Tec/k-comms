import { Link, useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { useContextualNavigation } from "../../app/ContextualNavigation";
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
import { SettingsPage } from "../settings/SettingsPage";

export function YouPage() {
  const { session, logout } = useSession();
  const { hasSidebarNavigation } = useContextualNavigation();
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
            {!hasSidebarNavigation && <nav className="you-role-shortcuts" aria-label="Workspace">
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
            </nav>}
            {showAdmin && <nav className="you-role-shortcuts you-administration-shortcuts" aria-label="Workspace administration">
              <h2>Workspace administration</h2>
              <div className="you-role-card-grid">
                {showPeople && <Link to="/admin?section=people"><AppIcon name="userPlus" /><span>People &amp; invitations</span><AppIcon name="arrowUpRight" /></Link>}
                {showSafety && <Link to="/admin?section=safety"><AppIcon name="flag" /><span>Safety review</span><AppIcon name="arrowUpRight" /></Link>}
                <Link to="/admin"><AppIcon name="settings" /><span>Workspace administration</span><AppIcon name="arrowUpRight" /></Link>
              </div>
            </nav>}
            {showOperations && <nav className="you-role-shortcuts you-operations-shortcuts" aria-label="Service operations">
              <h2>Service operations</h2>
              <div className="you-role-card-grid">
                <Link to="/ops"><AppIcon name="activity" /><span>Service operations</span><AppIcon name="arrowUpRight" /></Link>
              </div>
            </nav>}
            <section className="you-account-actions" aria-label="Signed-in account">
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
