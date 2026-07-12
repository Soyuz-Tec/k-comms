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
  it("creates a private direct conversation with exactly one teammate", async () => {
    const create = vi.fn().mockResolvedValue(undefined);
    render(<CreateConversationForm users={[teammate]} onCancel={vi.fn()} onCreate={create} />);
    await userEvent.click(screen.getByRole("radio", { name: /Grace Hopper/ }));
    await userEvent.click(screen.getByRole("button", { name: "Start message" }));
    expect(create).toHaveBeenCalledWith({
      title: "Grace Hopper",
      kind: "direct",
      visibility: "private",
      member_ids: ["user-2"]
    });
  });
});
