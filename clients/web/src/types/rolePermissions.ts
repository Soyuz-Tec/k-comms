import type { UserRole } from "./identity";

export type RoleCapability =
  | "administer_users"
  | "manage_user_lifecycle"
  | "manage_sessions"
  | "manage_tenant_settings"
  | "manage_invitations"
  | "audit_tenant"
  | "govern_tenant";

export type RoleCapabilityCondition =
  | "active_tenant"
  | "active_identity"
  | "current_session"
  | "workspace_access"
  | "recent_step_up";

export interface RoleCapabilityFact {
  capability: RoleCapability;
  scope: "tenant";
  conditions: RoleCapabilityCondition[];
}

export interface FixedRolePermission {
  role: UserRole;
  capabilities: RoleCapabilityFact[];
}

export interface UserRoleChangePreview {
  target_id: string;
  current_role: UserRole;
  requested_role: UserRole;
  current_version: number;
  target_status: "active" | "suspended";
  target_access_scope: "workspace" | "conversation_only";
  role_policy_allows: boolean;
  blockers: Array<"forbidden" | "last_owner_required">;
  added: RoleCapabilityFact[];
  removed: RoleCapabilityFact[];
  advisory: true;
  scope: "tenant";
  governance_review_required: true;
}
