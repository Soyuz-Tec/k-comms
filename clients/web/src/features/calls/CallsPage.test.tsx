import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CallSummary, Conversation, User } from "../../types";
import { CallsPage } from "./CallsPage";

const conversationId = "11111111-1111-4111-8111-111111111111";

const conversation: Conversation = {
  id: conversationId,
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Execution room",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "tenant",
  latest_sequence: 7,
  inserted_at: "2026-07-20T09:00:00Z",
  updated_at: "2026-07-24T09:00:00Z"
};

const starter: User = {
  id: "user-2",
  tenant_id: "tenant-1",
  display_name: "Grace Hopper",
  role: "member",
  status: "active"
};

const activeCall: CallSummary = {
  id: "call-1",
  conversation_id: conversationId,
  started_by_user_id: starter.id,
  ended_by_user_id: null,
  media_kind: "video",
  status: "active",
  started_at: "2026-07-24T10:00:00Z",
  expires_at: "2026-07-24T11:00:00Z",
  ended_at: null,
  end_reason: null,
  duration_seconds: 272,
  can_end: false
};

const harness = vi.hoisted(() => {
  const calls = vi.fn();
  return {
    calls,
    launchCall: vi.fn(),
    refreshCallAvailability: vi.fn(),
    api: { calls },
    audioCallsAvailable: true,
    videoCallsAvailable: true,
    workspaceLoading: false,
    hasSidebarNavigation: false,
    capabilities: {
      allow_audio_calls: true,
      allow_video_calls: true,
      allow_public_channels: true,
      message_edit_window_seconds: 900,
      max_attachment_bytes: 25_000_000
    }
  };
});

vi.mock("./CallSessionProvider", () => ({
  CallLaunchButton: ({
    children,
    className,
    conversation: target,
    kind,
    ariaLabel,
    disabled
  }: {
    children: ReactNode;
    className?: string;
    conversation: Conversation;
    kind: "audio" | "video";
    ariaLabel?: string;
    disabled?: boolean;
  }) => (
    <button
      className={className}
      type="button"
      aria-label={ariaLabel}
      disabled={disabled}
      onClick={() => harness.launchCall(target, kind)}
    >
      {children}
    </button>
  )
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: {
      user: { id: "user-1" }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    conversations: [conversation],
    users: [starter],
    capabilities: harness.capabilities,
    audioCallsAvailable: harness.audioCallsAvailable,
    videoCallsAvailable: harness.videoCallsAvailable,
    loading: harness.workspaceLoading,
    refreshCallAvailability: harness.refreshCallAvailability
  })
}));

vi.mock("../../app/ContextualNavigation", () => ({
  useContextualNavigation: () => ({ hasSidebarNavigation: harness.hasSidebarNavigation })
}));

