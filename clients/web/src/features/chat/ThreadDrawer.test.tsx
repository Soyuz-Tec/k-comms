import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient, SendMessageInput } from "../../api";
import { loadThreadDraft, storeThreadDraft } from "../../lib/drafts";
import { participantDisambiguator } from "../../lib/participantIdentity";
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

describe("ThreadDrawer composer parity", () => {
  beforeEach(() => {
    window.localStorage.clear();
    uploadMocks.sha256.mockClear();
    uploadMocks.upload.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
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

  it("identifies the current sender by resolved username followed by you", async () => {
    const duplicateAda = user("user-2", "Ada");
    const api = apiDouble({
      messageThread: vi.fn().mockResolvedValue({
        data: {
          root: message("root-1", 1, "Root message"),
          replies: [
            {
              ...message("reply-1", 2, "Duplicate-name reply"),
              sender_user_id: duplicateAda.id
            }
          ],
          reply_count: 1
        },
        page: { has_more: false, next_before_sequence: null }
      })
    });
    renderDrawer({ api, users: [currentUser, duplicateAda] });

    expect(
      await screen.findByText(
        `Ada · #${participantDisambiguator(currentUser.id)} (you)`
      )
    ).toBeVisible();
    expect(
      screen.getByText(`Ada · #${participantDisambiguator(duplicateAda.id)}`)
    ).toBeVisible();
    expect(screen.queryByText("You")).not.toBeInTheDocument();
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

  it("renders retained and deleted sender labels with stable duplicate-name identifiers", async () => {
    const firstDepartedId = "departed-user-1";
    const secondDepartedId = "departed-user-2";
    const deletedId = "deleted-user-1";
    const root = { ...message("root-1", 1, "Root message"), sender_user_id: firstDepartedId };
    const firstReply = {
      ...message("reply-1", 2, "First reply"),
      sender_user_id: secondDepartedId
    };
    const secondReply = {
      ...message("reply-2", 3, "Second reply"),
      sender_user_id: deletedId
    };
    const api = apiDouble({
      messageThread: vi.fn().mockResolvedValue({
        data: { root, replies: [firstReply, secondReply], reply_count: 2 },
        included: {
          sender_labels: [
            { id: firstDepartedId, display_name: "Former teammate", redacted: false },
            { id: secondDepartedId, display_name: "Former teammate", redacted: false },
            { id: deletedId, display_name: "Deleted user", redacted: true }
          ]
        },
        page: { has_more: false, next_before_sequence: null }
      })
    });

    renderDrawer({ api });

    expect(
      await screen.findByText(
        `Former teammate · #${participantDisambiguator(firstDepartedId)}`
      )
    ).toBeVisible();
    expect(
      screen.getByText(
        `Former teammate · #${participantDisambiguator(secondDepartedId)}`
      )
    ).toBeVisible();
    expect(screen.getByText("Deleted user")).toBeVisible();
    expect(screen.queryByText("Unknown user")).not.toBeInTheDocument();
  });

  it("uses an active guest username for a live reply and retains it after departure", async () => {
    const guest = {
      ...user("guest-live", "Visiting analyst"),
      account_type: "guest" as const
    };
    const liveReply = {
      ...message("reply-live", 2, "Live guest reply"),
      sender_user_id: guest.id,
      thread_root_message_id: "root-1"
    };
    const api = apiDouble();
    const commonProps = {
      api,
      tenantId: "tenant-1",
      conversationId: "conversation-1",
      targetMessageId: "target-reply",
      currentUserId: "user-1",
      maxAttachmentBytes: 25_000_000,
      users: [currentUser, mentionedUser],
      liveMessages: [liveReply],
      onClose: vi.fn(),
      onSend: vi.fn<(input: SendMessageInput) => Promise<Message>>()
        .mockResolvedValue(message("reply-sent", 3, "Reply"))
    };
    const view = render(
      <ThreadDrawer
        {...commonProps}
        members={[
          membership(currentUser),
          membership(mentionedUser),
          membership(guest)
        ]}
      />
    );

    expect(await screen.findByText("Visiting analyst")).toBeVisible();
    expect(screen.getByText("Live guest reply")).toBeVisible();

    view.rerender(
      <ThreadDrawer
        {...commonProps}
        members={[membership(currentUser), membership(mentionedUser)]}
      />
    );
    expect(screen.getByText("Visiting analyst")).toBeVisible();
    expect(screen.queryByText("Unknown user")).not.toBeInTheDocument();
  });

  it("makes a fresh deletion tombstone outrank stale active-member data", async () => {
    const deletedRoot = {
      ...message("root-1", 1, "Erased author message"),
      sender_user_id: mentionedUser.id
    };
    const api = apiDouble({
      messageThread: vi.fn().mockResolvedValue({
        data: { root: deletedRoot, replies: [], reply_count: 0 },
        included: {
          sender_labels: [
            { id: mentionedUser.id, display_name: "Deleted user", redacted: true }
          ]
        },
        page: { has_more: false, next_before_sequence: null }
      })
    });

    renderDrawer({ api });

    const body = await screen.findByText("Erased author message");
    expect(within(body.closest("article")!).getByText("Deleted user")).toBeVisible();
    expect(within(body.closest("article")!).queryByText("Grace")).not.toBeInTheDocument();
  });

  it("refreshes erased and renamed sender labels while the thread remains open", async () => {
    const scheduledRefreshes: Array<{ handler: () => void; delay: number }> = [];
    const nativeSetTimeout = window.setTimeout.bind(window);
    vi.spyOn(window, "setTimeout").mockImplementation(
      ((handler: TimerHandler, timeout?: number) => {
        if (
          typeof handler === "function" &&
          [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
        ) {
          scheduledRefreshes.push({
            handler: handler as () => void,
            delay: timeout || 0
          });
        }
        return [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
          ? 1_000_000 + scheduledRefreshes.length
          : nativeSetTimeout(handler, timeout);
      }) as typeof window.setTimeout
    );
    const root = message("root-1", 1, "Root message");
    const reply = {
      ...message("reply-1", 2, "Reply awaiting erasure"),
      sender_user_id: mentionedUser.id,
      thread_root_message_id: root.id
    };
    const departedUserId = "departed-user";
    const departedReply = {
      ...message("reply-2", 3, "Reply awaiting rename"),
      sender_user_id: departedUserId,
      thread_root_message_id: root.id
    };
    const messageSenderLabels = vi.fn().mockResolvedValue([
      {
        id: mentionedUser.id,
        display_name: "Deleted user",
        redacted: true
      },
      {
        id: departedUserId,
        display_name: "Renamed teammate",
        redacted: false
      }
    ]);
    const api = apiDouble({
      messageThread: vi.fn().mockResolvedValue({
        data: { root, replies: [reply, departedReply], reply_count: 2 },
        included: {
          sender_labels: [
            {
              id: departedUserId,
              display_name: "Former teammate",
              redacted: false
            }
          ]
        },
        page: { has_more: false, next_before_sequence: null }
      }),
      messageSenderLabels
    });
    const view = renderDrawer({ api });

    const replyBody = await screen.findByText("Reply awaiting erasure");
    const departedReplyBody = screen.getByText("Reply awaiting rename");
    expect(within(replyBody.closest("article")!).getByText("Grace")).toBeVisible();
    expect(
      within(departedReplyBody.closest("article")!).getByText("Former teammate")
    ).toBeVisible();
    expect(scheduledRefreshes.at(-1)?.delay).toBe(30_000);

    await act(async () => {
      scheduledRefreshes.at(-1)?.handler();
      await Promise.resolve();
    });

    await waitFor(() => expect(messageSenderLabels).toHaveBeenCalledWith(
      "conversation-1",
      ["root-1", "reply-1", "reply-2"]
    ));
    expect(
      await within(replyBody.closest("article")!).findByText("Deleted user")
    ).toBeVisible();
    expect(within(replyBody.closest("article")!).queryByText("Grace"))
      .not.toBeInTheDocument();
    expect(
      within(departedReplyBody.closest("article")!).getByText("Renamed teammate")
    ).toBeVisible();
    expect(
      within(departedReplyBody.closest("article")!).queryByText("Former teammate")
    ).not.toBeInTheDocument();
    expect(scheduledRefreshes.at(-1)?.delay).toBe(30_000);

    view.unmount();
  });

  it("bounds unchanged sender-label refreshes and prevents overlapping requests", async () => {
    const scheduledRefreshes: Array<{ handler: () => void; delay: number }> = [];
    const nativeSetTimeout = window.setTimeout.bind(window);
    vi.spyOn(window, "setTimeout").mockImplementation(
      ((handler: TimerHandler, timeout?: number) => {
        if (
          typeof handler === "function" &&
          [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
        ) {
          scheduledRefreshes.push({
            handler: handler as () => void,
            delay: timeout || 0
          });
        }
        return [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
          ? 1_000_000 + scheduledRefreshes.length
          : nativeSetTimeout(handler, timeout);
      }) as typeof window.setTimeout
    );
    const pendingLabels =
      deferred<Awaited<ReturnType<ApiClient["messageSenderLabels"]>>>();
    const root = message("root-1", 1, "Root message");
    const firstReply = {
      ...message("reply-1", 2, "First reply"),
      sender_user_id: mentionedUser.id,
      thread_root_message_id: root.id
    };
    const sameSenderReply = {
      ...message("reply-2", 3, "Same sender reply"),
      sender_user_id: mentionedUser.id,
      thread_root_message_id: root.id
    };
    const messageSenderLabels = vi.fn()
      .mockImplementationOnce(() => pendingLabels.promise)
      .mockResolvedValue([]);
    const api = apiDouble({
      messageThread: vi.fn().mockResolvedValue({
        data: {
          root,
          replies: [firstReply, sameSenderReply],
          reply_count: 2
        },
        page: { has_more: false, next_before_sequence: null }
      }),
      messageSenderLabels
    });
    const view = renderDrawer({ api });

    await screen.findByText("Same sender reply");
    const initialRefresh = scheduledRefreshes.at(-1);
    expect(initialRefresh?.delay).toBe(30_000);

    act(() => {
      initialRefresh?.handler();
      initialRefresh?.handler();
    });
    expect(messageSenderLabels).toHaveBeenCalledTimes(1);
    expect(messageSenderLabels).toHaveBeenCalledWith(
      "conversation-1",
      ["root-1", "reply-1"]
    );

    await act(async () => {
      pendingLabels.resolve([]);
      await pendingLabels.promise;
    });
    await waitFor(() => expect(scheduledRefreshes.at(-1)?.delay).toBe(60_000));

    for (const expectedDelay of [120_000, 300_000, 300_000]) {
      await act(async () => {
        scheduledRefreshes.at(-1)?.handler();
        await Promise.resolve();
      });
      await waitFor(() =>
        expect(scheduledRefreshes.at(-1)?.delay).toBe(expectedDelay)
      );
    }
    expect(messageSenderLabels).toHaveBeenCalledTimes(4);

    view.unmount();
  });

  it("discards a delayed older-page response after switching threads", async () => {
    let resolveOlder!: (value: Awaited<ReturnType<ApiClient["messageThread"]>>) => void;
    const older = new Promise<Awaited<ReturnType<ApiClient["messageThread"]>>>(
      (resolve) => { resolveOlder = resolve; }
    );
    const rootA = message("root-a", 2, "Thread A root");
    const rootB = message("root-b", 20, "Thread B root");
    const staleReply = {
      ...message("reply-a-old", 1, "Stale thread A reply"),
      thread_root_message_id: rootA.id,
      sender_user_id: "departed-a"
    };
    const messageThread = vi.fn((conversationId: string, targetId: string, before?: number) => {
      expect(conversationId).toBe("conversation-1");
      if (targetId === "target-a") {
        return Promise.resolve({
          data: { root: rootA, replies: [], reply_count: 1 },
          page: { has_more: true, next_before_sequence: 2 }
        });
      }
      if (targetId === rootA.id && before === 2) return older;
      if (targetId === "target-b") {
        return Promise.resolve({
          data: { root: rootB, replies: [], reply_count: 0 },
          page: { has_more: false, next_before_sequence: null }
        });
      }
      return Promise.reject(new Error(`Unexpected thread request ${targetId}:${before}`));
    });
    const api = apiDouble({ messageThread });
    const commonProps = {
      api,
      tenantId: "tenant-1",
      conversationId: "conversation-1",
      currentUserId: "user-1",
      maxAttachmentBytes: 25_000_000,
      members: [membership(currentUser), membership(mentionedUser)],
      users: [currentUser, mentionedUser],
      liveMessages: [],
      onClose: vi.fn(),
      onSend: vi.fn<(input: SendMessageInput) => Promise<Message>>()
        .mockResolvedValue(message("reply-sent", 21, "Reply"))
    };
    const view = render(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );
    expect(await screen.findByText("Thread A root")).toBeVisible();
    await userEvent.setup().click(
      screen.getByRole("button", { name: "Load older replies" })
    );
    await waitFor(() => expect(messageThread).toHaveBeenCalledWith(
      "conversation-1",
      "root-a",
      2
    ));

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-b" />
    );
    expect(await screen.findByText("Thread B root")).toBeVisible();
    await act(async () => resolveOlder({
      data: { root: rootA, replies: [staleReply], reply_count: 1 },
      included: {
        sender_labels: [
          { id: "departed-a", display_name: "Former A member", redacted: false }
        ]
      },
      page: { has_more: false, next_before_sequence: null }
    }));

    expect(screen.queryByText("Stale thread A reply")).not.toBeInTheDocument();
    expect(screen.queryByText("Former A member")).not.toBeInTheDocument();
    expect(screen.getByText("Thread B root")).toBeVisible();
  });

  it("keeps the next thread draft intact when a send from the previous thread finishes late", async () => {
    const rootA = message("root-a", 1, "Thread A root");
    const rootB = message("root-b", 20, "Thread B root");
    const sentReply = {
      ...message("reply-a", 2, "Sent reply for thread A"),
      thread_root_message_id: rootA.id
    };
    const pendingSend = deferred<Message>();
    const onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>(
      () => pendingSend.promise
    );
    const api = apiDouble({
      messageThread: threadLookup(rootA, rootB)
    });
    storeThreadDraft(
      "tenant-1",
      "user-1",
      "conversation-1",
      rootB.id,
      "Thread B saved draft"
    );
    const commonProps = threadSwitchProps(api, onSend);
    const userActions = userEvent.setup();
    const view = render(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );

    const composerA = await screen.findByLabelText("Reply in thread");
    await userActions.type(composerA, "Thread A reply");
    await userActions.click(screen.getByRole("button", { name: "Reply" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(1));

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-b" />
    );
    const composerB = await screen.findByLabelText("Reply in thread");
    await waitFor(() => expect(composerB).toHaveValue("Thread B saved draft"));

    await act(async () => pendingSend.resolve(sentReply));

    expect(composerB).toHaveValue("Thread B saved draft");
    expect(
      loadThreadDraft(
        "tenant-1",
        "user-1",
        "conversation-1",
        rootB.id
      )
    ).toBe("Thread B saved draft");
    expect(
      loadThreadDraft(
        "tenant-1",
        "user-1",
        "conversation-1",
        rootA.id
      )
    ).toBe("");
    expect(screen.queryByText("Sent reply for thread A")).not.toBeInTheDocument();

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );
    await screen.findByText("Thread A root");
    expect(screen.getByLabelText("Reply in thread")).toHaveValue("");
  });

  it("clears the original composer when an A to B to A switch finishes the same send", async () => {
    const rootA = message("root-a", 1, "Thread A root");
    const rootB = message("root-b", 20, "Thread B root");
    const pendingSend = deferred<Message>();
    const onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>(
      () => pendingSend.promise
    );
    const api = apiDouble({
      messageThread: threadLookup(rootA, rootB)
    });
    storeThreadDraft(
      "tenant-1",
      "user-1",
      "conversation-1",
      rootB.id,
      "Thread B saved draft"
    );
    const commonProps = threadSwitchProps(api, onSend);
    const userActions = userEvent.setup();
    const view = render(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );

    await userActions.type(
      await screen.findByLabelText("Reply in thread"),
      "Thread A pending send"
    );
    await userActions.click(screen.getByRole("button", { name: "Reply" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(1));

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-b" />
    );
    await waitFor(() =>
      expect(screen.getByLabelText("Reply in thread"))
        .toHaveValue("Thread B saved draft")
    );
    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );
    const returnedComposerA = await screen.findByLabelText("Reply in thread");
    await waitFor(() =>
      expect(returnedComposerA).toHaveValue("Thread A pending send")
    );

    await act(async () => pendingSend.resolve({
      ...message("reply-a", 2, "Sent reply for thread A"),
      thread_root_message_id: rootA.id
    }));

    await waitFor(() => expect(returnedComposerA).toHaveValue(""));
    expect(
      loadThreadDraft(
        "tenant-1",
        "user-1",
        "conversation-1",
        rootA.id
      )
    ).toBe("");
    expect(
      loadThreadDraft(
        "tenant-1",
        "user-1",
        "conversation-1",
        rootB.id
      )
    ).toBe("Thread B saved draft");
  });

  it("does not surface a late retry failure in a newly selected thread", async () => {
    const rootA = message("root-a", 1, "Thread A root");
    const rootB = message("root-b", 20, "Thread B root");
    const pendingRetry = deferred<Message>();
    const onSend = vi.fn<(input: SendMessageInput) => Promise<Message>>()
      .mockRejectedValueOnce(new Error("temporary disconnect"))
      .mockImplementationOnce(() => pendingRetry.promise);
    const api = apiDouble({
      messageThread: threadLookup(rootA, rootB)
    });
    storeThreadDraft(
      "tenant-1",
      "user-1",
      "conversation-1",
      rootB.id,
      "Keep this B draft"
    );
    const commonProps = threadSwitchProps(api, onSend);
    const userActions = userEvent.setup();
    const view = render(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );

    await userActions.type(
      await screen.findByLabelText("Reply in thread"),
      "Retry thread A"
    );
    await userActions.click(screen.getByRole("button", { name: "Reply" }));
    await screen.findByRole("alert");
    await userActions.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(2));

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-b" />
    );
    const composerB = await screen.findByLabelText("Reply in thread");
    await waitFor(() => expect(composerB).toHaveValue("Keep this B draft"));

    await act(async () => pendingRetry.reject(new Error("old retry failed")));

    expect(composerB).toHaveValue("Keep this B draft");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByText(/old retry failed/i)).not.toBeInTheDocument();
  });

  it("abandons a delayed upload when the user switches threads", async () => {
    const rootA = message("root-a", 1, "Thread A root");
    const rootB = message("root-b", 20, "Thread B root");
    const pendingIntent = deferred<{
      data: Attachment;
      upload: {
        url: string;
        approved_origin: string;
      };
    }>();
    const abandonAttachment = vi.fn().mockResolvedValue(undefined);
    const api = apiDouble({
      messageThread: threadLookup(rootA, rootB),
      createAttachment: vi.fn(() => pendingIntent.promise),
      abandonAttachment,
      completeAttachment: vi.fn()
    });
    storeThreadDraft(
      "tenant-1",
      "user-1",
      "conversation-1",
      rootB.id,
      "Upload-free B draft"
    );
    const commonProps = threadSwitchProps(
      api,
      vi.fn<(input: SendMessageInput) => Promise<Message>>()
        .mockResolvedValue(message("reply", 21, "Reply"))
    );
    const view = render(
      <ThreadDrawer {...commonProps} targetMessageId="target-a" />
    );
    await screen.findByText("Thread A root");

    fireEvent.change(screen.getByLabelText("Attach files to this thread"), {
      target: {
        files: [new File(["content"], "stale.txt", { type: "text/plain" })]
      }
    });
    await waitFor(() => expect(api.createAttachment).toHaveBeenCalledTimes(1));

    view.rerender(
      <ThreadDrawer {...commonProps} targetMessageId="target-b" />
    );
    const composerB = await screen.findByLabelText("Reply in thread");
    await waitFor(() => expect(composerB).toHaveValue("Upload-free B draft"));

    await act(async () => pendingIntent.resolve({
      data: attachment("uploaded"),
      upload: {
        url: "https://objects.example.test/stale-thread-file",
        approved_origin: "https://objects.example.test"
      }
    }));

    await waitFor(() =>
      expect(abandonAttachment).toHaveBeenCalledWith("attachment-1")
    );
    expect(uploadMocks.upload).not.toHaveBeenCalled();
    expect(api.completeAttachment).not.toHaveBeenCalled();
    expect(
      screen.queryByLabelText("Files being attached to this thread")
    ).not.toBeInTheDocument();
    expect(composerB).toHaveValue("Upload-free B draft");
    expect(screen.getByText("Attach")).toBeVisible();
  });
});

function renderDrawer({
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

function threadLookup(rootA: Message, rootB: Message) {
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

function threadSwitchProps(
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

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
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
