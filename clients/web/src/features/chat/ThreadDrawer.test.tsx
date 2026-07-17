import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient, SendMessageInput } from "../../api";
import { loadThreadDraft, storeThreadDraft } from "../../lib/drafts";
import type { Attachment, ConversationMembership, Message, User } from "../../types";
import { ThreadDrawer } from "./ThreadDrawer";

const uploadMocks = vi.hoisted(() => ({
  sha256: vi.fn().mockResolvedValue("checksum"),
  upload: vi.fn().mockResolvedValue(undefined)
}));

vi.mock("../../api", async (importOriginal) => {
  const actual = await importOriginal<Record<string, unknown>>();
  return {
    ...actual,
    sha256: uploadMocks.sha256,
    uploadToPresignedTarget: uploadMocks.upload
  };
});

const currentUser = user("user-1", "Ada");
const mentionedUser = user("user-2", "Grace");
const members = [membership(currentUser), membership(mentionedUser)];

describe("ThreadDrawer composer parity", () => {
  beforeEach(() => {
    window.localStorage.clear();
    uploadMocks.sha256.mockClear();
    uploadMocks.upload.mockClear();
  });

  it("restores and updates a draft scoped to the canonical thread root", async () => {
    storeThreadDraft("tenant-1", "user-1", "conversation-1", "root-1", "Saved reply");
    const api = apiDouble();
    const view = renderDrawer({ api });

    const composer = await screen.findByLabelText("Reply in thread");
    expect(composer).toHaveValue("Saved reply");

    await userEvent.setup().type(composer, " with context");
    expect(loadThreadDraft("tenant-1", "user-1", "conversation-1", "root-1")).toBe("Saved reply with context");

    view.unmount();
    renderDrawer({ api });
    expect(await screen.findByLabelText("Reply in thread")).toHaveValue("Saved reply with context");
  });

  it("retries the exact failed reply with its mention IDs and clears the draft after success", async () => {
    const api = apiDouble();
    const sent = message("reply-1", 2, "Mentioned reply");
    const onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>()
      .mockRejectedValueOnce(new Error("temporary disconnect"))
      .mockResolvedValueOnce(sent);
    const userActions = userEvent.setup();
    renderDrawer({ api, onSend });

    const composer = await screen.findByLabelText("Reply in thread");
    await userActions.click(screen.getByRole("button", { name: "Mention" }));
    await userActions.click(screen.getByRole("checkbox", { name: "Grace" }));
    await userActions.type(composer, "Mentioned reply");
    await userActions.click(screen.getByRole("button", { name: "Reply" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Reply not sent. Your draft is safe. temporary disconnect");
    await userActions.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(2));

    expect(onSend.mock.calls[0]?.[0]).toEqual(onSend.mock.calls[1]?.[0]);
    expect(onSend.mock.calls[0]?.[0]).toMatchObject({
      body: "Mentioned reply",
      attachment_ids: [],
      mentioned_user_ids: ["user-2"],
      reply_to_message_id: "root-1"
    });
    expect(composer).toHaveValue("");
    expect(loadThreadDraft("tenant-1", "user-1", "conversation-1", "root-1")).toBe("");
  });

  it("announces attachment scanning, blocks send until ready, and includes the ready file", async () => {
    const uploaded = attachment("uploaded");
    const ready = attachment("ready");
    let resolveStatus: ((value: { data: Attachment }) => void) | undefined;
    const status = new Promise<{ data: Attachment }>((resolve) => { resolveStatus = resolve; });
    const api = apiDouble({
      createAttachment: vi.fn().mockResolvedValue({
        data: uploaded,
        upload: { url: "https://objects.example.test/thread-file", approved_origin: "https://objects.example.test" }
      }),
      completeAttachment: vi.fn().mockResolvedValue(uploaded),
      attachmentStatus: vi.fn().mockReturnValue(status)
    });
    const onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>()
      .mockResolvedValue({ ...message("reply-1", 2, "File reply"), attachments: [ready] });
    const userActions = userEvent.setup();
    renderDrawer({ api, onSend });

    const composer = await screen.findByLabelText("Reply in thread");
    await userActions.type(composer, "File reply");
    fireEvent.change(screen.getByLabelText("Attach files to this thread"), {
      target: { files: [new File(["content"], "brief.txt", { type: "text/plain" })] }
    });

    await waitFor(() => expect(api.createAttachment).toHaveBeenCalled());

    const pendingFiles = await screen.findByLabelText("Files being attached to this thread");
    expect(within(pendingFiles).getByText("Safety scan pending")).toBeVisible();
    expect(screen.getByRole("status")).toHaveTextContent("brief.txt: Safety scan pending");
    expect(screen.getByRole("button", { name: "Reply" })).toBeDisabled();

    await waitFor(() => expect(api.attachmentStatus).toHaveBeenCalledWith("attachment-1"), { timeout: 2_000 });
    await act(async () => resolveStatus?.({ data: ready }));
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("brief.txt: Safety scan passed"));
    expect(screen.getByRole("button", { name: "Reply" })).toBeEnabled();

    await userActions.click(screen.getByRole("button", { name: "Reply" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledWith(expect.objectContaining({ attachment_ids: ["attachment-1"] })));
  });
});

function renderDrawer({
  api,
  onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>().mockResolvedValue(message("reply-1", 2, "Reply"))
}: {
  api: ApiClient;
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
      members={members}
      users={[currentUser, mentionedUser]}
      liveMessages={[]}
      onClose={vi.fn()}
      onSend={onSend}
    />
  );
}

function apiDouble(overrides: Record<string, unknown> = {}): ApiClient {
  return {
    messageThread: vi.fn().mockResolvedValue({
      data: { root: message("root-1", 1, "Root message"), replies: [], reply_count: 0 },
      page: { has_more: false, next_before_sequence: null }
    }),
    createAttachment: vi.fn(),
    completeAttachment: vi.fn(),
    attachmentStatus: vi.fn(),
    attachmentDownload: vi.fn(),
    ...overrides
  } as unknown as ApiClient;
}

function user(id: string, displayName: string): User {
  return {
    id,
    tenant_id: "tenant-1",
    display_name: displayName,
    account_type: "human",
    role: "member",
    status: "active"
  };
}

function membership(member: User): ConversationMembership {
  return {
    id: `membership-${member.id}`,
    role: "member",
    joined_at: "2026-07-15T12:00:00Z",
    last_read_sequence: 0,
    user: member
  };
}

function message(id: string, sequence: number, body: string): Message {
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

function attachment(status: Attachment["status"]): Attachment {
  return {
    id: "attachment-1",
    file_name: "brief.txt",
    content_type: "text/plain",
    byte_size: 7,
    status
  };
}
