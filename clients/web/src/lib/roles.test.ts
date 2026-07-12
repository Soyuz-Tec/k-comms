import { describe, expect, it } from "vitest";
import { canAccessAdmin, canOperate, rolesAssignableBy } from "./roles";

describe("role-aware product surfaces", () => {
  it("routes fixed tenant roles only to their authorized surfaces", () => {
    expect(canAccessAdmin("member")).toBe(false);
    expect(canAccessAdmin("moderator")).toBe(true);
    expect(canAccessAdmin("compliance_admin")).toBe(true);
    expect(canAccessAdmin("security_admin")).toBe(true);
    expect(canOperate(null)).toBe(false);
    expect(canOperate("platform_operator")).toBe(true);
    expect(canOperate("support_operator")).toBe(true);
    expect(canOperate("security_operator")).toBe(true);
  });

  it("does not offer elevated assignments to tenant administrators", () => {
    expect(rolesAssignableBy("admin")).toEqual(["member", "moderator"]);
    expect(rolesAssignableBy("owner")).toContain("compliance_admin");
    expect(rolesAssignableBy("owner")).toContain("security_admin");
  });
});
