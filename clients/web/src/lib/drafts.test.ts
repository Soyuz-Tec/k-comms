import { beforeEach, describe, expect, it } from "vitest";
import {
  clearDrafts,
  draftKey,
  loadDraft,
  loadThreadDraft,
  storeDraft,
  storeThreadDraft,
  threadDraftKey
} from "./drafts";

describe("scoped drafts", () => {
  beforeEach(() => window.localStorage.clear());

  it("does not expose one user's draft to another user in the same conversation", () => {
    storeDraft("tenant-1", "user-a", "conversation-1", "private draft");
    expect(loadDraft("tenant-1", "user-a", "conversation-1")).toBe("private draft");
    expect(loadDraft("tenant-1", "user-b", "conversation-1")).toBe("");
  });

  it("clears only the signing-out user's scoped drafts and removes legacy unscoped drafts", () => {
    storeDraft("tenant-1", "user-a", "conversation-1", "a");
    storeThreadDraft("tenant-1", "user-a", "conversation-1", "root-1", "thread a");
    storeDraft("tenant-1", "user-b", "conversation-1", "b");
    storeThreadDraft("tenant-1", "user-b", "conversation-1", "root-1", "thread b");
    window.localStorage.setItem("k-comms.draft.v1.conversation-1", "legacy");

    clearDrafts("tenant-1", "user-a");

    expect(window.localStorage.getItem(draftKey("tenant-1", "user-a", "conversation-1"))).toBeNull();
    expect(window.localStorage.getItem(threadDraftKey("tenant-1", "user-a", "conversation-1", "root-1"))).toBeNull();
    expect(loadDraft("tenant-1", "user-b", "conversation-1")).toBe("b");
    expect(loadThreadDraft("tenant-1", "user-b", "conversation-1", "root-1")).toBe("thread b");
    expect(window.localStorage.getItem("k-comms.draft.v1.conversation-1")).toBeNull();
  });

  it("isolates drafts for each canonical thread root", () => {
    storeThreadDraft("tenant-1", "user-a", "conversation-1", "root-1", "first thread");
    storeThreadDraft("tenant-1", "user-a", "conversation-1", "root-2", "second thread");

    expect(loadThreadDraft("tenant-1", "user-a", "conversation-1", "root-1")).toBe("first thread");
    expect(loadThreadDraft("tenant-1", "user-a", "conversation-1", "root-2")).toBe("second thread");
    expect(loadThreadDraft("tenant-1", "user-a", "conversation-2", "root-1")).toBe("");
  });
});
