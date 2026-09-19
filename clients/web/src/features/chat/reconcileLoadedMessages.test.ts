import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Message } from "../../types";
import { mergeReconciledMessages, readLoadedMessages } from "./reconcileLoadedMessages";

const message = (sequence: number, body = `Message ${sequence}`): Message => ({
  id: `m-${sequence}`, tenant_id: "tenant", conversation_id: "conversation",
  sender_user_id: "user", sender_device_id: "device", client_message_id: `c-${sequence}`,
  conversation_sequence: sequence, body, status: "active", metadata: {},
  inserted_at: "2026-09-19T00:00:00Z", attachments: [], reactions: []
});

describe("loaded message reconciliation", () => {
  it("reads all older loaded windows in bounded pages and stops at the loaded upper boundary", async () => {
    const snapshot = Array.from({ length: 250 }, (_, index) => message(index + 11));
    const pages = [snapshot.slice(0, 200), snapshot.slice(200)];
    const messages = vi.fn().mockResolvedValueOnce({ data: pages[0], page: { has_more: true, next_after_sequence: 210 } })
      .mockResolvedValueOnce({ data: pages[1], page: { has_more: false } });
    const incoming = await readLoadedMessages({ messages } as unknown as ApiClient, "conversation", snapshot, () => true, vi.fn());
    expect(messages.mock.calls).toEqual([["conversation", 10, 200, 261], ["conversation", 210, 200, 261]]);
    expect(incoming).toEqual(snapshot);
  });

  it("converges edits, tombstones, reactions and unavailable rows while preserving later events and pages", () => {
    const snapshot = [message(1), message(2), message(3), message(4), message(5)];
    const current = [message(0), ...snapshot, message(6)];
    const later = { ...snapshot[4]!, reactions: [{ user_id: "live", emoji: "👍" }] };
    current[5] = later;
    const incoming = [message(1, "Edited offline"), { ...message(2), body: null, status: "deleted" as const },
      { ...message(3), reactions: [{ user_id: "offline", emoji: "👍" }] }, message(5)];
    const result = mergeReconciledMessages(current, snapshot, incoming);
    expect(result.messages.map(({ id }) => id)).toEqual(["m-0", "m-1", "m-2", "m-3", "m-5", "m-6"]);
    expect(result.messages[1]!.body).toBe("Edited offline");
    expect(result.messages[2]!.status).toBe("deleted");
    expect(result.messages[3]!.reactions).toEqual(incoming[2]!.reactions);
    expect(result.messages[4]).toBe(later);
    expect(result.changedDuringRead).toBe(true);
  });
});
