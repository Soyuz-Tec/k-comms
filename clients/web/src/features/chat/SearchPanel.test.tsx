import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Conversation, Message, User } from "../../types";
import { SearchPanel } from "./SearchPanel";

const conversations: Conversation[] = [
  { id: "general", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 2, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" },
  { id: "projects", tenant_id: "tenant-1", kind: "group", title: "Projects", visibility: "private", latest_sequence: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }
];

const users: User[] = [
  { id: "ada", tenant_id: "tenant-1", display_name: "Ada", role: "member", status: "active" },
  { id: "grace", tenant_id: "tenant-1", display_name: "Grace", role: "member", status: "active" }
];

function result(id: string, conversationId: string, senderId: string, body: string, insertedAt = new Date().toISOString()): Message {
  return {
    id,
    tenant_id: "tenant-1",
    conversation_id: conversationId,
    sender_user_id: senderId,
    sender_device_id: "device-1",
    client_message_id: `client-${id}`,
    conversation_sequence: 1,
    body,
    metadata: {},
    status: "active",
    inserted_at: insertedAt,
    attachments: [],
    reactions: []
  };
}

function Harness() {
  const [open, setOpen] = useState(false);
  return <><button type="button" onClick={() => setOpen(true)}>Open search</button>{open && <SearchPanel api={{} as ApiClient} conversations={[]} users={[]} onClose={() => setOpen(false)} onSelect={() => undefined} />}</>;
}

describe("SearchPanel accessibility", () => {
  it("closes on Escape and restores focus to its trigger", async () => {
    const user = userEvent.setup();
    render(<Harness />);
    const trigger = screen.getByRole("button", { name: "Open search" });
    await user.click(trigger);
    expect(screen.getByRole("dialog", { name: "Search messages" })).toBeVisible();
    expect(screen.getByRole("searchbox")).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    expect(trigger).toHaveFocus();
  });

  it("refines authorized results locally and supports arrow-key result navigation", async () => {
    const user = userEvent.setup();
    const onSelect = vi.fn();
    const searchMessages = vi.fn().mockResolvedValue([
      result("one", "general", "ada", "First result"),
      result("two", "projects", "grace", "Second result"),
      result("three", "general", "ada", "Old result", "2020-01-01T00:00:00Z")
    ]);
    const api = { searchMessages } as unknown as ApiClient;

    render(<SearchPanel api={api} conversations={conversations} users={users} onClose={() => undefined} onSelect={onSelect} />);
    await user.type(screen.getByRole("searchbox"), "roadmap");
    await user.click(screen.getByRole("button", { name: "Search" }));

    await waitFor(() => expect(searchMessages).toHaveBeenCalledWith("roadmap"));
    expect(screen.getByRole("status")).toHaveTextContent("3 results shown");

    const firstButton = screen.getByText("First result").closest("button");
    const secondButton = screen.getByText("Second result").closest("button");
    expect(firstButton).not.toBeNull();
    expect(secondButton).not.toBeNull();
    firstButton?.focus();
    await user.keyboard("{ArrowDown}");
    expect(secondButton).toHaveFocus();
    await user.keyboard("{Enter}");
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ id: "two" }));

    await user.selectOptions(screen.getByLabelText("Conversation"), "general");
    expect(screen.queryByText("Second result")).not.toBeInTheDocument();
    expect(screen.getByText("First result")).toBeVisible();

    await user.selectOptions(screen.getByLabelText("Date"), "day");
    expect(screen.queryByText("Old result")).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("1 result shown");
  });
});
