import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  INSTANT_WORKSPACE_DRAFT_TTL_MS,
  loadInstantWorkspaceDraft,
  newInstantWorkspaceDraft,
  saveInstantWorkspaceDraft
} from "./instantWorkspaceDraftStore";

const storageKey = "k-comms.instant-workspace-draft.v1";

describe("instantWorkspaceDraftStore", () => {
  beforeEach(() => {
    window.localStorage.clear();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-02T12:00:00.000Z"));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("restores a well-formed draft within the retention window", () => {
    const draft = newInstantWorkspaceDraft("Guest 1234");
    saveInstantWorkspaceDraft({
      ...draft,
      roomTitle: "Design review",
      updatedAt: new Date(Date.now() - INSTANT_WORKSPACE_DRAFT_TTL_MS + 1_000).toISOString()
    });

    expect(loadInstantWorkspaceDraft("Fallback")).toMatchObject({
      id: draft.id,
      displayName: "Guest 1234",
      roomTitle: "Design review"
    });
  });

  it("discards a draft after 24 hours", () => {
    const draft = newInstantWorkspaceDraft("Guest 1234");
    saveInstantWorkspaceDraft({
      ...draft,
      updatedAt: new Date(Date.now() - INSTANT_WORKSPACE_DRAFT_TTL_MS - 1).toISOString()
    });

    const restored = loadInstantWorkspaceDraft("Fallback");

    expect(restored.id).not.toBe(draft.id);
    expect(restored.displayName).toBe("Fallback");
    expect(window.localStorage.getItem(storageKey)).toBeNull();
  });

  it("removes malformed or future-dated records", () => {
    window.localStorage.setItem(storageKey, "not-json");
    loadInstantWorkspaceDraft("Fallback");
    expect(window.localStorage.getItem(storageKey)).toBeNull();

    const draft = newInstantWorkspaceDraft("Guest 1234");
    saveInstantWorkspaceDraft({
      ...draft,
      updatedAt: new Date(Date.now() + 61_000).toISOString()
    });
    expect(loadInstantWorkspaceDraft("Fallback").id).not.toBe(draft.id);
    expect(window.localStorage.getItem(storageKey)).toBeNull();
  });
});
