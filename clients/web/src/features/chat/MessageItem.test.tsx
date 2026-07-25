import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { Message } from "../../types";
import { MessageItem } from "./MessageItem";

const message: Message = {
  id: "message-1",
  tenant_id: "tenant-1",
  conversation_id: "conversation-1",
  sender_user_id: "user-1",
  sender_device_id: "device-1",
  client_message_id: "client-message-1",
  conversation_sequence: 1,
  body: "Quarterly report",
  metadata: {},
  status: "active",
  inserted_at: "2026-07-12T10:00:00Z",
  attachments: [{ id: "attachment-1", file_name: "report.pdf", content_type: "application/pdf", byte_size: 1024, status: "quarantined" }],
  reactions: []
};

describe("MessageItem", () => {
  it("uses the current username as the visible self identifier", () => {
    render(
      <MessageItem
        message={{
          ...message,
          reply_to_message_id: "earlier-message"
        }}
        currentUserId="user-1"
        senderName="Ada · #A1B2C"
        replySenderName="Ada · #A1B2C"
        replyPreview={{
          ...message,
          id: "earlier-message",
          body: "Earlier message"
        }}
        seenCount={0}
        focused={false}
        onReaction={vi.fn()}
        onAttachment={vi.fn()}
        onReply={vi.fn()}
        onEdit={vi.fn()}
        onDelete={vi.fn()}
        onReport={vi.fn()}
      />
    );

    expect(screen.getAllByText("Ada · #A1B2C (you)")).toHaveLength(2);
    expect(screen.queryByText("You")).not.toBeInTheDocument();
  });

  it("renders explicitly resolved sender and reply labels without synthetic users", () => {
    render(
      <MessageItem
        message={{
          ...message,
          sender_user_id: "departed-user",
          reply_to_message_id: "earlier-message"
        }}
        currentUserId="user-1"
        senderName="Departed Guest"
        replySenderName="Earlier Guest"
        replyPreview={{
          ...message,
          id: "earlier-message",
          sender_user_id: "earlier-user",
          body: "Earlier message"
        }}
        seenCount={0}
        focused={false}
        onReaction={vi.fn()}
        onAttachment={vi.fn()}
        onReply={vi.fn()}
        onEdit={vi.fn()}
        onDelete={vi.fn()}
        onReport={vi.fn()}
      />
    );

    expect(screen.getByText("Departed Guest")).toBeVisible();
    expect(screen.getByText("Earlier Guest")).toBeVisible();
  });

  it("blocks quarantined attachments and exposes their safety state", () => {
    render(<MessageItem message={message} currentUserId="user-1" seenCount={0} focused={false} onReaction={vi.fn()} onAttachment={vi.fn()} onReply={vi.fn()} onEdit={vi.fn()} onDelete={vi.fn()} onReport={vi.fn()} />);
    const attachment = screen.getByRole("button", { name: /report\.pdf/i });
    expect(attachment).toBeDisabled();
    expect(screen.getByText(/quarantined/i)).toBeInTheDocument();
  });

  it("confirms message deletion without a native browser prompt and restores focus on cancel", async () => {
    const user = userEvent.setup();
    const onDelete = vi.fn().mockResolvedValue(undefined);
    render(<MessageItem message={message} currentUserId="user-1" seenCount={0} focused={false} onReaction={vi.fn()} onAttachment={vi.fn()} onReply={vi.fn()} onEdit={vi.fn()} onDelete={onDelete} onReport={vi.fn()} />);
    const trigger = screen.getByRole("button", { name: "Delete" });

    await user.click(trigger);
    expect(screen.getByRole("alertdialog", { name: "Delete this message?" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(trigger).toHaveFocus());
    expect(onDelete).not.toHaveBeenCalled();

    await user.click(trigger);
    await user.click(screen.getByRole("button", { name: "Delete message" }));
    await waitFor(() => expect(onDelete).toHaveBeenCalledTimes(1));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
});
