import { createRef } from "react";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { Conversation, UserCapabilities } from "../../types";
import { ConversationWorkspaceHeader } from "./ConversationWorkspaceHeader";

vi.mock("../calls/CallSessionProvider", () => ({
  CallLaunchActions: ({ iconOnly }: { iconOnly?: boolean }) => (
    <div data-testid="call-actions" data-icon-only={String(iconOnly)}>
      <button type="button">Start audio call</button>
      <button type="button">Start video call</button>
    </div>
  )
}));

const conversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "direct",
  title: "Team Meeting",
  counterpart_user_id: "user-2",
  counterpart_display_name: "Grace Hopper",
  visibility: "private",
  latest_sequence: 4,
  version: 8,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

describe("ConversationWorkspaceHeader", () => {
  it("groups chat surfaces and room actions without losing accessible names", async () => {
    const user = userEvent.setup();
    const onToggleSearch = vi.fn();
    const onInviteGuest = vi.fn();
    const onToggleActivity = vi.fn();
    const onToggleDetails = vi.fn();
    const onShowConversationList = vi.fn();

    render(
      <MemoryRouter>
        <ConversationWorkspaceHeader
          conversation={conversation}
          title="Team Meeting"
          connectionStatus="live"
          onlineUsers={3}
          capabilities={{
            allow_audio_calls: true,
            allow_video_calls: true,
            allow_public_channels: true,
            message_edit_window_seconds: 900,
            max_attachment_bytes: 10_000_000
          } satisfies UserCapabilities}
          audioCallsAvailable
          videoCallsAvailable
          callGuidance={null}
          mobileBackRef={createRef<HTMLButtonElement>()}
          showSearch={false}
          showActivity={false}
          showDetails={false}
          onShowConversationList={onShowConversationList}
          onToggleSearch={onToggleSearch}
          onInviteGuest={onInviteGuest}
          onToggleActivity={onToggleActivity}
          onToggleDetails={onToggleDetails}
        />
      </MemoryRouter>
    );

    expect(screen.getByRole("heading", { name: "Team Meeting" })).toBeVisible();
    expect(screen.getByText("Direct message")).toBeVisible();
    expect(screen.getByText("private")).toBeVisible();
    expect(screen.getByText("Connected")).toBeVisible();
    expect(screen.getByText("3 online")).toBeVisible();

    const workspace = screen.getByRole("navigation", {
      name: "Conversation workspace"
    });
    const workspaceQueries = within(workspace);
    expect(workspaceQueries.getByRole("link", { name: "Chat" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(workspaceQueries.getByRole("link", { name: "Chat" })).toHaveAttribute(
      "href",
      "/app/?conversation=conversation-1"
    );
    expect(workspaceQueries.getByRole("link", { name: "Canvas" })).toHaveAttribute(
      "href",
      "/app/whiteboard?conversation=conversation-1"
    );
    expect(screen.getByTestId("call-actions")).toHaveAttribute(
      "data-icon-only",
      "true"
    );

    await user.click(screen.getByRole("button", { name: "Search messages" }));
    await user.click(screen.getByRole("button", { name: "Invite guest" }));
    const activity = screen.getByRole("button", { name: "Activity" });
    const details = screen.getByRole("button", { name: "Details" });
    expect(activity).toHaveAttribute("aria-controls", "conversation-activity-panel");
    expect(details).toHaveAttribute("aria-controls", "conversation-details-panel");
    await user.click(activity);
    await user.click(details);
    await user.click(
      screen.getByRole("button", { name: "Back to conversations" })
    );

    expect(onToggleSearch).toHaveBeenCalledOnce();
    expect(onInviteGuest).toHaveBeenCalledOnce();
    expect(onToggleActivity).toHaveBeenCalledOnce();
    expect(onToggleDetails).toHaveBeenCalledOnce();
    expect(onShowConversationList).toHaveBeenCalledOnce();
  });
});
