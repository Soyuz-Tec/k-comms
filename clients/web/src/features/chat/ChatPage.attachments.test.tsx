import {
  getChatPageHarness,
  getUploadHarness,
  resetChatPageHarness
} from "./ChatPage.testSupport";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Attachment } from "../../types";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();
const uploadHarness = getUploadHarness();

describe("ChatPage attachment lifecycle", () => {
  beforeEach(resetChatPageHarness);

  it("shows per-file upload status and retries a transient failure without losing the selected file", async () => {
    const user = userEvent.setup();
    const ready = attachment("ready");
    harness.api.createAttachment = vi.fn()
      .mockRejectedValueOnce(
        new Error("Object store is temporarily unavailable")
      )
      .mockResolvedValueOnce({
        data: { ...ready, status: "pending" },
        upload: {
          url: "https://objects.example.test/file",
          approved_origin: "https://objects.example.test"
        }
      });
    harness.api.completeAttachment = vi.fn().mockResolvedValue(ready);

    renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["report"], "report.pdf", {
        type: "application/pdf"
      })
    );

    expect(
      await screen.findByText("Object store is temporarily unavailable")
    ).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Retry" }));

    expect(
      await screen.findByText("Ready to send · Safety scan passed")
    ).toBeVisible();
    expect(harness.api.createAttachment).toHaveBeenCalledTimes(2);
    expect(uploadHarness.upload).toHaveBeenCalledTimes(1);
    expect(harness.api.completeAttachment).toHaveBeenCalledWith(
      "attachment-1",
      expect.any(AbortSignal)
    );
  });

  it("lets a user cancel a queued file before its secure upload is created", async () => {
    const user = userEvent.setup();
    let resolveHash: ((value: string) => void) | undefined;
    uploadHarness.sha256.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveHash = resolve;
      })
    );
    harness.api.createAttachment = vi.fn();

    renderChatPage();
    await screen.findByRole("button", { name: "Start audio call" });
    fireEvent.change(screen.getByLabelText("Attach files"), {
      target: {
        files: [
          new File(["draft"], "draft.txt", { type: "text/plain" })
        ]
      }
    });
    expect(uploadHarness.sha256).toHaveBeenCalledTimes(1);

    await user.click(
      await screen.findByRole("button", {
        name: "Cancel attaching draft.txt"
      })
    );
    resolveHash?.("checksum");
    await act(async () => Promise.resolve());

    expect(screen.queryByText("draft.txt")).not.toBeInTheDocument();
    expect(harness.api.createAttachment).not.toHaveBeenCalled();
  });

  it("abandons an intent that resolves after cancellation without mutating the queue", async () => {
    const user = userEvent.setup();
    let resolveIntent:
      | ((value: {
          data: Attachment;
          upload: { url: string; approved_origin: string };
        }) => void)
      | undefined;
    harness.api.createAttachment = vi.fn().mockReturnValue(
      new Promise((resolve) => {
        resolveIntent = resolve;
      })
    );

    renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["late"], "late.txt", { type: "application/pdf" })
    );
    await waitFor(() =>
      expect(harness.api.createAttachment).toHaveBeenCalledTimes(1)
    );

    await user.click(
      screen.getByRole("button", { name: "Cancel attaching late.txt" })
    );
    expect(screen.queryByText("late.txt")).not.toBeInTheDocument();

    await act(async () => {
      resolveIntent?.({
        data: {
          ...attachment("pending"),
          id: "late-intent",
          file_name: "late.txt"
        },
        upload: {
          url: "https://objects.example.test/late",
          approved_origin: "https://objects.example.test"
        }
      });
      await Promise.resolve();
    });

    await waitFor(() =>
      expect(harness.api.abandonAttachment).toHaveBeenCalledWith(
        "late-intent"
      )
    );
    expect(uploadHarness.upload).not.toHaveBeenCalled();
    expect(screen.queryByText("late.txt")).not.toBeInTheDocument();
  });

  it("aborts and abandons an active upload when the conversation changes", async () => {
    const user = userEvent.setup();
    harness.conversations = [
      ...harness.conversations,
      {
        ...harness.conversations[0]!,
        id: "conversation-2",
        title: "Operations"
      }
    ];
    harness.api.createAttachment = vi.fn().mockResolvedValue({
      data: { ...attachment("pending"), id: "switch-intent" },
      upload: {
        url: "https://objects.example.test/switch",
        approved_origin: "https://objects.example.test"
      }
    });
    let uploadSignal: AbortSignal | undefined;
    uploadHarness.upload.mockImplementationOnce(
      (_descriptor: unknown, _file: File, signal?: AbortSignal) =>
        new Promise<void>((_resolve, reject) => {
          uploadSignal = signal;
          signal?.addEventListener(
            "abort",
            () => reject(new DOMException("cancelled", "AbortError")),
            { once: true }
          );
        })
    );

    renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["switch"], "switch.txt", {
        type: "application/pdf"
      })
    );
    await waitFor(() =>
      expect(uploadHarness.upload).toHaveBeenCalledTimes(1)
    );

    await user.click(
      within(
        screen.getByRole("navigation", {
          name: "Conversation list"
        })
      ).getByRole("button", { name: /Operations/ })
    );

    await waitFor(() => expect(uploadSignal?.aborted).toBe(true));
    await waitFor(() =>
      expect(harness.api.abandonAttachment).toHaveBeenCalledWith(
        "switch-intent"
      )
    );
    expect(screen.queryByText("switch.txt")).not.toBeInTheDocument();
  });

  it("abandons an active upload when the chat unmounts", async () => {
    const user = userEvent.setup();
    harness.api.createAttachment = vi.fn().mockResolvedValue({
      data: { ...attachment("pending"), id: "unmount-intent" },
      upload: {
        url: "https://objects.example.test/unmount",
        approved_origin: "https://objects.example.test"
      }
    });
    uploadHarness.upload.mockImplementationOnce(
      (_descriptor: unknown, _file: File, signal?: AbortSignal) =>
        new Promise<void>((_resolve, reject) => {
          signal?.addEventListener(
            "abort",
            () => reject(new DOMException("cancelled", "AbortError")),
            { once: true }
          );
        })
    );

    const view = renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["unmount"], "unmount.txt", {
        type: "application/pdf"
      })
    );
    await waitFor(() =>
      expect(uploadHarness.upload).toHaveBeenCalledTimes(1)
    );

    view.unmount();

    await waitFor(() =>
      expect(harness.api.abandonAttachment).toHaveBeenCalledWith(
        "unmount-intent"
      )
    );
  });

  it("abandons a failed intent before a one-click retry creates its replacement", async () => {
    const user = userEvent.setup();
    const replacement = {
      ...attachment("ready"),
      id: "replacement-intent"
    };
    harness.api.createAttachment = vi.fn()
      .mockResolvedValueOnce({
        data: { ...attachment("pending"), id: "failed-intent" },
        upload: {
          url: "https://objects.example.test/failed",
          approved_origin: "https://objects.example.test"
        }
      })
      .mockResolvedValueOnce({
        data: { ...replacement, status: "pending" },
        upload: {
          url: "https://objects.example.test/replacement",
          approved_origin: "https://objects.example.test"
        }
      });
    uploadHarness.upload
      .mockRejectedValueOnce(new Error("temporary upload failure"))
      .mockResolvedValueOnce(undefined);
    harness.api.completeAttachment = vi
      .fn()
      .mockResolvedValue(replacement);

    renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["retry"], "retry.txt", {
        type: "application/pdf"
      })
    );
    expect(
      await screen.findByText("temporary upload failure")
    ).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Retry" }));

    await waitFor(() =>
      expect(harness.api.abandonAttachment).toHaveBeenCalledWith(
        "failed-intent"
      )
    );
    expect(
      await screen.findByText("Ready to send · Safety scan passed")
    ).toBeVisible();
    expect(harness.api.createAttachment).toHaveBeenCalledTimes(2);
    expect(
      harness.api.abandonAttachment!.mock.invocationCallOrder[0]
    ).toBeLessThan(
      harness.api.createAttachment.mock.invocationCallOrder[1]!
    );
  });

  it("retains a failed intent and blocks replacement until DELETE is accepted", async () => {
    const user = userEvent.setup();
    const replacement = {
      ...attachment("ready"),
      id: "replacement-after-cleanup"
    };
    harness.api.createAttachment = vi.fn()
      .mockResolvedValueOnce({
        data: {
          ...attachment("pending"),
          id: "cleanup-pending-intent"
        },
        upload: {
          url: "https://objects.example.test/cleanup-pending",
          approved_origin: "https://objects.example.test"
        }
      })
      .mockResolvedValueOnce({
        data: { ...replacement, status: "pending" },
        upload: {
          url: "https://objects.example.test/replacement-after-cleanup",
          approved_origin: "https://objects.example.test"
        }
      });
    uploadHarness.upload
      .mockRejectedValueOnce(new Error("temporary upload failure"))
      .mockResolvedValueOnce(undefined);
    harness.api.completeAttachment = vi
      .fn()
      .mockResolvedValue(replacement);
    harness.api.abandonAttachment = vi.fn()
      .mockRejectedValueOnce(new Error("cleanup offline"))
      .mockRejectedValueOnce(new Error("cleanup offline"))
      .mockRejectedValueOnce(new Error("cleanup offline"))
      .mockResolvedValue(undefined);

    renderChatPage();
    await user.upload(
      screen.getByLabelText("Attach files"),
      new File(["retry"], "cleanup-retry.txt", {
        type: "application/pdf"
      })
    );
    expect(
      await screen.findByText("temporary upload failure")
    ).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Retry" }));

    expect(
      await screen.findByText(
        "The previous secure upload could not be removed. Retry before creating a replacement.",
        {},
        { timeout: 3_000 }
      )
    ).toBeVisible();
    expect(harness.api.abandonAttachment).toHaveBeenCalledTimes(3);
    expect(harness.api.createAttachment).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole("button", { name: "Retry" }));

    expect(
      await screen.findByText("Ready to send · Safety scan passed")
    ).toBeVisible();
    expect(harness.api.abandonAttachment).toHaveBeenCalledTimes(4);
    expect(harness.api.createAttachment).toHaveBeenCalledTimes(2);

    await user.click(
      screen.getByRole("button", {
        name: "Remove cleanup-retry.txt"
      })
    );
    await waitFor(() =>
      expect(
        screen.queryByText("Ready to send · Safety scan passed")
      ).not.toBeInTheDocument()
    );
    expect(harness.api.abandonAttachment).toHaveBeenCalledTimes(5);
  });
});

function renderChatPage() {
  return render(
    <MemoryRouter
      initialEntries={["/app?conversation=conversation-1"]}
    >
      <ChatPage />
    </MemoryRouter>
  );
}

function attachment(status: Attachment["status"]): Attachment {
  return {
    id: "attachment-1",
    file_name: "report.pdf",
    content_type: "application/pdf",
    byte_size: 6,
    status
  };
}
