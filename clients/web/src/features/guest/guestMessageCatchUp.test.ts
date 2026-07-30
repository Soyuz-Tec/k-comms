import { describe, expect, it, vi } from "vitest";
import type { GuestApiClient } from "../../api";
import type { Message } from "../../types";
import { loadGuestMessageCatchUp } from "./guestMessageCatchUp";

function message(sequence: number): Message {
  return {
    id: `message-${sequence}`,
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "member-2",
    sender_device_id: "device-2",
    client_message_id: `client-message-${sequence}`,
    conversation_sequence: sequence,
    body: `Message ${sequence}`,
    metadata: {},
    status: "active",
    inserted_at: `2026-07-24T12:${String(sequence % 60).padStart(2, "0")}:00Z`,
    attachments: [],
    reactions: []
  };
}

describe("loadGuestMessageCatchUp", () => {
  it("loads more than 700 messages through bounded forward pages", async () => {
    const allMessages = Array.from(
      { length: 750 },
      (_, index) => message(index + 1)
    );
    const capturedLabels: string[] = [];
    const messages = vi.fn(async (afterSequence: number, limit: number) => {
      const data = allMessages.slice(afterSequence, afterSequence + limit);
      const nextAfterSequence = data.at(-1)?.conversation_sequence ?? null;
      return {
        data,
        included: {
          sender_labels: [
            {
              id: `sender-page-${afterSequence}`,
              display_name: `Sender ${afterSequence}`,
              redacted: false
            }
          ]
        },
        page: {
          has_more: afterSequence + data.length < allMessages.length,
          next_after_sequence: nextAfterSequence,
          reset_required: false
        }
      };
    });

    await expect(
      loadGuestMessageCatchUp(
        { messages } as unknown as Pick<GuestApiClient, "messages">,
        0,
        (labels) => capturedLabels.push(...labels.map(({ id }) => id))
      )
    ).resolves.toHaveLength(750);
    expect(messages.mock.calls.map(([afterSequence]) => afterSequence)).toEqual([
      0,
      200,
      400,
      600
    ]);
    expect(capturedLabels).toEqual([
      "sender-page-0",
      "sender-page-200",
      "sender-page-400",
      "sender-page-600"
    ]);
  });
});
