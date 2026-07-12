import { render, screen } from "@testing-library/react";
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
  it("blocks quarantined attachments and exposes their safety state", () => {
    render(<MessageItem message={message} currentUserId="user-1" seenCount={0} focused={false} onReaction={vi.fn()} onAttachment={vi.fn()} onReply={vi.fn()} onEdit={vi.fn()} onDelete={vi.fn()} onReport={vi.fn()} />);
    const attachment = screen.getByRole("button", { name: /report\.pdf/i });
    expect(attachment).toBeDisabled();
    expect(screen.getByText(/quarantined/i)).toBeInTheDocument();
  });
});
