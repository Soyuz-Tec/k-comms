import { describe, expect, it, vi } from "vitest";
import type { ApiDownload, ApiRequest } from "../../api/contracts";
import { createAdministrationApi } from "../../api/domains/administration";
import type { FixedRolePermission, UserRoleChangePreview } from "../../types/rolePermissions";

function client(data: unknown) {
  const request = vi.fn().mockResolvedValue({ data });
  const api = createAdministrationApi(request as ApiRequest, vi.fn() as ApiDownload, { operationId: () => "unused-read" });
  return { api, request };
}

describe("role permission preview transport", () => {
  it("encodes the target and sends only the selected role and current version to the advisory endpoint", async () => {
    const data: UserRoleChangePreview = {
      target_id: "person/1",
      current_role: "member",
      requested_role: "admin",
      current_version: 4,
      target_status: "active",
      target_access_scope: "workspace",
      role_policy_allows: true,
      blockers: [],
      added: [],
      removed: [],
      advisory: true,
      scope: "tenant",
      governance_review_required: true
    };
    const { api, request } = client(data);
    await expect(api.previewAdminUserRole("person/1", { role: "admin", version: 4 })).resolves.toEqual(data);
    expect(request).toHaveBeenCalledExactlyOnceWith("/api/v1/admin/users/person%2F1/role-preview", { method: "POST", body: JSON.stringify({ role: "admin", version: 4 }) });
  });

  it("preserves the catalog's conditional tenant facts without treating them as a mutation receipt", async () => {
    const data: FixedRolePermission[] = [{ role: "security_admin", capabilities: [{ capability: "manage_sessions", scope: "tenant", conditions: ["active_tenant", "active_identity", "current_session", "workspace_access", "recent_step_up"] }] }];
    const { api, request } = client(data);
    await expect(api.fixedRolePermissions()).resolves.toEqual(data);
    expect(request).toHaveBeenCalledExactlyOnceWith("/api/v1/admin/role-permissions");
  });
});
