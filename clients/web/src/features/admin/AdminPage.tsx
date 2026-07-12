import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import {
  canAccessAdmin,
  canAdministerTenant,
  canAudit,
  canGovern,
  canManageSessions,
  canManageUsers,
  canModerate
} from "../../lib/roles";
import type { UserRole } from "../../types";
import { AuditPanel } from "./AuditPanel";
import { GovernancePanel } from "./GovernancePanel";
import { IntegrationsPanel } from "./IntegrationsPanel";
import { PeoplePanel } from "./PeoplePanel";
import { SafetyPanel } from "./SafetyPanel";
import { TenantSettingsPanel } from "./TenantSettingsPanel";

type AdminSection = "workspace" | "people" | "safety" | "governance" | "integrations" | "audit";

export function AdminPage() {
  const { api, session, setSession } = useSession();
  const { users, conversations, setUsers, setCapabilities, refreshAll } = useWorkspaceData();
  const role = session?.user.role || "member";
  const sections = adminSections(role);
  const [section, setSection] = useState<AdminSection>(() => sections[0]?.[0] || "workspace");
  useEffect(() => {
    if (!sections.some(([id]) => id === section)) setSection(sections[0]?.[0] || "workspace");
  }, [role, section]);
  if (!session) return null;
  if (!canAccessAdmin(session.user.role)) return <Navigate to="/app" replace />;

  return (
    <main className="page-shell" id="main-content">
      <header className="page-heading admin-heading"><div><span className="eyebrow">Tenant administration</span><h1>Workspace control center</h1><p>Manage access, policies, safety, integrations and audit evidence through tenant-scoped APIs.</p></div></header>
      <section className="admin-stats" aria-label="Workspace summary"><article><span>People</span><strong>{users.length}</strong><small>{users.filter(({ status }) => status === "active").length} active</small></article><article><span>Visible conversations</span><strong>{conversations.length}</strong><small>{conversations.filter(({ kind }) => kind === "channel").length} channels</small></article><article><span>Workspace</span><strong className="word-stat">{session.tenant.status}</strong><small>{session.tenant.slug}</small></article></section>
      <nav className="admin-section-nav" aria-label="Administration sections">{sections.map(([id, label]) => <button type="button" key={id} aria-current={section === id ? "page" : undefined} onClick={() => setSection(id)}>{label}</button>)}</nav>
      {section === "workspace" && <TenantSettingsPanel api={api} onUpdated={(updated) => {
        setSession({ ...session, tenant: updated.tenant });
        setCapabilities((current) => current ? { ...current, allow_public_channels: updated.settings.allow_public_channels, message_edit_window_seconds: updated.settings.message_edit_window_seconds, max_attachment_bytes: updated.settings.max_attachment_bytes } : current);
      }} />}
      {section === "people" && <PeoplePanel api={api} actorRole={session.user.role} users={users} setUsers={setUsers} />}
      {section === "safety" && <SafetyPanel api={api} canManageAttachments={canAdministerTenant(session.user.role)} />}
      {section === "governance" && <GovernancePanel api={api} users={users} conversations={conversations} />}
      {section === "integrations" && <IntegrationsPanel api={api} onServiceAccountLifecycleChanged={refreshAll} />}
      {section === "audit" && <AuditPanel api={api} users={users} />}
    </main>
  );
}

function adminSections(role: UserRole): Array<[AdminSection, string]> {
  const sections: Array<[AdminSection, string]> = [];
  if (canAdministerTenant(role)) sections.push(["workspace", "Workspace"]);
  if (canManageUsers(role) || canManageSessions(role)) sections.push(["people", "People"]);
  if (canModerate(role)) sections.push(["safety", "Safety"]);
  if (canGovern(role)) sections.push(["governance", "Governance"]);
  if (canAdministerTenant(role)) sections.push(["integrations", "Integrations"]);
  if (canAudit(role)) sections.push(["audit", "Audit"]);
  return sections;
}
