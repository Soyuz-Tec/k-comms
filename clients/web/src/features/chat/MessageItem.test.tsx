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

  it("renders safe link and whiteboard reference cards from typed metadata", () => {
    render(
      <MessageItem
        message={{
          ...message,
          attachments: [],
          metadata: {
            links: [{ url: "https://docs.example.test/guide", label: "Team guide" }],
            whiteboard_reference: {
              element_ids: ["element-0001", "element-0002"],
              board_sequence: 17,
              label: "Architecture sketch"
            }
          }
        }}
        currentUserId="user-1"
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

    expect(screen.getByRole("link", { name: /architecture sketch/i })).toHaveAttribute(
      "href",
      "/app/whiteboard?conversation=conversation-1&focus_elements=element-0001%2Celement-0002"
    );
    expect(screen.getByRole("link", { name: /team guide/i })).toHaveAttribute(
      "href",
      "https://docs.example.test/guide"
    );
    expect(screen.getByRole("link", { name: /team guide/i })).toHaveAttribute(
      "rel",
      "noopener noreferrer nofollow"
    );
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
  describe("attachment previews", () => {
    const imageAttachment = {
      id: "attachment-2",
      file_name: "photo.png",
      content_type: "image/png",
      byte_size: 2048,
      status: "ready" as const,
      variant_kinds: ["thumbnail"]
    };

    function renderWith(attachment: Message["attachments"][number], resolver = vi.fn()) {
      render(
        <MessageItem
          message={{ ...message, attachments: [attachment] }}
          currentUserId="user-1"
          seenCount={0}
          focused={false}
          onReaction={vi.fn()}
          onAttachment={vi.fn()}
          onRequestThumbnail={resolver}
          onReply={vi.fn()}
          onEdit={vi.fn()}
          onDelete={vi.fn()}
          onReport={vi.fn()}
        />
      );
      return resolver;
    }

    it("renders a decorative preview once resolved", async () => {
      renderWith(imageAttachment, vi.fn().mockResolvedValue("https://objects.test/thumb.webp"));

      const image = await screen.findByRole("presentation", { hidden: true });
      expect(image).toHaveAttribute("src", "https://objects.test/thumb.webp");
      // The file name and state carry the meaning, so the image is decorative.
      expect(image).toHaveAttribute("alt", "");
      expect(screen.getByText("photo.png")).toBeVisible();
    });

    it("keeps the attachment usable when no preview can be resolved", async () => {
      const resolver = renderWith(imageAttachment, vi.fn().mockResolvedValue(null));

      await waitFor(() => expect(resolver).toHaveBeenCalled());
      expect(screen.queryByRole("presentation", { hidden: true })).not.toBeInTheDocument();
      expect(screen.getByRole("button", { name: /photo\.png/ })).toBeEnabled();
    });

    it("keeps the attachment usable when the resolver rejects", async () => {
      const resolver = renderWith(
        imageAttachment,
        vi.fn().mockRejectedValue(new Error("network"))
      );

      await waitFor(() => expect(resolver).toHaveBeenCalled());
      expect(screen.queryByRole("presentation", { hidden: true })).not.toBeInTheDocument();
      expect(screen.getByRole("button", { name: /photo\.png/ })).toBeEnabled();
    });

    it("does not request a preview for an attachment reporting no variant", () => {
      const resolver = renderWith({ ...imageAttachment, variant_kinds: [] }, vi.fn());

      expect(resolver).not.toHaveBeenCalled();
    });

    it("does not request a preview before the safety scan passes", () => {
      const resolver = renderWith(
        { ...imageAttachment, status: "uploaded" as const },
        vi.fn()
      );

      // A preview is derived from content the scanner has not cleared.
      expect(resolver).not.toHaveBeenCalled();
    });

    it("resolves once when realtime replaces an attachment with equal data", async () => {
      const resolver = vi.fn().mockResolvedValue("https://objects.test/thumb.webp");
      const props = (attachment: Message["attachments"][number]) => ({
        message: { ...message, attachments: [attachment] },
        currentUserId: "user-1",
        seenCount: 0,
        focused: false,
        onReaction: vi.fn(),
        onAttachment: vi.fn(),
        onRequestThumbnail: resolver,
        onReply: vi.fn(),
        onEdit: vi.fn(),
        onDelete: vi.fn(),
        onReport: vi.fn()
      });

      const view = render(<MessageItem {...props(imageAttachment)} />);
      await waitFor(() => expect(resolver).toHaveBeenCalledTimes(1));

      view.rerender(<MessageItem {...props({ ...imageAttachment })} />);
      view.rerender(<MessageItem {...props({ ...imageAttachment })} />);

      await waitFor(() => expect(resolver).toHaveBeenCalledTimes(1));
      expect(resolver).toHaveBeenCalledWith(imageAttachment.id);
    });
  });
});
