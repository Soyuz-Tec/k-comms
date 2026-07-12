import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { AccountSession, Invitation, User } from "../../types";
import type { UserRole } from "../../types";
import { errorText, formatDateTime, initials, stringValue } from "../../lib/format";
import { canChangeUser, canManageSessions, canManageUsers, roleLabel, rolesAssignableBy } from "../../lib/roles";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";

export function PeoplePanel({
  api,
  actorRole,
  users,
  setUsers
}: {
  api: ApiClient;
  actorRole: UserRole;
  users: User[];
  setUsers: React.Dispatch<React.SetStateAction<User[]>>;
}) {
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [sessionsByUser, setSessionsByUser] = useState<Record<string, AccountSession[]>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [oneTimeToken, setOneTimeToken] = useState<string | null>(null);
  const { runWithStepUp } = useStepUp();
  const manageUsers = canManageUsers(actorRole);
  const manageSessions = canManageSessions(actorRole);
  const assignableRoles = rolesAssignableBy(actorRole) as Exclude<UserRole, "owner">[];

  useEffect(() => {
    let current = true;
    if (manageUsers) api.invitations().then((values) => current && setInvitations(values)).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api, manageUsers]);

  useEffect(() => {
    if (!oneTimeToken) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [oneTimeToken]);

  async function changeUser(user: User, changes: { role?: UserRole; status?: string }) {
    if (!user.version) return setError("The server did not provide a user version; reload before editing.");
    const description = changes.role ? `change ${user.display_name}'s role to ${roleLabel(changes.role)}` : `change ${user.display_name}'s status to ${changes.status}`;
    const reason = window.prompt(`Enter a reason to ${description}. This action is audited.`);
    if (!reason?.trim()) return;
    setBusy(`user-${user.id}`);
    setError(null);
    try {
      const updated = await runWithStepUp(() => api.updateAdminUser(user.id, { ...changes, reason: reason.trim(), version: user.version! }));
      setUsers((current) => current.map((value) => value.id === updated.id ? updated : value));
      setNotice(`${updated.display_name} updated.`);
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function createInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    if (oneTimeToken) return setError("Acknowledge the current one-time invitation token before creating another.");
    setBusy("invite");
    setError(null);
    try {
      const result = await runWithStepUp(() => api.createInvitation({ email: stringValue(values, "email"), role: stringValue(values, "role") as Exclude<UserRole, "owner"> }));
      setInvitations((current) => [result.invitation, ...current]);
      setOneTimeToken(result.invitationToken || null);
      setNotice("Invitation created. Copy the one-time token now.");
      form.reset();
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function revokeInvitation(invitation: Invitation) {
    const reason = window.prompt(`Enter a reason to revoke the invitation for ${invitation.email}.`);
    if (!reason?.trim()) return;
    setBusy(`invite-${invitation.id}`);
    try {
      const updated = await runWithStepUp(() => api.revokeInvitation(invitation.id, invitation.version, reason.trim()));
      setInvitations((current) => current.map((value) => value.id === updated.id ? updated : value));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function toggleSessions(user: User) {
    if (sessionsByUser[user.id]) return setSessionsByUser((current) => { const next = { ...current }; delete next[user.id]; return next; });
    setBusy(`sessions-${user.id}`);
    try {
      const values = await runWithStepUp(() => api.adminUserSessions(user.id));
      setSessionsByUser((current) => ({ ...current, [user.id]: values }));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function revokeSession(userId: string, sessionId: string) {
    const reason = window.prompt("Enter a reason to revoke this session. The user will need to sign in again.");
    if (!reason?.trim()) return;
    setBusy(`admin-session-${sessionId}`);
    try {
      await runWithStepUp(() => api.adminRevokeSession(userId, sessionId, reason.trim()));
      setSessionsByUser((current) => ({ ...current, [userId]: (current[userId] || []).map((record) => record.id === sessionId ? { ...record, revoked_at: new Date().toISOString() } : record) }));
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}{notice && <div className="inline-notice" role="status">{notice}<button type="button" onClick={() => setNotice(null)}>×</button></div>}
    <section className="data-card" aria-labelledby="people-title">
      <div className="card-heading"><div><span className="eyebrow">Directory and access</span><h2 id="people-title">People, roles and sessions</h2></div><span className="status-pill success">Live API</span></div>
      <div className="responsive-table"><table><thead><tr><th>Person</th><th>Role</th><th>Status</th>{manageSessions && <th>Sessions</th>}</tr></thead><tbody>{users.map((user) => <UserRows key={user.id} actorRole={actorRole} user={user} busy={busy} sessions={sessionsByUser[user.id]} manageSessions={manageSessions} onRole={(role) => void changeUser(user, { role })} onStatus={(status) => void changeUser(user, { status })} onSessions={() => void toggleSessions(user)} onRevokeSession={(sessionId) => void revokeSession(user.id, sessionId)} />)}</tbody></table></div>
    </section>

    {manageUsers && <section className="data-card" aria-labelledby="invite-title">
      <div className="card-heading"><div><span className="eyebrow">Controlled onboarding</span><h2 id="invite-title">Invitations</h2></div><span className="status-pill success">Live API</span></div>
      <form className="inline-admin-form" onSubmit={(event) => void createInvitation(event)}><label className="field">Email<input name="email" type="email" required /></label><label className="field">Role<select name="role" defaultValue="member">{assignableRoles.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}</select></label><button className="button primary" type="submit" disabled={busy === "invite" || Boolean(oneTimeToken)}>Create invitation</button></form>
      {oneTimeToken && <div className="secret-reveal" role="status"><strong>One-time invitation token</strong><code>{oneTimeToken}</code><button className="button ghost compact" type="button" onClick={() => void navigator.clipboard.writeText(oneTimeToken)}>Copy token</button><button className="text-button" type="button" onClick={() => setOneTimeToken(null)}>I stored it</button></div>}
      <ul className="security-list">{invitations.map((invitation) => <li key={invitation.id}><div><strong>{invitation.email}</strong><small>{invitation.role} · Expires {formatDateTime(invitation.expires_at)}</small></div><span className={`status-pill ${invitation.status === "pending" ? "success" : "neutral"}`}>{invitation.status}</span>{invitation.status === "pending" && <button className="button danger compact" type="button" disabled={busy === `invite-${invitation.id}`} onClick={() => void revokeInvitation(invitation)}>Revoke</button>}</li>)}</ul>
    </section>}
  </>;
}

function UserRows({ actorRole, user, busy, sessions, manageSessions, onRole, onStatus, onSessions, onRevokeSession }: { actorRole: UserRole; user: User; busy: string | null; sessions?: AccountSession[]; manageSessions: boolean; onRole: (role: UserRole) => void; onStatus: (status: string) => void; onSessions: () => void; onRevokeSession: (sessionId: string) => void }) {
  const serviceAccount = user.account_type === "service";
  const mutable = !serviceAccount && canChangeUser(actorRole, user.role);
  const roles = rolesAssignableBy(actorRole, true);
  const columns = manageSessions ? 4 : 3;
  return <><tr><td><span className="person-cell"><span className="avatar" aria-hidden="true">{initials(user.display_name)}</span><span><strong>{user.display_name} {serviceAccount && <span className="role-chip">Bot</span>}</strong><small>{serviceAccount ? "Non-login service identity" : user.email}</small></span></span></td><td>{mutable ? <select aria-label={`Role for ${user.display_name}`} value={user.role} disabled={busy === `user-${user.id}`} onChange={(event) => onRole(event.target.value as UserRole)}>{roles.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}</select> : <span className="role-chip">{roleLabel(user.role)}</span>}</td><td>{mutable ? <select aria-label={`Status for ${user.display_name}`} value={user.status} disabled={busy === `user-${user.id}`} onChange={(event) => onStatus(event.target.value)}><option value="active">Active</option><option value="suspended">Suspended</option><option value="deleted">Deleted</option></select> : <span className="status-pill neutral">{user.status}</span>}</td>{manageSessions && <td>{serviceAccount ? <span className="role-chip">Service credential</span> : <button className="button ghost compact" type="button" disabled={busy === `sessions-${user.id}`} onClick={onSessions}>{sessions ? "Hide" : "Manage"}</button>}</td>}</tr>{sessions && !serviceAccount && <tr className="expanded-row"><td colSpan={columns}><ul className="security-list compact-security-list">{sessions.length === 0 ? <li><div><strong>No sessions</strong></div></li> : sessions.map((record) => <li key={record.id}><div><strong>Session {record.id.slice(0, 8)}</strong><small>Last used {formatDateTime(record.last_used_at)}</small></div><span className={`status-pill ${record.revoked_at ? "neutral" : "success"}`}>{record.revoked_at ? "Revoked" : "Active"}</span>{!record.revoked_at && <button className="button danger compact" type="button" disabled={busy === `admin-session-${record.id}`} onClick={() => onRevokeSession(record.id)}>Revoke</button>}</li>)}</ul></td></tr>}</>;
}
