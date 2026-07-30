import { describe, expect, it } from "vitest";
import type { Conversation, Message } from "../../types";
import {
  advanceContiguousSequence,
  applyMessageReaction,
  collectConversationActivity,
  mergeConversationMessages,
  updateConversationActivity
} from "./conversationFeedReducer";

function message(
  sequence: number,
  overrides: Partial<Message> = {}
): Message {
  const base: Message = {
    id: `message-${sequence}`,
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "user-2",
    sender_device_id: "device-2",
    body: `Message ${sequence}`,
    conversation_sequence: sequence,
    client_message_id: `client-${sequence}`,
    thread_root_message_id: null,
    thread_reply_count: 0,
    metadata: {},
    status: "active",
    reactions: [],
    attachments: [],
    inserted_at: "2026-07-30T12:00:00Z"
  };

  return { ...base, ...overrides };
}

describe("conversationFeedReducer", () => {
  it("merges messages in sequence order and updates a loaded thread root", () => {
    const root = message(1);
    const reply = message(3, {
      thread_root_message_id: root.id,
      thread_reply_count: 2
    });

    const merged = mergeConversationMessages(
      [root],
      [reply, message(2)]
    );

    expect(merged.map(({ conversation_sequence }) => conversation_sequence))
      .toEqual([1, 2, 3]);
    expect(merged[0]?.thread_reply_count).toBe(2);
  });

  it("advances only across a contiguous sequence and retains future gaps", () => {
    const future = new Set<number>();

    expect(advanceContiguousSequence(3, future, [message(5)])).toBe(3);
    expect(future).toEqual(new Set([5]));
    expect(advanceContiguousSequence(3, future, [message(4)])).toBe(5);
    expect(future.size).toBe(0);
  });

  it("applies and removes a reaction without duplicating it", () => {
    const event = {
      message_id: "message-1",
      user_id: "user-2",
      emoji: "👍"
    };
    const added = applyMessageReaction([message(1)], event, true);
    const replaced = applyMessageReaction(added, event, true);
    const removed = applyMessageReaction(replaced, event, false);

    expect(replaced[0]?.reactions).toEqual([
      { user_id: "user-2", emoji: "👍" }
    ]);
    expect(removed[0]?.reactions).toEqual([]);
  });

  it("updates unread summaries only for messages from another user", () => {
    const conversation = {
      id: "conversation-1",
      latest_sequence: 1,
      last_read_sequence: 1,
      unread_count: 0
    } as Conversation;
    const activity = collectConversationActivity(
      [message(4)],
      "user-1"
    );

    const [updated] = updateConversationActivity(
      [conversation],
      activity,
      null,
      false
    );

    expect(updated?.latest_sequence).toBe(4);
    expect(updated?.unread_count).toBe(3);
  });
});
