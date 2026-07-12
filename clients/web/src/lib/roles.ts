import type { PlatformRole, UserRole } from "../types";

export const tenantRoles: UserRole[] = [
  "member",
  "moderator",
  "admin",
  "compliance_admin",
  "security_admin",
  "owner"
];

export const invitationRoles: UserRole[] = [
  "member",
  "moderator",
  "admin",
  "compliance_admin",
  "security_admin"
];

export function roleLabel(role: UserRole): string {
  return ({
    member: "Member",
    moderator: "Moderator",
    admin: "Administrator",
    compliance_admin: "Compliance administrator",
    security_admin: "Security administrator",
    owner: "Owner"
  } satisfies Record<UserRole, string>)[role];
}

export function canAdministerTenant(role: UserRole): boolean {
  return role === "owner" || role === "admin";
}

export function canManageUsers(role: UserRole): boolean {
  return role === "owner" || role === "admin";
}

export function canManageSessions(role: UserRole): boolean {
  return role === "owner" || role === "security_admin";
}

export function canModerate(role: UserRole): boolean {
  return ["owner", "admin", "moderator", "compliance_admin"].includes(role);
}

export function canGovern(role: UserRole): boolean {
  return role === "owner" || role === "compliance_admin";
}

export function canAudit(role: UserRole): boolean {
  return ["owner", "compliance_admin", "security_admin"].includes(role);
}

export function canAccessAdmin(role: UserRole): boolean {
  return canAdministerTenant(role) || canManageSessions(role) || canModerate(role) || canGovern(role) || canAudit(role);
}

export function canOperate(role?: PlatformRole | null): boolean {
  return role === "platform_operator" || role === "support_operator" || role === "security_operator";
}

export function rolesAssignableBy(actorRole: UserRole, includeOwner = false): UserRole[] {
  if (actorRole === "owner") {
    return includeOwner ? tenantRoles : invitationRoles;
  }
  if (actorRole === "admin") return ["member", "moderator"];
  return [];
}

export function canChangeUser(actorRole: UserRole, targetRole: UserRole): boolean {
  if (actorRole === "owner") return true;
  return actorRole === "admin" && ["member", "moderator"].includes(targetRole);
}
