import { describe, expect, it } from "vitest";
import type { User } from "../types";
import { canAccessAdmin, canAccessWorkspaceAdmin, canOperate, rolesAssignableBy } from "./roles";

describe("role-aware product surfaces", () => {
  it("routes fixed tenant roles only to their authorized surfaces", () => {
    expect(canAccessAdmin("member")).toBe(false);
    expect(canAccessAdmin("moderator")).toBe(true);
    expect(canAccessAdmin("compliance_admin")).toBe(true);
    expect(canAccessAdmin("security_admin")).toBe(true);
    expect(canOperate(null)).toBe(false);
    const future = new Date(Date.now() + 60_000).toISOString();
    const past = new Date(Date.now() - 60_000).toISOString();
    expect(canOperate("platform_operator", future)).toBe(true);
    expect(canOperate("support_operator", future)).toBe(true);
    expect(canOperate("security_operator", future)).toBe(true);
    expect(canOperate("platform_operator", past)).toBe(false);
    expect(canOperate("platform_operator", null)).toBe(false);
  });

  it("excludes limited humans and nonhuman accounts from every administrative role surface", () => {
    const user: User = { id: "synthetic-user", tenant_id: "synthetic-tenant",
      display_name: "Synthetic member", status: "active", role: "owner",
      account_type: "human", access_scope: "workspace" };
    for (const role of ["owner", "admin", "moderator", "compliance_admin", "security_admin"] as const) {
      expect(canAccessWorkspaceAdmin({ ...user, role })).toBe(true);
      expect(canAccessWorkspaceAdmin({ ...user, role, access_scope: "conversation_only" })).toBe(false);
      expect(canAccessWorkspaceAdmin({ ...user, role, account_type: "guest" })).toBe(false);
      expect(canAccessWorkspaceAdmin({ ...user, role, account_type: "service" })).toBe(false);
    }
    expect(canAccessWorkspaceAdmin({ ...user, role: "member" })).toBe(false);
  });

  it("does not offer elevated assignments to tenant administrators", () => {
    expect(rolesAssignableBy("admin")).toEqual(["member", "moderator"]);
    expect(rolesAssignableBy("owner")).toContain("compliance_admin");
    expect(rolesAssignableBy("owner")).toContain("security_admin");
  });
});
