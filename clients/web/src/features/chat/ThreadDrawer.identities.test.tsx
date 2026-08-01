import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient, SendMessageInput } from "../../api";
import { participantDisambiguator } from "../../lib/participantIdentity";
import type { Message } from "../../types";
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

import {
  apiDouble,
  currentUser,
  deferred,
  membership,
  message,
  mentionedUser,
  renderDrawer,
  user
} from "./ThreadDrawer.testSupport";

describe("ThreadDrawer sender identities and feed isolation", () => {
  beforeEach(() => {
    window.localStorage.clear();
    uploadMocks.sha256.mockClear();
    uploadMocks.upload.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
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
    await waitFor(() =>
      expect(scheduledRefreshes.length).toBeGreaterThanOrEqual(2)
    );
    const loadedThreadRefresh = scheduledRefreshes.at(-1);
    expect(loadedThreadRefresh?.delay).toBe(30_000);

    await act(async () => {
      loadedThreadRefresh?.handler();
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
    await waitFor(() =>
      expect(scheduledRefreshes.length).toBeGreaterThanOrEqual(2)
    );
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

});
