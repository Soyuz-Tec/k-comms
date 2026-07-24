import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { User } from "../../types";
import { CreateConversationForm } from "./CreateConversationForm";

const teammate: User = {
  id: "user-2",
  tenant_id: "tenant-1",
  display_name: "Grace Hopper",
  email: "grace@example.test",
  role: "member",
  status: "active"
};

describe("CreateConversationForm", () => {
  it("starts a direct conversation atomically using only the selected teammate id", async () => {
    const create = vi.fn().mockResolvedValue(undefined);
    const startDirect = vi.fn().mockResolvedValue(undefined);
    render(
      <CreateConversationForm
        users={[teammate]}
        onCancel={vi.fn()}
        onCreate={create}
        onStartDirect={startDirect}
      />
    );
    await userEvent.click(screen.getByRole("radio", { name: /Grace Hopper/ }));
    await userEvent.click(screen.getByRole("button", { name: "Start message" }));
    expect(startDirect).toHaveBeenCalledWith("user-2");
    expect(create).not.toHaveBeenCalled();
    expect(screen.queryByText("grace@example.test")).not.toBeInTheDocument();
  });

  it("exposes a supplied first-teammate action when direct messaging has no candidates", () => {
    render(
      <CreateConversationForm
        users={[]}
        emptyDirectAction={<a href="/admin?section=people#admin-invitations">Invite your first teammate</a>}
        onCancel={vi.fn()}
        onCreate={vi.fn()}
        onStartDirect={vi.fn()}
      />
    );

    expect(screen.getByText("Create another account before starting a conversation.")).toBeVisible();
    expect(screen.getByRole("link", { name: "Invite your first teammate" })).toHaveAttribute(
      "href",
      "/admin?section=people#admin-invitations"
    );
  });
});
