import type { AccountSession, AuditEvent, DataResponse, DeletionRequest, Invitation, LegalHold, ListResponse, ModerationCase, OperationsSnapshot, RetentionPolicy, TenantAdministration, User, UserRole } from "../../types";
import type { ApiDownload, ApiRequest, AuditExportFile, AuditExportInput, UpdateTenantInput } from "../contracts";

interface AdministrationApiSupport {
  operationId: () => string;
}

export function createAdministrationApi(request: ApiRequest, download: ApiDownload, { operationId }: AdministrationApiSupport) {
  const api = {
    adminUsers(): Promise<User[]> {
        return request<ListResponse<User>>("/api/v1/admin/users").then((response) => response.data);
      },

    updateAdminUser(id: string, input: { role?: UserRole; status?: string; display_name?: string; reason?: string; version: number }): Promise<User> {
        return request<DataResponse<User>>(`/api/v1/admin/users/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
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

    exportAuditEvents(input: AuditExportInput = {}): Promise<AuditExportFile> {
        return download("/api/v1/admin/audit-events/export", {
          method: "POST",
          body: JSON.stringify(input)
        });
      },

    moderationCases(): Promise<ModerationCase[]> {
        return request<ListResponse<ModerationCase>>("/api/v1/moderation/cases").then(
          (response) => response.data
        );
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

    createRetentionPolicy(input: { name: string; retention_days: number; delete_attachments: boolean }): Promise<RetentionPolicy> {
        return request<DataResponse<RetentionPolicy>>("/api/v1/admin/retention-policies", {
          method: "POST",
          headers: { "Idempotency-Key": operationId() },
          body: JSON.stringify({ ...input, scope_type: "tenant", status: "active" })
        }).then((response) => response.data);
      },

    updateRetentionPolicy(id: string, input: { status: "active" | "disabled"; version: number; reason: string }): Promise<RetentionPolicy> {
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
