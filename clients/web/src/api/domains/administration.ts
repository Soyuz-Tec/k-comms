import type { AccountSession, AuditEvent, DataResponse, DeletionRequest, Invitation, LegalHold, ListResponse, ModerationCase, OperationsSnapshot, RetentionPolicy, TenantAdministration, User, UserRole } from "../../types";
import type { ApiDownload, ApiRequest, AuditExportFile, AuditExportInput, UpdateTenantInput } from "../contracts";
import type { AuditPage, ModerationCaseDetail, ModerationCaseQuery } from "../../types/administration";
import type { DeletionHistoryExportFile, DeletionHistoryPage, DeletionHistoryQuery } from "../../types/deletionHistory";
import type { FixedRolePermission, UserRoleChangePreview } from "../../types/rolePermissions";
import type { UsageExportFile, UsageQuery, UsageReport } from "../../types/usage";
import { ApiError } from "../errors";
import type { WorkspaceDomainClaim, WorkspaceDomainCreateInput, WorkspaceDomainInventory } from "../../types/workspaceDiscovery";

interface AdministrationApiSupport {
  operationId: () => string;
}

export function createAdministrationApi(request: ApiRequest, download: ApiDownload, { operationId }: AdministrationApiSupport) {
  const api = {
    workspaceDomains(): Promise<WorkspaceDomainInventory> {
      return request<WorkspaceDomainInventory>("/api/v1/admin/workspace-domains");
    },

    createWorkspaceDomain(input: WorkspaceDomainCreateInput): Promise<WorkspaceDomainClaim> {
      return request<DataResponse<WorkspaceDomainClaim>>("/api/v1/admin/workspace-domains", { method: "POST", body: JSON.stringify(input) }).then((response) => response.data);
    },

    renewWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
      return request<DataResponse<WorkspaceDomainClaim>>(`/api/v1/admin/workspace-domains/${encodeURIComponent(id)}/challenge`, { method: "POST", body: JSON.stringify({ version }) }).then((response) => response.data);
    },

    verifyWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
      return request<DataResponse<WorkspaceDomainClaim>>(`/api/v1/admin/workspace-domains/${encodeURIComponent(id)}/verify`, { method: "POST", body: JSON.stringify({ version }) }).then((response) => response.data);
    },

    updateWorkspaceDomainDiscovery(id: string, version: number, discoveryEnabled: boolean): Promise<WorkspaceDomainClaim> {
      return request<DataResponse<WorkspaceDomainClaim>>(`/api/v1/admin/workspace-domains/${encodeURIComponent(id)}`, { method: "PATCH", body: JSON.stringify({ version, discovery_enabled: discoveryEnabled }) }).then((response) => response.data);
    },

    removeWorkspaceDomain(id: string, version: number): Promise<WorkspaceDomainClaim> {
      return request<DataResponse<WorkspaceDomainClaim>>(`/api/v1/admin/workspace-domains/${encodeURIComponent(id)}`, { method: "DELETE", body: JSON.stringify({ version }) }).then((response) => response.data);
    },
    adminUsers(): Promise<User[]> {
        return request<ListResponse<User>>("/api/v1/admin/users").then((response) => response.data);
      },

    updateAdminUser(id: string, input: { role?: UserRole; status?: string; display_name?: string; reason?: string; version: number }): Promise<User> {
        return request<DataResponse<User>>(`/api/v1/admin/users/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    previewAdminUserRole(id: string, input: { role: UserRole; version: number }): Promise<UserRoleChangePreview> {
      return request<DataResponse<UserRoleChangePreview>>(`/api/v1/admin/users/${encodeURIComponent(id)}/role-preview`, {
        method: "POST", body: JSON.stringify(input)
      }).then((response) => response.data);
    },

    fixedRolePermissions(): Promise<FixedRolePermission[]> {
      return request<ListResponse<FixedRolePermission>>("/api/v1/admin/role-permissions").then((response) => response.data);
    },

    usageReport(input: UsageQuery = {}): Promise<UsageReport> {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(input)) { if (value) params.set(key, value); }
      return request<DataResponse<UsageReport>>(`/api/v1/admin/usage${params.size ? `?${params}` : ""}`).then((response) => response.data);
    },

    async exportUsageReport(input: UsageQuery = {}): Promise<UsageExportFile> {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(input)) { if (value) params.set(key, value); }
      const file = await download(`/api/v1/admin/usage/export${params.size ? `?${params}` : ""}`);
      if (!file.usage || (input.from && file.usage.from !== input.from) || (input.through && file.usage.through !== input.through)) {
        throw new ApiError(502, "invalid_usage_export", "The usage export receipt could not be verified.");
      }
      return { blob: file.blob, filename: `usage-${file.usage.from}-${file.usage.through}.csv`, usage: file.usage };
    },

    adminUserSessions(userId: string): Promise<AccountSession[]> {
        return request<ListResponse<AccountSession>>(`/api/v1/admin/users/${encodeURIComponent(userId)}/sessions`).then(
          (response) => response.data
        );
      },

    adminRevokeSession(userId: string, sessionId: string, reason?: string): Promise<void> {
        return request(`/api/v1/admin/users/${encodeURIComponent(userId)}/sessions/${encodeURIComponent(sessionId)}`, {
          method: "DELETE",
          body: reason ? JSON.stringify({ reason }) : undefined
        });
      },

    tenantAdministration(): Promise<TenantAdministration> {
        return request<DataResponse<TenantAdministration>>("/api/v1/admin/tenant").then(
          (response) => response.data
        );
      },

    updateTenantAdministration(input: UpdateTenantInput): Promise<TenantAdministration> {
        return request<DataResponse<TenantAdministration>>("/api/v1/admin/tenant", {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    invitations(): Promise<Invitation[]> {
        return request<ListResponse<Invitation>>("/api/v1/admin/invitations").then(
          (response) => response.data
        );
      },

    createInvitation(input: { email: string; role: Exclude<UserRole, "owner"> }): Promise<{ invitation: Invitation; invitationToken?: string | null }> {
        return request<{ data: Invitation; invitation_token?: string | null }>("/api/v1/admin/invitations", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify(input)
        }).then((response) => ({ invitation: response.data, invitationToken: response.invitation_token }));
      },

    revokeInvitation(id: string, version: number, reason?: string): Promise<Invitation> {
        return request<DataResponse<Invitation>>(`/api/v1/admin/invitations/${encodeURIComponent(id)}/revoke`, {
          method: "POST",
          body: JSON.stringify({ version, reason })
        }).then((response) => response.data);
      },

    auditEvents(limit = 100): Promise<AuditEvent[]> {
        return request<ListResponse<AuditEvent>>(`/api/v1/admin/audit-events?limit=${limit}`).then(
          (response) => response.data
        );
      },

    auditEventsPage(input: AuditExportInput = {}, cursor?: string): Promise<AuditPage> {
        const params = new URLSearchParams();
        for (const [key, value] of Object.entries(input)) {
          if (value !== undefined && value !== "") params.set(key, String(value));
        }
        if (cursor) params.set("cursor", cursor);
        return request<AuditPage>(`/api/v1/admin/audit-events?${params}`);
      },

    exportAuditEvents(input: AuditExportInput = {}): Promise<AuditExportFile> {
        return download("/api/v1/admin/audit-events/export", {
          method: "POST",
          body: JSON.stringify(input)
        });
      },

    moderationCases(input: ModerationCaseQuery = {}): Promise<ModerationCase[]> {
        const params = new URLSearchParams();
        for (const [key, value] of Object.entries(input)) {
          if (value !== undefined && value !== "") params.set(key, String(value));
        }
        return request<ListResponse<ModerationCase>>(`/api/v1/moderation/cases${params.size ? `?${params}` : ""}`).then(
          (response) => response.data
        );
      },

    moderationCase(id: string): Promise<ModerationCaseDetail> {
        return request<ModerationCaseDetail>(`/api/v1/moderation/cases/${encodeURIComponent(id)}`);
      },

    createModerationCase(input: { subject_user_id?: string; conversation_id?: string; message_id?: string; category: string; summary: string; details?: string; priority?: string }): Promise<ModerationCase> {
        return request<DataResponse<ModerationCase>>("/api/v1/moderation/cases", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    addModerationAction(id: string, input: { action_type: string; note: string; version: number }): Promise<ModerationCase> {
        return request<{ data: ModerationCase }>(`/api/v1/moderation/cases/${encodeURIComponent(id)}/actions`, {
          method: "POST",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    retentionPolicies(): Promise<RetentionPolicy[]> {
        return request<ListResponse<RetentionPolicy>>("/api/v1/admin/retention-policies").then(
          (response) => response.data
        );
      },

    createRetentionPolicy(input: { name: string; retention_days: number; delete_attachments: boolean; scope_type?: "tenant" | "conversation"; conversation_id?: string }): Promise<RetentionPolicy> {
        return request<DataResponse<RetentionPolicy>>("/api/v1/admin/retention-policies", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify({ ...input, scope_type: input.scope_type || "tenant", status: "active" })
        }).then((response) => response.data);
      },

    updateRetentionPolicy(id: string, input: { status?: "active" | "disabled"; name?: string; retention_days?: number; delete_attachments?: boolean; scope_type?: "tenant" | "conversation"; conversation_id?: string | null; version: number; reason: string }): Promise<RetentionPolicy> {
        return request<DataResponse<RetentionPolicy>>(`/api/v1/admin/retention-policies/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    legalHolds(): Promise<LegalHold[]> {
        return request<ListResponse<LegalHold>>("/api/v1/admin/legal-holds").then(
          (response) => response.data
        );
      },

    createLegalHold(input: {
        name: string;
        reason: string;
        scope_type: "tenant" | "user" | "conversation";
        target_id?: string;
      }): Promise<LegalHold> {
        const { target_id: targetId, ...body } = input;
        const targetField = input.scope_type === "user"
          ? "subject_user_id"
          : input.scope_type === "conversation"
            ? "conversation_id"
            : null;
        return request<DataResponse<LegalHold>>("/api/v1/admin/legal-holds", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify({ ...body, ...(targetField && targetId ? { [targetField]: targetId } : {}) })
        }).then((response) => response.data);
      },

    releaseLegalHold(id: string, version: number, releaseReason: string): Promise<LegalHold> {
        return request<DataResponse<LegalHold>>(`/api/v1/admin/legal-holds/${encodeURIComponent(id)}/release`, {
          method: "POST",
          body: JSON.stringify({ version, release_reason: releaseReason })
        }).then((response) => response.data);
      },

    deletionRequests(): Promise<DeletionRequest[]> {
        return request<ListResponse<DeletionRequest>>("/api/v1/admin/deletion-requests").then(
          (response) => response.data
        );
      },

    deletionHistory(id: string, input: DeletionHistoryQuery = {}): Promise<DeletionHistoryPage> {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(input)) {
        if (value !== undefined && value !== "") params.set(key, String(value));
      }
      return request<DataResponse<DeletionHistoryPage>>(`/api/v1/admin/deletion-requests/${encodeURIComponent(id)}/timeline${params.size ? `?${params}` : ""}`)
        .then((response) => response.data);
    },

    async exportDeletionHistory(id: string, snapshot: string, limit = 5000): Promise<DeletionHistoryExportFile> {
      const params = new URLSearchParams({ snapshot, limit: String(limit) });
      const file = await download(`/api/v1/admin/deletion-requests/${encodeURIComponent(id)}/timeline/export?${params}`);
      if (!file.history || file.history.snapshot !== snapshot) {
        throw new ApiError(502, "invalid_history_export", "The history export receipt could not be verified. Retry the same snapshot.");
      }
      return { ...file, filename: "deletion-request-history.csv", history: file.history };
    },

    createDeletionRequest(input: { target_type: "user" | "conversation" | "message"; target_id: string; reason: string }): Promise<DeletionRequest> {
        const targetField = input.target_type === "user" ? "subject_user_id" : `${input.target_type}_id`;
        return request<DataResponse<DeletionRequest>>("/api/v1/admin/deletion-requests", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify({ target_type: input.target_type, [targetField]: input.target_id, reason: input.reason })
        }).then((response) => response.data);
      },

    updateDeletionRequest(id: string, input: { status: string; version: number; transition_reason: string }): Promise<DeletionRequest> {
        return request<DataResponse<DeletionRequest>>(`/api/v1/admin/deletion-requests/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    operations(): Promise<OperationsSnapshot> {
        return request<DataResponse<OperationsSnapshot>>("/api/v1/ops").then(
          (response) => response.data
        );
      },

    platformOperations(): Promise<OperationsSnapshot> {
        return request<DataResponse<OperationsSnapshot>>("/api/v1/platform/ops").then(
          (response) => response.data
        );
      },

    retryOperation(resourceType: "notification" | "webhook" | "attachment_scan", id: string): Promise<void> {
        return request("/api/v1/ops/retry", {
          method: "POST",
          body: JSON.stringify({ resource_type: resourceType, id })
        });
      }
  };
  return api;
}

export type AdministrationApi = ReturnType<typeof createAdministrationApi>;
