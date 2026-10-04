import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Message } from "../../types";
import { useConversationFeed } from "./useConversationFeed";

function message(): Message {
  return {
    id: "message-1",
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "user-1",
    sender_device_id: "device-1",
    client_message_id: "client-1",
    conversation_sequence: 1,
    body: "Original message",
    metadata: {},
    status: "active",
    inserted_at: "2026-10-04T12:00:00Z",
    attachments: [],
    reactions: []
  };
}

function renderFeed() {
  return renderHook(() => useConversationFeed({
    api: {} as ApiClient,
    session: null,
    activeConversation: null,
    activeConversationId: "conversation-1",
    linkedSearchSequence: null,
    readerActive: false,
    setError: vi.fn(),
    setConversations: vi.fn(),
    refreshConversations: vi.fn().mockResolvedValue(undefined),
    mergeRetainedSenderLabels: vi.fn(),
    scheduleMemberRefresh: vi.fn(),
    notePresence: vi.fn(),
    noteRealtimeDisconnected: vi.fn(),
    onMembershipChanged: vi.fn(),
    publishRealtimeEvent: vi.fn()
  }));
}

describe("useConversationFeed thread mutation reconciliation", () => {
  it.each(["deleted", "moderated"] as const)("keeps a live %s tombstone when an earlier edit response resolves", async (status) => {
    const { result } = renderFeed();
    const original = message();
    const tombstone: Message = { ...original, status, body: null, deleted_at: "2026-10-04T12:02:00Z" };
    const edited: Message = { ...original, body: "Earlier edit response", edited_at: "2026-10-04T12:01:00Z" };
    let resolveEdit!: (value: Message) => void;
    const pendingEdit = new Promise<Message>((resolve) => { resolveEdit = resolve; });
    act(() => result.current.receiveMessages([original]));
    const reconcileEdit = pendingEdit.then((updated) => result.current.updateLoadedMessage(updated));

    act(() => result.current.receiveMessages([tombstone]));
    expect(result.current.messages).toEqual([tombstone]);

    await act(async () => {
      resolveEdit(edited);
      await reconcileEdit;
    });
    expect(result.current.messages).toEqual([tombstone]);
    expect(result.current.messages[0]).toBe(tombstone);
    expect(result.current.latestSequence).toBe(1);
    expect(result.current.newMessageCount).toBe(0);
  });

  it("still reconciles an active edit and a subsequent deletion into the loaded transcript", () => {
    const { result } = renderFeed();
    const original = message();
    const edited: Message = { ...original, body: "Edited message", edited_at: "2026-10-04T12:01:00Z" };
    const tombstone: Message = { ...edited, status: "deleted", body: null };
    act(() => result.current.receiveMessages([original]));
    act(() => result.current.updateLoadedMessage(edited));
    expect(result.current.messages).toEqual([edited]);
    act(() => result.current.updateLoadedMessage(tombstone));
    expect(result.current.messages).toEqual([tombstone]);
  });
});
