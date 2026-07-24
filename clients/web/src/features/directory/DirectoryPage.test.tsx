import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation, DirectoryPerson, PublicChannel } from "../../types";
import { DirectoryPage } from "./DirectoryPage";

const person: DirectoryPerson = {
  id: "user-grace",
  display_name: "Grace Hopper"
};

const room: Conversation = {
  id: "room-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Execution room",
  counterpart_display_name: null,
  visibility: "tenant",
  latest_sequence: 4,
  inserted_at: "2026-07-24T00:00:00Z",
  updated_at: "2026-07-24T00:00:00Z"
};

const publicRoom: PublicChannel = {
  ...room,
  id: "room-public",
  title: "Product launch",
  joined: false,
  member_count: 8,
  membership: null
};

const membership = {
  id: "membership-1",
  role: "member" as const,
  joined_at: "2026-07-24T00:00:00Z",
  left_at: null,
  last_read_sequence: 0,
  version: 1
};

const harness = vi.hoisted(() => {
  const directoryUsers = vi.fn();
  const directConversation = vi.fn();
  const discoverPublicChannels = vi.fn();
  const joinPublicChannel = vi.fn();
  return {
    directoryUsers,
    directConversation,
    discoverPublicChannels,
    joinPublicChannel,
    api: {
      directoryUsers,
      directConversation,
      discoverPublicChannels,
      joinPublicChannel
    },
    setConversations: vi.fn(),
    launchCall: vi.fn(),
    userRole: "member" as "member" | "owner"
  };
});

vi.mock("../calls/CallSessionProvider", () => ({
  useCallSession: () => ({
    launchCall: harness.launchCall
  })
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: {
      tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
      user: {
        id: "user-current",
        tenant_id: "tenant-1",
        display_name: "Current User",
        role: harness.userRole,
        status: "active"
      }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    audioCallsAvailable: true,
    capabilities: {
      allow_audio_calls: true,
      allow_video_calls: true,
      allow_public_channels: true
    },
    conversations: [room],
    setConversations: harness.setConversations,
    videoCallsAvailable: true
  })
}));

function LocationProbe() {
  const location = useLocation();
  return <output aria-label="location">{`${location.pathname}${location.search}`}</output>;
}

function renderDirectory() {
  return render(
    <MemoryRouter initialEntries={["/app/directory"]}>
      <DirectoryPage />
      <LocationProbe />
    </MemoryRouter>
  );
}

describe("DirectoryPage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.userRole = "member";
    harness.launchCall.mockReturnValue(true);
    harness.directoryUsers.mockResolvedValue({
      data: [person],
      page: { next_cursor: null }
    });
    harness.discoverPublicChannels.mockResolvedValue({
      data: [publicRoom],
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    harness.directConversation.mockResolvedValue({
      data: {
        ...room,
        id: "direct-1",
        kind: "direct",
        title: null,
        counterpart_display_name: "Grace Hopper",
        visibility: "private"
      },
      created: false
    });
    harness.joinPublicChannel.mockResolvedValue({
      data: {
        conversation: { ...publicRoom },
        membership
      },
      replayed: false
    });
  });

  it("uses the privacy-minimal directory and opens a joined room in one action", async () => {
    const user = userEvent.setup();
    renderDirectory();

    const peopleList = await screen.findByRole("list", { name: "People" });
    expect(within(peopleList).getByText("Grace Hopper")).toBeVisible();
    expect(within(peopleList).getByText("Workspace member")).toBeVisible();
    expect(within(peopleList).queryByText(/admin/i)).not.toBeInTheDocument();
    expect(harness.directoryUsers).toHaveBeenCalledWith("", 25);

    await user.click(screen.getByRole("button", { name: "Rooms" }));
    await user.click(await screen.findByRole("button", { name: "Message Execution room" }));
    expect(screen.getByLabelText("location")).toHaveTextContent(
      "/app?conversation=room-1"
    );
    expect(harness.joinPublicChannel).not.toHaveBeenCalled();
  });

  it("resumes an atomic direct conversation and opens its default-off video lobby", async () => {
    const user = userEvent.setup();
    renderDirectory();

    await user.click(
      await screen.findByRole("button", { name: "Video call Grace Hopper" })
    );

    await waitFor(() =>
      expect(harness.directConversation).toHaveBeenCalledWith("user-grace")
    );
    expect(harness.setConversations).toHaveBeenCalledWith(expect.any(Function));
    expect(harness.launchCall).toHaveBeenCalledWith(
      expect.objectContaining({ id: "direct-1" }),
      "video"
    );
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/directory");
  });

  it("joins and opens a discoverable public room in one action", async () => {
    const user = userEvent.setup();
    renderDirectory();

    await screen.findByRole("list", { name: "People" });
    await user.click(screen.getByRole("button", { name: "Rooms" }));
    await user.click(
      await screen.findByRole("button", { name: "Join & open Product launch" })
    );

    await waitFor(() =>
      expect(harness.joinPublicChannel).toHaveBeenCalledWith("room-public")
    );
    expect(harness.setConversations).toHaveBeenCalledWith(expect.any(Function));
    expect(screen.getByLabelText("location")).toHaveTextContent(
      "/app?conversation=room-public"
    );
  });

  it("keeps the Rooms empty state hidden while a failed load is retryable", async () => {
    harness.discoverPublicChannels
      .mockRejectedValueOnce(new Error("Room directory unavailable"))
      .mockResolvedValue({
        data: [publicRoom],
        page: { limit: 25, has_more: false, next_cursor: null }
      });
    const user = userEvent.setup();
    renderDirectory();

    await screen.findByRole("list", { name: "People" });
    const rooms = screen.getByRole("button", { name: "Rooms" });
    await user.click(rooms);

    const error = await screen.findByRole("alert");
    expect(error).toHaveTextContent("Room directory unavailable");
    expect(within(error).getByRole("button", { name: "Try again" })).toBeEnabled();
    expect(rooms).toHaveAttribute("aria-pressed", "true");
    expect(screen.queryByText("No rooms found")).not.toBeInTheDocument();
    expect(screen.queryByRole("list", { name: "Rooms" })).not.toBeInTheDocument();

    await user.click(within(error).getByRole("button", { name: "Try again" }));

    const roomList = await screen.findByRole("list", { name: "Rooms" });
    expect(within(roomList).getByText("Product launch")).toBeVisible();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(harness.discoverPublicChannels).toHaveBeenCalledTimes(2);
  });

  it("debounces server-side people search and replaces the current page", async () => {
    const user = userEvent.setup();
    renderDirectory();
    await screen.findByRole("list", { name: "People" });

    await user.type(screen.getByRole("searchbox", { name: "Search people" }), "Grace");

    await waitFor(() =>
      expect(harness.directoryUsers).toHaveBeenLastCalledWith("Grace", 25)
    );
  });

  it("gives an empty-workspace owner a direct first-teammate invite action", async () => {
    harness.userRole = "owner";
    harness.directoryUsers.mockResolvedValue({
      data: [],
      page: { next_cursor: null }
    });
    renderDirectory();

    expect(
      await screen.findByRole("link", { name: "Invite your first teammate" })
    ).toHaveAttribute("href", "/admin?section=people#admin-invitations");
  });
});
