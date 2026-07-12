import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ConversationMembership, User } from "../../types";
import { MentionPicker } from "./MentionPicker";

function membership(user: User): ConversationMembership {
  return {
    id: `membership-${user.id}`,
    role: "member",
    joined_at: "2026-07-12T12:00:00Z",
    last_read_sequence: 0,
    user
  };
}

function user(id: string, displayName: string, accountType: "human" | "service" = "human"): User {
  return {
    id,
    tenant_id: "tenant-1",
    display_name: displayName,
    account_type: accountType,
    role: "member",
    status: "active"
  };
}

describe("MentionPicker", () => {
  it("offers only active human conversation members other than the sender", async () => {
    const changed = vi.fn();
    const members = [
      membership(user("current", "Current user")),
      membership(user("human", "Human member")),
      membership(user("service", "Release bot", "service")),
      membership({ ...user("inactive", "Inactive member"), status: "suspended" })
    ];
    const userActions = userEvent.setup();

    render(
      <MentionPicker
        members={members}
        currentUserId="current"
        selectedUserIds={[]}
        onChange={changed}
      />
    );

    await userActions.click(screen.getByRole("button", { name: "Mention" }));
    expect(screen.getByText("Human member")).toBeInTheDocument();
    expect(screen.queryByText("Current user")).not.toBeInTheDocument();
    expect(screen.queryByText("Release bot")).not.toBeInTheDocument();
    expect(screen.queryByText("Inactive member")).not.toBeInTheDocument();

    await userActions.click(screen.getByRole("checkbox", { name: "Human member" }));
    expect(changed).toHaveBeenCalledWith(["human"]);
  });
});
