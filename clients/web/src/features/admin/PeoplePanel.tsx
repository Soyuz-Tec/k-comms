import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { AccountSession, Invitation, User } from "../../types";
import type { UserRole } from "../../types";
import { errorText, formatDateTime, initials, stringValue } from "../../lib/format";
import { canChangeUser, canManageSessions, canManageUsers, roleLabel, rolesAssignableBy } from "../../lib/roles";
import { useSession } from "../../app/session";
import { stepUpWasCancelled, useStepUp } from "../../app/step-up";
import { ActionDialog } from "../../components/ActionDialog";

type PendingPeopleAction =
  | {
      kind: "user-change";
      user: User;
      changes: { role?: UserRole; status?: string };
      description: string;
    }
  | { kind: "invitation-revocation"; invitation: Invitation }
  | { kind: "session-revocation"; user: User; sessionId: string };

interface OneTimeInvitation {
  url: string;
}

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
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [oneTimeInvitation, setOneTimeInvitation] = useState<OneTimeInvitation | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingPeopleAction | null>(null);
  const [peopleQuery, setPeopleQuery] = useState("");
  const [invitationQuery, setInvitationQuery] = useState("");
  const { session } = useSession();
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
    if (!oneTimeInvitation) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [oneTimeInvitation]);

  function stageUserChange(user: User, changes: { role?: UserRole; status?: string }) {
    if (changes.role === user.role || changes.status === user.status) {
      setPendingAction(null);
      return;
    }
    const description = changes.role
      ? `Change ${user.display_name}'s role from ${roleLabel(user.role)} to ${roleLabel(changes.role)}`
      : `Change ${user.display_name}'s status from ${user.status} to ${changes.status}`;
    setPendingAction({ kind: "user-change", user, changes, description });
    setActionError(null);
    setError(null);
  }

  function stageInvitationRevocation(invitation: Invitation) {
    setPendingAction({ kind: "invitation-revocation", invitation });
    setActionError(null);
    setError(null);
  }

  function stageSessionRevocation(user: User, sessionId: string) {
    setPendingAction({ kind: "session-revocation", user, sessionId });
    setActionError(null);
    setError(null);
  }

  async function confirmPendingAction(reason: string) {
    if (!pendingAction) return;
    const action = pendingAction;
    const busyKey = peopleActionBusyKey(action);
    if (action.kind === "user-change" && !action.user.version) {
      setActionError("The server did not provide a user version; reload before editing.");
      return;
    }
    setBusy(busyKey);
    setActionError(null);
    try {
      if (action.kind === "user-change") {
        const updated = await runWithStepUp(() => api.updateAdminUser(action.user.id, { ...action.changes, reason, version: action.user.version! }));
        setUsers((current) => current.map((value) => value.id === updated.id ? updated : value));
        setNotice(`${updated.display_name} updated.`);
      } else if (action.kind === "invitation-revocation") {
        const invitation = action.invitation;
        const updated = await runWithStepUp(() => api.revokeInvitation(invitation.id, invitation.version, reason));
        setInvitations((current) => current.map((value) => value.id === updated.id ? updated : value));
        setNotice(`Invitation for ${updated.email} revoked.`);
      } else {
        await runWithStepUp(() => api.adminRevokeSession(action.user.id, action.sessionId, reason));
        setSessionsByUser((current) => ({ ...current, [action.user.id]: (current[action.user.id] || []).map((record) => record.id === action.sessionId ? { ...record, revoked_at: new Date().toISOString() } : record) }));
        setNotice(`Session for ${action.user.display_name} revoked.`);
      }
      setPendingAction(null);
    } catch (failure: unknown) {
      if (!stepUpWasCancelled(failure)) setActionError(errorText(failure));
    } finally {
      setBusy(null);
    }
  }

  async function createInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    if (oneTimeInvitation) return setError("Acknowledge the current one-time invitation link before creating another.");
    setBusy("invite");
    setError(null);
    try {
      const result = await runWithStepUp(() => api.createInvitation({ email: stringValue(values, "email"), role: stringValue(values, "role") as Exclude<UserRole, "owner"> }));
      setInvitations((current) => [result.invitation, ...current]);
      setOneTimeInvitation(result.invitationToken ? {
        url: invitationUrl(result.invitationToken, session?.tenant.slug)
      } : null);
      setNotice(result.invitationToken ? "Invitation created. Copy and share the one-time link now." : "Invitation created. The server did not return a shareable one-time link.");
      form.reset();
    } catch (reason: unknown) {
      if (!stepUpWasCancelled(reason)) setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function copyInvitationUrl() {
    if (!oneTimeInvitation) return;
    try {
      await navigator.clipboard.writeText(oneTimeInvitation.url);
      setNotice("Invitation link copied. Share it only with the intended recipient.");
    } catch {
      setError("The invitation link could not be copied automatically. Select and copy it manually.");
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

  const normalizedPeopleQuery = peopleQuery.trim().toLocaleLowerCase();
  const visibleUsers = users.filter((user) => !normalizedPeopleQuery || [user.display_name, user.email, user.role, user.status]
    .some((value) => value?.toLocaleLowerCase().includes(normalizedPeopleQuery)));
  const normalizedInvitationQuery = invitationQuery.trim().toLocaleLowerCase();
  const visibleInvitations = invitations.filter((invitation) => !normalizedInvitationQuery || [invitation.email, invitation.role, invitation.status]
    .some((value) => value.toLocaleLowerCase().includes(normalizedInvitationQuery)));
  const pendingUserChange = pendingAction?.kind === "user-change" ? pendingAction : null;

  return <>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" onClick={() => setError(null)}>×</button></div>}{notice && <div className="inline-notice" role="status">{notice}<button type="button" onClick={() => setNotice(null)}>×</button></div>}
    {pendingAction && <ActionDialog
      key={peopleActionBusyKey(pendingAction)}
      title={pendingAction.kind === "user-change" ? "Apply this access change?" : pendingAction.kind === "invitation-revocation" ? "Revoke this invitation?" : "Revoke this session?"}
      description={pendingAction.kind === "user-change" ? `${pendingAction.description}.` : pendingAction.kind === "invitation-revocation" ? `Revoke the pending invitation for ${pendingAction.invitation.email}.` : `Revoke session ${pendingAction.sessionId.slice(0, 8)} for ${pendingAction.user.display_name}.`}
      impact={pendingAction.kind === "user-change" ? pendingAction.changes.status === "deleted" ? "The user will lose normal workspace access. The reason and actor are written to the audit log." : "The user's workspace permissions will change. The reason and actor are written to the audit log." : pendingAction.kind === "invitation-revocation" ? "The one-time invitation can no longer be accepted. The reason and actor are written to the audit log." : "The session stops working and the user must sign in again. The reason and actor are written to the audit log."}
      confirmLabel={pendingAction.kind === "user-change" ? "Confirm change" : pendingAction.kind === "invitation-revocation" ? "Revoke invitation" : "Revoke session"}
      tone={pendingAction.kind === "user-change" && pendingAction.changes.status !== "deleted" ? "default" : "danger"}
      auditReason={{ label: "Audit reason", helpText: "Required for the audit log.", minimumLength: 3 }}
      busy={busy === peopleActionBusyKey(pendingAction)}
      error={actionError}
      onCancel={() => { setPendingAction(null); setActionError(null); }}
      onConfirm={(reason) => void confirmPendingAction(reason)}
    />}
    <section className="data-card" aria-labelledby="people-title">
      <div className="card-heading"><div><span className="eyebrow">Directory and access</span><h2 id="people-title">People, roles and sessions</h2></div><span className="status-pill success">Live API</span></div>
      <label className="field">Search people<input type="search" value={peopleQuery} onChange={(event) => setPeopleQuery(event.target.value)} placeholder="Name, email, role or status" /></label>
      <div className="responsive-table"><table><thead><tr><th>Person</th><th>Role</th><th>Status</th>{manageSessions && <th>Sessions</th>}</tr></thead><tbody>{visibleUsers.length === 0 ? <tr><td colSpan={manageSessions ? 4 : 3}>No people match this search.</td></tr> : visibleUsers.map((user) => <UserRows key={user.id} actorRole={actorRole} user={user} busy={busy} pendingChange={pendingUserChange?.user.id === user.id ? pendingUserChange.changes : undefined} sessions={sessionsByUser[user.id]} manageSessions={manageSessions} onRole={(role) => stageUserChange(user, { role })} onStatus={(status) => stageUserChange(user, { status })} onSessions={() => void toggleSessions(user)} onRevokeSession={(sessionId) => stageSessionRevocation(user, sessionId)} />)}</tbody></table></div>
    </section>

    {manageUsers && <section className="data-card" aria-labelledby="invite-title">
      <div className="card-heading"><div><span className="eyebrow">Controlled onboarding</span><h2 id="invite-title">Invitations</h2></div><span className="status-pill success">Live API</span></div>
      <form className="inline-admin-form" onSubmit={(event) => void createInvitation(event)}><label className="field">Email<input name="email" type="email" required /></label><label className="field">Role<select name="role" defaultValue="member">{assignableRoles.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}</select></label><button className="button primary" type="submit" disabled={busy === "invite" || Boolean(oneTimeInvitation)}>Create invitation</button></form>
      {oneTimeInvitation && <div className="secret-reveal" role="region" aria-label="One-time invitation link"><strong>One-time invitation link</strong><p>This link contains a one-time secret. Share it only with the intended recipient; it cannot be shown again.</p><code>{oneTimeInvitation.url}</code><button className="button ghost compact" type="button" onClick={() => void copyInvitationUrl()}>Copy invitation link</button><button className="text-button" type="button" onClick={() => setOneTimeInvitation(null)}>I have shared it</button></div>}
      <label className="field">Search invitations<input type="search" value={invitationQuery} onChange={(event) => setInvitationQuery(event.target.value)} placeholder="Email, role or status" /></label>
      <ul className="security-list">{visibleInvitations.length === 0 ? <li><div><strong>No invitations match this search.</strong></div></li> : visibleInvitations.map((invitation) => <li key={invitation.id}><div><strong>{invitation.email}</strong><small>{invitation.role} · Expires {formatDateTime(invitation.expires_at)}</small></div><span className={`status-pill ${invitation.status === "pending" ? "success" : "neutral"}`}>{invitation.status}</span>{invitation.status === "pending" && <button className="button danger compact" type="button" disabled={busy === `invite-${invitation.id}`} onClick={() => stageInvitationRevocation(invitation)}>Revoke</button>}</li>)}</ul>
    </section>}
  </>;
}

function UserRows({ actorRole, user, busy, pendingChange, sessions, manageSessions, onRole, onStatus, onSessions, onRevokeSession }: { actorRole: UserRole; user: User; busy: string | null; pendingChange?: { role?: UserRole; status?: string }; sessions?: AccountSession[]; manageSessions: boolean; onRole: (role: UserRole) => void; onStatus: (status: string) => void; onSessions: () => void; onRevokeSession: (sessionId: string) => void }) {
  const serviceAccount = user.account_type === "service";
  const mutable = !serviceAccount && canChangeUser(actorRole, user.role);
  const roles = rolesAssignableBy(actorRole, true);
  const columns = manageSessions ? 4 : 3;
  return <><tr><td><span className="person-cell"><span className="avatar" aria-hidden="true">{initials(user.display_name)}</span><span><strong>{user.display_name} {serviceAccount && <span className="role-chip">Bot</span>}</strong><small>{serviceAccount ? "Non-login service identity" : user.email}</small></span></span></td><td>{mutable ? <select aria-label={`Role for ${user.display_name}`} value={pendingChange?.role || user.role} disabled={busy === `user-${user.id}`} onChange={(event) => onRole(event.target.value as UserRole)}>{roles.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}</select> : <span className="role-chip">{roleLabel(user.role)}</span>}</td><td>{mutable ? <select aria-label={`Status for ${user.display_name}`} value={pendingChange?.status || user.status} disabled={busy === `user-${user.id}`} onChange={(event) => onStatus(event.target.value)}><option value="active">Active</option><option value="suspended">Suspended</option><option value="deleted">Deleted</option></select> : <span className="status-pill neutral">{user.status}</span>}</td>{manageSessions && <td>{serviceAccount ? <span className="role-chip">Service credential</span> : <button className="button ghost compact" type="button" disabled={busy === `sessions-${user.id}`} onClick={onSessions}>{sessions ? "Hide" : "Manage"}</button>}</td>}</tr>{sessions && !serviceAccount && <tr className="expanded-row"><td colSpan={columns}><ul className="security-list compact-security-list">{sessions.length === 0 ? <li><div><strong>No sessions</strong></div></li> : sessions.map((record) => <li key={record.id}><div><strong>Session {record.id.slice(0, 8)}</strong><small>Last used {formatDateTime(record.last_used_at)}</small></div><span className={`status-pill ${record.revoked_at ? "neutral" : "success"}`}>{record.revoked_at ? "Revoked" : "Active"}</span>{!record.revoked_at && <button className="button danger compact" type="button" disabled={busy === `admin-session-${record.id}`} onClick={() => onRevokeSession(record.id)}>Revoke</button>}</li>)}</ul></td></tr>}</>;
}

function invitationUrl(token: string, tenantSlug?: string): string {
  const url = new URL("/app/", window.location.origin);
  const hash = new URLSearchParams({ invitation_token: token });
  if (tenantSlug) hash.set("tenant_slug", tenantSlug);
  url.hash = hash.toString();
  return url.toString();
}

function peopleActionBusyKey(action: PendingPeopleAction): string {
  if (action.kind === "user-change") return `user-${action.user.id}`;
  if (action.kind === "invitation-revocation") return `invite-${action.invitation.id}`;
  return `admin-session-${action.sessionId}`;
}
