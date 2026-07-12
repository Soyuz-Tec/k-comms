import { beforeEach, describe, expect, it } from "vitest";
import { clearDrafts, draftKey, loadDraft, storeDraft } from "./drafts";

describe("scoped drafts", () => {
  beforeEach(() => window.localStorage.clear());

  it("does not expose one user's draft to another user in the same conversation", () => {
    storeDraft("tenant-1", "user-a", "conversation-1", "private draft");
    expect(loadDraft("tenant-1", "user-a", "conversation-1")).toBe("private draft");
    expect(loadDraft("tenant-1", "user-b", "conversation-1")).toBe("");
  });

  it("clears only the signing-out user's scoped drafts and removes legacy unscoped drafts", () => {
    storeDraft("tenant-1", "user-a", "conversation-1", "a");
    storeDraft("tenant-1", "user-b", "conversation-1", "b");
    window.localStorage.setItem("k-comms.draft.v1.conversation-1", "legacy");

    clearDrafts("tenant-1", "user-a");

    expect(window.localStorage.getItem(draftKey("tenant-1", "user-a", "conversation-1"))).toBeNull();
    expect(loadDraft("tenant-1", "user-b", "conversation-1")).toBe("b");
    expect(window.localStorage.getItem("k-comms.draft.v1.conversation-1")).toBeNull();
  });
});
