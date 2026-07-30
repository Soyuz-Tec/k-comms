import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { MessagePage } from "../../types";
import {
  loadConversationCatchUp,
  mergeCatchUpRequests
} from "./conversationFeedCatchUp";

describe("conversationFeedCatchUp", () => {
  it("coalesces overlapping requests without widening a bounded replay", () => {
    expect(
      mergeCatchUpRequests(
        { afterSequence: 10, beforeSequence: 20 },
        { afterSequence: 5, beforeSequence: 30 }
      )
    ).toEqual({ afterSequence: 5, beforeSequence: 30 });

    expect(
      mergeCatchUpRequests(
        { afterSequence: 10, beforeSequence: 20 },
        { afterSequence: 5 }
      )
    ).toEqual({ afterSequence: 5, beforeSequence: undefined });
  });

  it("fails closed when the server returns a non-advancing cursor", async () => {
    const page = {
      data: [],
      included: { sender_labels: [] },
      page: { has_more: true, next_after_sequence: 10, reset_required: false }
    } as MessagePage;
    const api = {
      messages: vi.fn().mockResolvedValue(page)
    } as unknown as ApiClient;

    await expect(
      loadConversationCatchUp(
        api,
        "conversation-1",
        10,
        undefined,
        () => true,
        vi.fn(),
        vi.fn()
      )
    ).rejects.toThrow("non-advancing cursor");
  });

  it("stops applying pages after the owning conversation is replaced", async () => {
    let current = true;
    const applyMessages = vi.fn(() => {
      current = false;
    });
    const api = {
      messages: vi.fn().mockResolvedValue({
        data: [{ id: "message-1" }],
        included: { sender_labels: [] },
        page: { has_more: true, next_after_sequence: 1, reset_required: false }
      })
    } as unknown as ApiClient;

    await loadConversationCatchUp(
      api,
      "conversation-1",
      0,
      undefined,
      () => current,
      vi.fn(),
      applyMessages
    );

    expect(applyMessages).toHaveBeenCalledOnce();
    expect(api.messages).toHaveBeenCalledOnce();
  });
});
