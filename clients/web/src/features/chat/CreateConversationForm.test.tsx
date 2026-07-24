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
});
