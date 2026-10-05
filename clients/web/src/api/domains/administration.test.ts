import { describe, expect, it, vi } from "vitest";
import type { ApiDownload, ApiRequest } from "../contracts";
import { createAdministrationApi } from "./administration";

function fixture() {
  const request = vi.fn().mockResolvedValue({ data: [], page: { limit: 100, next_cursor: null } });
  const download = vi.fn();
  const api = createAdministrationApi(request as ApiRequest, download as ApiDownload, { operationId: () => "operation-1" });
  return { api, request, download };
}

describe("administration evidence contracts", () => {
  it("preserves bounded domain inventory and supplies current CAS versions to every domain mutation", async () => {
    const { api, request } = fixture();
    const claim = { id: "claim/1", domain: "team.example.org", version: 3, status: "pending", discovery_enabled: false, challenge_value: null };
    request.mockResolvedValue({ data: [claim], limits: { domains: 8 } });
    await expect(api.workspaceDomains()).resolves.toEqual({ data: [claim], limits: { domains: 8 } });
    request.mockResolvedValue({ data: claim });
    await expect(api.createWorkspaceDomain({ domain: "team.example.org", version: 0 })).resolves.toEqual(claim);
    await api.renewWorkspaceDomain("claim/1", 3);
    await api.verifyWorkspaceDomain("claim/1", 4);
    await api.updateWorkspaceDomainDiscovery("claim/1", 5, false);
    await api.removeWorkspaceDomain("claim/1", 6);
    expect(request.mock.calls.slice(1)).toEqual([
      ["/api/v1/admin/workspace-domains", { method: "POST", body: JSON.stringify({ domain: "team.example.org", version: 0 }) }],
      ["/api/v1/admin/workspace-domains/claim%2F1/challenge", { method: "POST", body: JSON.stringify({ version: 3 }) }],
      ["/api/v1/admin/workspace-domains/claim%2F1/verify", { method: "POST", body: JSON.stringify({ version: 4 }) }],
      ["/api/v1/admin/workspace-domains/claim%2F1", { method: "PATCH", body: JSON.stringify({ version: 5, discovery_enabled: false }) }],
      ["/api/v1/admin/workspace-domains/claim%2F1", { method: "DELETE", body: JSON.stringify({ version: 6 }) }]
    ]);
  });

  it("preserves page cursors and uses the same structured filters for the audit list and export", async () => {
    const { api, request, download } = fixture();
    const input = { q: "%_ literal", action: "message.updated", actor_user_id: "actor-1", before: "2026-07-12T10:00:00Z", limit: 100 };
    await expect(api.auditEventsPage(input, "opaque+/=")).resolves.toEqual({ data: [], page: { limit: 100, next_cursor: null } });
    const path = request.mock.calls[0]?.[0] as string;
    const params = new URL(path, "https://comms.test").searchParams;
    expect(Object.fromEntries(params)).toEqual({ ...input, limit: "100", cursor: "opaque+/=" });
    await api.exportAuditEvents({ ...input, limit: 5000 });
    expect(download).toHaveBeenCalledWith("/api/v1/admin/audit-events/export", { method: "POST", body: JSON.stringify({ ...input, limit: 5000 }) });
  });

  it("queries the existing moderation inventory filters on the server", async () => {
    const { api, request } = fixture();
    await api.moderationCases({ status: "in_review", priority: "urgent", limit: 100 });
    expect(request).toHaveBeenCalledWith("/api/v1/moderation/cases?status=in_review&priority=urgent&limit=100");
  });

  it("returns the complete moderation detail envelope and encodes the case identifier", async () => {
    const { api, request } = fixture();
    const detail = { data: { id: "case/1" }, actions: [{ id: "action-1", note: "Reviewed" }] };
    request.mockResolvedValueOnce(detail);
    await expect(api.moderationCase("case/1")).resolves.toEqual(detail);
    expect(request).toHaveBeenCalledWith("/api/v1/moderation/cases/case%2F1");
  });

  it("preserves conversation scope on creation and explicit target clearing during audited edits", async () => {
    const { api, request } = fixture();
    const create = { name: "Channel records", retention_days: 30, delete_attachments: false, scope_type: "conversation" as const, conversation_id: "conversation-1" };
    await api.createRetentionPolicy(create);
    expect(request).toHaveBeenCalledWith("/api/v1/admin/retention-policies", { method: "POST", headers: { "Idempotency-Key": "operation-1" }, body: JSON.stringify({ ...create, status: "active" }) });
    const edit = { scope_type: "tenant" as const, conversation_id: null, retention_days: 90, version: 4, reason: "Adjusted scope" };
    await api.updateRetentionPolicy("policy/1", edit);
    expect(request).toHaveBeenCalledWith("/api/v1/admin/retention-policies/policy%2F1", { method: "PATCH", body: JSON.stringify(edit) });
  });
});