describe("CallsPage", () => {
  beforeEach(() => {
    harness.calls.mockReset().mockResolvedValue({
      data: [activeCall],
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    harness.launchCall.mockReset();
    harness.refreshCallAvailability.mockReset().mockResolvedValue(undefined);
    harness.audioCallsAvailable = true;
    harness.videoCallsAvailable = true;
    harness.workspaceLoading = false;
    harness.hasSidebarNavigation = false;
    harness.capabilities.allow_audio_calls = true;
    harness.capabilities.allow_video_calls = true;
  });

  it("shows truthful room-session state and one-click conversation lobby links", async () => {
    render(<MemoryRouter initialEntries={["/app/calls"]}><CallsPage /></MemoryRouter>);

    const row = (await screen.findByRole("button", {
      name: "Join video call for Execution room"
    })).closest("li");
    expect(row).not.toBeNull();
    expect(within(row as HTMLElement).getByText("Video")).toBeVisible();
    expect(within(row as HTMLElement).getByText("4m 32s room duration")).toBeVisible();
    expect(within(row as HTMLElement).getByRole("link", { name: "Open chat for Execution room" })).toHaveAttribute(
      "href",
      `/app/?conversation=${conversationId}`
    );
    const user = userEvent.setup();
    await user.click(within(row as HTMLElement).getByRole("button", { name: "Join video call for Execution room" }));
    expect(harness.launchCall).toHaveBeenCalledWith(conversation, "video");
    const launcher = screen.getByRole("region", { name: "Start a call" });
    expect(screen.getByRole("heading", { name: "Calls", level: 1 })).toBeVisible();
    expect(screen.queryByText("Room lifecycle")).not.toBeInTheDocument();
    expect(screen.queryByText("Workspace communication")).not.toBeInTheDocument();
    await user.click(within(launcher).getByRole("button", { name: "Audio call Execution room" }));
    expect(harness.launchCall).toHaveBeenCalledWith(conversation, "audio");
    expect(screen.queryByText(/missed|declined|scheduled/i)).not.toBeInTheDocument();
  });

  /*
   * The screen used to carry a second "Quick contacts" column beside the
   * launcher. Both listed unarchived conversations most-recent-first and both
   * offered message, audio and video on every row; the only difference was
   * that the panel floated direct messages up and cut the list at five. The
   * shortcuts it provided now have to hold in the launcher, which is what this
   * checks.
   */
  it("offers truthful conversation shortcuts from the call launcher", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/calls"]}><CallsPage /></MemoryRouter>);

    await screen.findByText("Active room");
    expect(screen.queryByRole("complementary", { name: "Quick contacts" })).not.toBeInTheDocument();

    const launcher = screen.getByRole("region", { name: "Start a call" });
    expect(within(launcher).getByText("Execution room")).toBeVisible();
    expect(within(launcher).getByRole("link", { name: "Message Execution room" })).toHaveAttribute(
      "href",
      `/app/?conversation=${conversationId}`
    );
    expect(within(launcher).getByRole("link", { name: "Browse directory" })).toHaveAttribute(
      "href",
      "/app/directory"
    );
    expect(screen.queryByRole("link", { name: "View contacts" })).not.toBeInTheDocument();

    await user.click(within(launcher).getByRole("button", { name: "Audio call Execution room" }));
    expect(harness.launchCall).toHaveBeenCalledWith(conversation, "audio");
  });

  it("keeps empty mobile history compact and opens the launcher with keyboard focus", async () => {
    harness.calls.mockResolvedValue({
      data: [],
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    await screen.findByText("No active call rooms");
    expect(document.querySelector(".calls-new-call-toggle")).toHaveAttribute("aria-expanded", "false");
    const callTypes = screen.getByRole("navigation", { name: "Call types" });
    expect(callTypes).toBeVisible();
    expect(within(callTypes).getByRole("link", { name: "Internet calls" })).toHaveAttribute("aria-current", "page");
    expect(within(callTypes).getByRole("link", { name: "Phone" })).toHaveAttribute("href", "/app/calls/phone");
    expect(within(callTypes).getAllByRole("link")).toHaveLength(2);
    const related = screen.getByRole("navigation", { name: "Related calling destinations" });
    expect(within(related).getByText("Related")).toBeVisible();
    expect(within(related).getByRole("link", { name: "Calendar" })).toHaveAttribute("href", "/app/meetings");
    expect(within(related).getByRole("link", { name: "Recordings" })).toHaveAttribute("href", "/app/artifacts");
    fireEvent.click(screen.getByRole("button", { name: "Start call" }));
    expect(screen.getByRole("searchbox", { name: "Find a conversation to call" })).toHaveFocus();
    const hideLauncher = screen.getByText("Hide call launcher").closest("button");
    expect(hideLauncher).not.toBeNull();
    expect(hideLauncher).toHaveAttribute("aria-expanded", "true");
    fireEvent.click(hideLauncher as HTMLButtonElement);
    expect(document.querySelector(".calls-new-call-toggle")).toHaveAttribute(
      "aria-expanded",
      "false"
    );
  });

  it("keeps call types visible with a sidebar and restores related destinations without one", async () => {
    harness.hasSidebarNavigation = true;
    const view = render(<MemoryRouter><CallsPage /></MemoryRouter>);
    await screen.findByText("Active room");
    expect(screen.getByRole("navigation", { name: "Call types" })).toBeVisible();
    expect(screen.queryByRole("navigation", { name: "Related calling destinations" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Browse directory" })).toHaveAttribute("href", "/app/directory");

    harness.hasSidebarNavigation = false;
    view.rerender(<MemoryRouter><CallsPage /></MemoryRouter>);
    expect(screen.getByRole("navigation", { name: "Call types" })).toBeVisible();
    expect(screen.getByRole("navigation", { name: "Related calling destinations" })).toBeVisible();
    expect(screen.getByRole("link", { name: "Phone" })).toHaveAttribute("href", "/app/calls/phone");
  });

  it("opens the member Phone page without launching an internet call", async () => {
    harness.hasSidebarNavigation = true;
    render(<MemoryRouter initialEntries={["/app/calls"]}>
      <Routes>
        <Route path="/app/calls" element={<CallsPage />} />
        <Route path="/app/calls/phone" element={<h1>Member phone destination</h1>} />
      </Routes>
    </MemoryRouter>);
    await screen.findByText("Active room");

    const phoneLink = within(screen.getByRole("navigation", { name: "Call types" })).getByRole("link", { name: "Phone" });
    expect(phoneLink).not.toHaveAttribute("aria-current");
    await userEvent.setup().click(phoneLink);

    expect(screen.getByRole("heading", { name: "Member phone destination" })).toBeVisible();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("keeps starter attribution when a different member ended the room", async () => {
    harness.calls.mockResolvedValue({
      data: [{ ...activeCall, status: "ended", ended_by_user_id: "user-3", ended_at: "2026-07-24T10:05:00Z" }],
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    const row = (await screen.findByRole("button", { name: "Start video call for Execution room" })).closest("li") as HTMLElement;
    expect(within(row).getByText("Started by Grace Hopper")).toBeVisible();
    expect(within(row).queryByText("Ended by Grace Hopper")).not.toBeInTheDocument();
    expect(row.querySelector("time")).toHaveAttribute("dateTime", "2026-07-24T10:05:00Z");
  });

  it("takes Join active call to current rooms without starting a new call", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><CallsPage /></MemoryRouter>);
    await screen.findByText("Active room");
    await user.click(screen.getByRole("button", { name: "Recent" }));
    await user.click(screen.getByRole("button", { name: "Join active call" }));

    await waitFor(() => expect(harness.calls).toHaveBeenLastCalledWith({
      scope: "active", media_kind: undefined, limit: 25, cursor: undefined
    }));
    expect(screen.getByRole("region", { name: "Call history" })).toHaveFocus();
    expect(harness.launchCall).not.toHaveBeenCalled();
  });

  it("sends accessible state, modality, and cursor filters to the stable query", async () => {
    const user = userEvent.setup();
    harness.calls
      .mockResolvedValueOnce({ data: [activeCall], page: { limit: 25, has_more: false, next_cursor: null } })
      .mockResolvedValue({ data: [], page: { limit: 25, has_more: false, next_cursor: null } });

    render(<MemoryRouter><CallsPage /></MemoryRouter>);
    await screen.findByRole("button", { name: "Join video call for Execution room" });

    await user.click(screen.getByRole("button", { name: "Recent" }));
    await user.selectOptions(screen.getByLabelText("Media"), "audio");

    await waitFor(() => expect(harness.calls).toHaveBeenLastCalledWith({
      scope: "recent",
      media_kind: "audio",
      limit: 25,
      cursor: undefined
    }));
    expect(screen.getByRole("button", { name: "Recent" })).toHaveAttribute("aria-pressed", "true");
  });

  it("keeps a failed load recoverable with a visible retry", async () => {
    const user = userEvent.setup();
    harness.calls
      .mockRejectedValueOnce(new Error("Calls are temporarily unavailable"))
      .mockResolvedValueOnce({ data: [], page: { limit: 25, has_more: false, next_cursor: null } });

    render(<MemoryRouter><CallsPage /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("Calls are temporarily unavailable");

    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("No active call rooms")).toBeVisible();
    expect(harness.calls).toHaveBeenCalledTimes(2);
  });

  it("refreshes both call sessions and current call availability", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><CallsPage /></MemoryRouter>);
    await screen.findByRole("button", { name: "Join video call for Execution room" });

    await user.click(screen.getByRole("button", { name: "Refresh calls" }));

    await waitFor(() => {
      expect(harness.calls).toHaveBeenCalledTimes(2);
      expect(harness.refreshCallAvailability).toHaveBeenCalledTimes(1);
    });
  });

  it("explains policy-disabled calling and disables history launch actions", async () => {
    harness.capabilities.allow_audio_calls = false;
    harness.capabilities.allow_video_calls = false;

    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    expect(await screen.findByText(/Calling is disabled by workspace policy/)).toBeVisible();
    expect(screen.getByRole("button", {
      name: "Join video call for Execution room (unavailable)"
    })).toBeDisabled();
    expect(screen.getByRole("link", { name: "Phone" })).toHaveAttribute("href", "/app/calls/phone");
  });

  it("explains runtime-unavailable calling and disables the affected history action", async () => {
    harness.videoCallsAvailable = false;

    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    expect(await screen.findByText(/Video calling is temporarily unavailable/)).toBeVisible();
    expect(screen.getByRole("button", {
      name: "Join video call for Execution room (unavailable)"
    })).toBeDisabled();
  });

  it("shows a distinct availability check and keeps history launch actions disabled while loading", async () => {
    harness.workspaceLoading = true;

    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    expect(await screen.findByText("Checking call availability…")).toBeVisible();
    expect(screen.getByRole("button", {
      name: "Join video call for Execution room (checking availability)"
    })).toBeDisabled();
    expect(screen.queryByText(/temporarily unavailable/i)).not.toBeInTheDocument();
  });

  it("uses a Start label for ended room actions", async () => {
    harness.calls.mockResolvedValue({
      data: [{
        ...activeCall,
        id: "call-ended",
        media_kind: "audio",
        status: "ended",
        ended_at: "2026-07-24T10:04:32Z"
      }],
      page: { limit: 25, has_more: false, next_cursor: null }
    });

    render(<MemoryRouter><CallsPage /></MemoryRouter>);

    const row = (await screen.findByRole("button", {
      name: "Start audio call for Execution room"
    })).closest("li");
    expect(row).not.toBeNull();
    expect(within(row as HTMLElement).getByRole("button", {
      name: "Start audio call for Execution room"
    })).toHaveTextContent("Start audio");
  });
});
