import { render } from "@testing-library/react";
import { vi } from "vitest";
import type { ApiClient, SendMessageInput } from "../../api";
import type { Attachment, ConversationMembership, Message, User } from "../../types";
import { ThreadDrawer } from "./ThreadDrawer";

export const currentUser = user("user-1", "Ada");
export const mentionedUser = user("user-2", "Grace");

export function renderDrawer({
  api,
  users = [currentUser, mentionedUser],
  drawerMembers = users.map(membership),
  liveMessages = [],
  onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>().mockResolvedValue(message("reply-1", 2, "Reply"))
}: {
  api: ApiClient;
  users?: User[];
  drawerMembers?: ConversationMembership[];
  liveMessages?: Message[];
  onSend?: (input: SendMessageInput) => Promise<Message>;
}) {
  return render(
    <ThreadDrawer
      api={api}
      tenantId="tenant-1"
      conversationId="conversation-1"
      targetMessageId="target-reply"
      currentUserId="user-1"
      maxAttachmentBytes={25_000_000}
      members={drawerMembers}
      users={users}
      liveMessages={liveMessages}
      onClose={vi.fn()}
      onSend={onSend}
    />
  );
}

export function apiDouble(overrides: Record<string, unknown> = {}): ApiClient {
  return {
    messageThread: vi.fn().mockResolvedValue({
      data: { root: message("root-1", 1, "Root message"), replies: [], reply_count: 0 },
      page: { has_more: false, next_before_sequence: null }
    }),
    createAttachment: vi.fn(),
    completeAttachment: vi.fn(),
    attachmentStatus: vi.fn(),
    attachmentDownload: vi.fn(),
    abandonAttachment: vi.fn().mockResolvedValue(undefined),
    ...overrides
  } as unknown as ApiClient;
}

export function threadLookup(rootA: Message, rootB: Message) {
  return vi.fn((_conversationId: string, targetId: string) => {
    if (targetId === "target-a") {
      return Promise.resolve({
        data: { root: rootA, replies: [], reply_count: 0 },
        page: { has_more: false, next_before_sequence: null }
      });
    }
    if (targetId === "target-b") {
      return Promise.resolve({
        data: { root: rootB, replies: [], reply_count: 0 },
        page: { has_more: false, next_before_sequence: null }
      });
    }
    return Promise.reject(new Error(`Unexpected thread request ${targetId}`));
  });
}

export function threadSwitchProps(
  api: ApiClient,
  onSend: (input: SendMessageInput) => Promise<Message>
) {
  return {
    api,
    tenantId: "tenant-1",
    conversationId: "conversation-1",
    currentUserId: "user-1",
    maxAttachmentBytes: 25_000_000,
    members: [membership(currentUser), membership(mentionedUser)],
    users: [currentUser, mentionedUser],
    liveMessages: [],
    onClose: vi.fn(),
    onSend
  };
}

export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

export function user(id: string, displayName: string): User {
  return {
    id,
    tenant_id: "tenant-1",
    display_name: displayName,
    account_type: "human",
    role: "member",
    status: "active"
  };
}

export function membership(member: User): ConversationMembership {
  return {
    id: `membership-${member.id}`,
    role: "member",
    joined_at: "2026-07-15T12:00:00Z",
    last_read_sequence: 0,
    user: member
  };
}

export function message(id: string, sequence: number, body: string): Message {
  return {
    id,
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    sender_user_id: "user-1",
    sender_device_id: "device-1",
    client_message_id: `client-${id}`,
    conversation_sequence: sequence,
    body,
    metadata: {},
    status: "active",
    inserted_at: "2026-07-15T12:00:00Z",
    attachments: [],
    reactions: []
  };
}

export function attachment(status: Attachment["status"]): Attachment {
  return {
    id: "attachment-1",
    file_name: "brief.txt",
    content_type: "text/plain",
    byte_size: 7,
    status
  };
}
