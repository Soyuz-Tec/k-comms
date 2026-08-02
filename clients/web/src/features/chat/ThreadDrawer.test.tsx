import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SendMessageInput } from "../../api";
import { loadThreadDraft, storeThreadDraft } from "../../lib/drafts";
import type { Attachment, Message } from "../../types";
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
  attachment,
  deferred,
  message,
  renderDrawer,
  threadLookup,
  threadSwitchProps
} from "./ThreadDrawer.testSupport";

describe("ThreadDrawer composer lifecycle", () => {
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
    await screen.findByRole("alert", {}, { timeout: 3_000 });
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
