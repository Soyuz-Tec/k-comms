import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  readRememberedWorkspaceSlug,
  rememberWorkspaceSlug,
  validWorkspaceSlug
} from "./workspacePreference";

describe("workspace preference", () => {
  beforeEach(() => window.localStorage.clear());

  it("remembers only a valid non-secret workspace slug", () => {
    rememberWorkspaceSlug(" I-Team ");
    expect(readRememberedWorkspaceSlug()).toBe("i-team");

    rememberWorkspaceSlug("not valid!");
    expect(readRememberedWorkspaceSlug()).toBe("i-team");
  });

  it("fails open when storage is unavailable", () => {
    const getItem = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable");
    });
    expect(readRememberedWorkspaceSlug()).toBe("");
    getItem.mockRestore();
  });

  it("matches the server workspace-slug contract", () => {
    expect(validWorkspaceSlug("acme")).toBe(true);
    expect(validWorkspaceSlug("north-star-2")).toBe(true);
    expect(validWorkspaceSlug("a")).toBe(false);
    expect(validWorkspaceSlug("-north-star")).toBe(false);
    expect(validWorkspaceSlug("north--star")).toBe(false);
  });
});
