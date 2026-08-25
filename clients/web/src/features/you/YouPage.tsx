import { Link, useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { AppIcon } from "../../components/AppIcon";
import {
  canAccessAdmin,
  canManageUsers,
  canModerate,
  canOperate
} from "../../lib/roles";
import { useOptionalCallSession } from "../calls/CallSessionProvider";
import { beginNewInstantRoomVisit } from "../instant-room/idempotency";
import { clearMemberInstantRoomContinuity } from "../instant-room/memberContinuity";
import { SettingsPage } from "../settings/SettingsPage";

/*
 * This screen absorbed the phone overflow drawer. That drawer was a full-height
 * modal holding five items — one of them under a "Collaboration" label that
 * headed a list of one — and it cost a control in the top bar of every screen
 * to reach. Administration and operations already lived here; the drawer was
 * duplicating them. Whiteboard, the instant room and signing out are the three
 * that had nowhere else to go, and they belong on the screen that already
 * exists to hold everything about you, your workspace and your role.
 */
export function YouPage() {
  const { session, logout } = useSession();
  const callSession = useOptionalCallSession();
  const navigate = useNavigate();
  if (!session) return null;
  const showAdmin = canAccessAdmin(session.user.role);
  const showOperations = canOperate(
    session.user.platform_role,
    session.user.platform_role_expires_at
  );
  const showPeople = canManageUsers(session.user.role);
  const showSafety = canModerate(session.user.role);

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
              <span>Workspace</span>
              <div className="you-role-card-grid">
                <Link to="/app/whiteboard">Whiteboard</Link>
                <button
                  className="you-shortcut-button"
                  type="button"
                  onClick={() => {
                    beginNewInstantRoomVisit();
                    navigate("/");
                  }}
                >
                  Start instant room
                </button>
                {showPeople && <Link to="/admin?section=people">People &amp; invitations</Link>}
                {showSafety && <Link to="/admin?section=safety">Safety review</Link>}
                {showAdmin && <Link to="/admin">Workspace administration</Link>}
                {showOperations && <Link to="/ops">Service operations</Link>}
              </div>
            </nav>
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
