import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
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
  it("keeps group selections while searching and supports removing a selected person", async () => {
    const user = userEvent.setup();
    const alan = { ...teammate, id: "alan", display_name: "Alan Turing" };
    const create = vi.fn().mockResolvedValue(undefined);
    render(<CreateConversationForm users={[teammate, alan]} onCancel={vi.fn()} onCreate={create} onStartDirect={vi.fn()} />);
    await user.selectOptions(screen.getByLabelText("Type"), "group");
    await user.type(screen.getByLabelText("Title"), "Planning");
    const search = screen.getByRole("searchbox", { name: "Find a teammate" });
    await user.type(search, "Grace");
    await user.click(screen.getByRole("checkbox", { name: "Grace Hopper" }));
    await user.clear(search);
    await user.type(search, "Alan");
    await user.click(screen.getByRole("checkbox", { name: "Alan Turing" }));
    expect(within(screen.getByRole("region", { name: "Selected people" })).getByText("2 people selected")).toBeVisible();
    await user.clear(search);
    await user.type(search, "No matching person");
    expect(screen.getByText("No people match this name. Your selections are kept.")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Remove Grace Hopper" }));
    await user.click(screen.getByRole("button", { name: "Create" }));
    expect(create).toHaveBeenCalledWith({ title: "Planning", kind: "group", visibility: "private", member_ids: ["alan"] });
  });

  it("preserves a searched recipient when starting a direct conversation fails", async () => {
    const user = userEvent.setup();
    const startDirect = vi.fn().mockRejectedValue(new Error("Conversation unavailable"));
    render(<CreateConversationForm users={[teammate]} onCancel={vi.fn()} onCreate={vi.fn()} onStartDirect={startDirect} />);
    await user.type(screen.getByRole("searchbox"), "Grace");
    await user.click(screen.getByRole("radio", { name: "Grace Hopper" }));
    await user.click(screen.getByRole("button", { name: "Start message" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Conversation unavailable");
    expect(screen.getByRole("radio", { name: "Grace Hopper" })).toBeChecked();
    expect(screen.getByRole("searchbox")).toHaveValue("Grace");
  });

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

  it("disambiguates duplicate candidates while starting direct chat by user id", async () => {
    const first = { ...teammate, id: "grace-first" };
    const second = {
      ...teammate,
      id: "grace-second",
      display_name: "GRACE HOPPER"
    };
    const duplicateNames = duplicateParticipantNames([first, second]);
    const firstIdentifier = participantIdentifier(first, duplicateNames);
    const secondIdentifier = participantIdentifier(second, duplicateNames);
    const startDirect = vi.fn().mockResolvedValue(undefined);
    const userActions = userEvent.setup();

    render(
      <CreateConversationForm
        users={[first, second]}
        onCancel={vi.fn()}
        onCreate={vi.fn()}
        onStartDirect={startDirect}
      />
    );

    expect(screen.getByText(firstIdentifier)).toBeVisible();
    expect(screen.getByText(secondIdentifier)).toBeVisible();
    await userActions.click(
      screen.getByRole("radio", { name: secondIdentifier })
    );
    await userActions.click(
      screen.getByRole("button", { name: "Start message" })
    );

    expect(startDirect).toHaveBeenCalledWith(second.id);
  });
});
