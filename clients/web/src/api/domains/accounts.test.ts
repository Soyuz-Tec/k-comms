import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createAccountsApi } from "./accounts";
import { workspaceFixture } from "../../features/member-workspace/memberWorkspace.testSupport";

describe("member workspace contracts", () => {
  it("unwraps versioned state and carries exact snapshot versions without claiming setup completion", async () => {
    const data = workspaceFixture({ version: 7 });
    const request = vi.fn().mockResolvedValue({ data });
    const api = createAccountsApi(request as ApiRequest, { withReceivedAt: (value) => value });
    await expect(api.memberWorkspace()).resolves.toEqual(data);
    expect(request).toHaveBeenLastCalledWith("/api/v1/me/workspace");
    const input = { version: 7, contact_ids: ["person-1"], groups: [{ id: "group-1", name: "Shared name", member_ids: ["person-1"] }] };
    await expect(api.updateMemberWorkspace(input)).resolves.toEqual(data);
    expect(request).toHaveBeenLastCalledWith("/api/v1/me/workspace", { method: "PUT", body: JSON.stringify(input) });
    await api.updateOnboarding({ version: 7, action: "resume" });
    expect(request).toHaveBeenLastCalledWith("/api/v1/me/onboarding", { method: "PATCH", body: JSON.stringify({ version: 7, action: "resume" }) });
  });
});
