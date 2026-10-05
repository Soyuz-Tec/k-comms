import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation, DirectoryPerson, PublicChannel } from "../../types";
import { workspaceFixture } from "../member-workspace/memberWorkspace.testSupport";
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
  counterpart_user_id: null,
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
      memberWorkspace: vi.fn(),
      updateMemberWorkspace: vi.fn(),
      updateOnboarding: vi.fn(),
      createConversation: vi.fn(),
      directoryUsers,
      directConversation,
      discoverPublicChannels,
      joinPublicChannel
    },
    setConversations: vi.fn(),
    launchCall: vi.fn(),
    allowAudioCalls: true,
    allowVideoCalls: true,
    audioCallsAvailable: true,
    videoCallsAvailable: true,
    workspaceLoading: false,
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
    audioCallsAvailable: harness.audioCallsAvailable,
    capabilities: {
      allow_audio_calls: harness.allowAudioCalls,
      allow_video_calls: harness.allowVideoCalls,
      allow_public_channels: true
    },
    conversations: [room],
    loading: harness.workspaceLoading,
    setConversations: harness.setConversations,
    videoCallsAvailable: harness.videoCallsAvailable
  })
}));

function LocationProbe() {
  const location = useLocation();
  return <output aria-label="location">{`${location.pathname}${location.search}`}</output>;
}

function renderDirectory(path = "/app/directory") {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <DirectoryPage />
      <LocationProbe />
    </MemoryRouter>
  );
}

describe("DirectoryPage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.api.memberWorkspace.mockResolvedValue(workspaceFixture());
    harness.userRole = "member";
    harness.allowAudioCalls = true;
    harness.allowVideoCalls = true;
    harness.audioCallsAvailable = true;
    harness.videoCallsAvailable = true;
    harness.workspaceLoading = false;
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
        counterpart_user_id: person.id,
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
    expect(within(peopleList).queryByText("Workspace member")).not.toBeInTheDocument();
    expect(within(peopleList).queryByText(/admin/i)).not.toBeInTheDocument();
    expect(harness.directoryUsers).toHaveBeenCalledWith("", 25);

    await user.click(screen.getByRole("button", { name: "Rooms" }));
    await user.click(await screen.findByRole("button", { name: "Message Execution room" }));
    expect(screen.getByLabelText("location")).toHaveTextContent(
      "/app/?conversation=room-1"
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

  it("shows touch-visible guidance when the call provider is unavailable", async () => {
    harness.audioCallsAvailable = false;
    harness.videoCallsAvailable = false;
    renderDirectory();

    await screen.findByRole("list", { name: "People" });
    expect(screen.getByText(
      "Calling is temporarily unavailable. Keep messaging and refresh call availability from Calls."
    )).toBeVisible();
    expect(screen.getByRole("link", { name: "Open Calls" })).toHaveAttribute("href", "/app/calls");
    expect(screen.getByRole("button", { name: "Audio call unavailable for Grace Hopper" }))
      .toHaveAttribute("aria-describedby", "directory-call-availability");
    expect(screen.getByRole("button", { name: "Video call unavailable for Grace Hopper" }))
      .toHaveAttribute("aria-describedby", "directory-call-availability");
  });

  it("announces a checking state without mislabeling disabled calls as unavailable", async () => {
    harness.workspaceLoading = true;
    renderDirectory();

    await screen.findByRole("list", { name: "People" });
    expect(screen.getByText("Checking call availability…")).toBeVisible();
    const audio = screen.getByRole("button", {
      name: "Checking audio call availability for Grace Hopper"
    });
    const video = screen.getByRole("button", {
      name: "Checking video call availability for Grace Hopper"
    });
    expect(audio).toBeDisabled();
    expect(video).toBeDisabled();
    expect(audio).not.toHaveAttribute("aria-describedby");
    expect(video).not.toHaveAttribute("aria-describedby");
    expect(screen.queryByText(/temporarily unavailable/i)).not.toBeInTheDocument();
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
    await waitFor(() => {
      expect(screen.getByLabelText("location")).toHaveTextContent(
        "/app/?conversation=room-public"
      );
    });
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

  it("uses the directory query from a quick-switcher deep link", async () => {
    render(<MemoryRouter initialEntries={["/app/directory?q=Grace"]}><DirectoryPage /><LocationProbe /></MemoryRouter>);
    expect(screen.getByRole("searchbox", { name: "Search people" })).toHaveValue("Grace");
    await screen.findByRole("list", { name: "People" });
    expect(harness.directoryUsers).toHaveBeenCalledWith("Grace", 25);
  });

  it("keeps people visible and retries the failed contact action without reloading search", async () => {
    const success = await harness.directConversation();
    harness.directConversation.mockReset().mockRejectedValueOnce(new Error("Message unavailable")).mockResolvedValue(success);
    const user = userEvent.setup();
    renderDirectory();
    await user.click(await screen.findByRole("button", { name: "Message Grace Hopper" }));
    const list = screen.getByRole("list", { name: "People" });
    const error = within(list).getByRole("alert");
    expect(error).toHaveTextContent("Message unavailable");
    expect(within(list).getByText("Grace Hopper")).toBeVisible();
    await user.click(within(error).getByRole("button", { name: "Retry action for Grace Hopper" }));
    await waitFor(() => expect(screen.getByLabelText("location")).toHaveTextContent("conversation=direct-1"));
    expect(harness.directoryUsers).toHaveBeenCalledTimes(1);
    expect(harness.directConversation).toHaveBeenCalledTimes(2);
  });

  it("keeps the public room list and retries a failed join on its row", async () => {
    const success = await harness.joinPublicChannel();
    harness.joinPublicChannel.mockReset().mockRejectedValueOnce(new Error("Join unavailable")).mockResolvedValue(success);
    const user = userEvent.setup();
    renderDirectory();
    await screen.findByRole("list", { name: "People" });
    await user.click(screen.getByRole("button", { name: "Rooms" }));
    await user.click(await screen.findByRole("button", { name: "Join & open Product launch" }));
    const list = screen.getByRole("list", { name: "Rooms" });
    expect(within(list).getByText("Execution room")).toBeVisible();
    const error = within(list).getByRole("alert");
    await user.click(within(error).getByRole("button", { name: "Retry action for Product launch" }));
    await waitFor(() => expect(screen.getByLabelText("location")).toHaveTextContent("conversation=room-public"));
    expect(harness.discoverPublicChannels).toHaveBeenCalledTimes(1);
    expect(harness.joinPublicChannel).toHaveBeenCalledTimes(2);
  });

  it("retains loaded people and the cursor when pagination fails", async () => {
    harness.directoryUsers.mockReset()
      .mockResolvedValueOnce({ data: [person], page: { next_cursor: "cursor-1" } })
      .mockRejectedValueOnce(new Error("Next page unavailable"))
      .mockResolvedValueOnce({ data: [{ id: "user-next", display_name: "Next teammate" }], page: { next_cursor: null } });
    const user = userEvent.setup();
    renderDirectory();
    await screen.findByRole("list", { name: "People" });
    await user.click(screen.getByRole("button", { name: "Load more people" }));
    expect(screen.getByRole("list", { name: "People" })).toHaveTextContent("Grace Hopper");
    await user.click(await screen.findByRole("button", { name: "Retry loading more people" }));
    await screen.findByText("Next teammate");
    expect(screen.getByRole("list", { name: "People" })).toHaveTextContent("Grace Hopper");
    expect(harness.directoryUsers.mock.calls).toEqual([["", 25], ["", 25, "cursor-1"], ["", 25, "cursor-1"]]);
  });

  it("resets a pending old page when the search changes and ignores its late results", async () => {
    let finishPage: ((page: { data: DirectoryPerson[]; page: { next_cursor: string | null } }) => void) | undefined;
    harness.directoryUsers.mockReset()
      .mockResolvedValueOnce({ data: [person], page: { next_cursor: "old-cursor" } })
      .mockImplementationOnce(() => new Promise((resolve) => { finishPage = resolve; }))
      .mockResolvedValue({ data: [{ id: "new-user", display_name: "New match" }], page: { next_cursor: "new-cursor" } });
    const user = userEvent.setup();
    renderDirectory();
    await screen.findByRole("list", { name: "People" });
    await user.click(screen.getByRole("button", { name: "Load more people" }));
    await user.type(screen.getByRole("searchbox", { name: "Search people" }), "New");
    await screen.findByText("New match");
    expect(screen.getByRole("button", { name: "Load more people" })).toBeEnabled();
    await act(async () => finishPage?.({ data: [{ id: "stale-user", display_name: "Stale teammate" }], page: { next_cursor: null } }));
    expect(screen.queryByText("Stale teammate")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Load more people" })).toBeEnabled();
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


describe("private contact communication", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.userRole = "member";
    harness.allowAudioCalls = true;
    harness.allowVideoCalls = true;
    harness.audioCallsAvailable = true;
    harness.videoCallsAvailable = true;
    harness.workspaceLoading = false;
    harness.api.memberWorkspace.mockReset();
    harness.api.createConversation.mockReset();
    harness.launchCall.mockReturnValue(true);
  });

  const teammate = { id: "user-alan", display_name: "Alan Turing" };
  const privateGroup = { id: "33333333-3333-4333-8333-333333333333", name: "Planning", member_ids: [person.id, teammate.id] };

  it("uses the actual private group conversation response for a selected audio handoff", async () => {
    const user = userEvent.setup();
    const snapshot = workspaceFixture({ version: 4, contacts: [person, teammate], groups: [privateGroup] });
    harness.api.memberWorkspace.mockResolvedValue(snapshot);
    const returned = { ...room, id: "actual-owner-created-conversation", kind: "group" as const, visibility: "private" as const };
    harness.api.createConversation.mockResolvedValue(returned);
    renderDirectory("/app/directory?section=groups");
    await user.click(await screen.findByRole("button", { name: "Audio call selected contacts in Planning" }));
    await waitFor(() => expect(harness.launchCall).toHaveBeenCalledWith(returned, "audio"));
    expect(harness.api.createConversation).toHaveBeenCalledWith({ title: "Planning", kind: "group", visibility: "private", member_ids: [person.id, teammate.id] });
    expect(harness.setConversations).toHaveBeenCalled();
  });

  it("requires explicit review after the saved selection changes and creates no alternate group", async () => {
    const user = userEvent.setup();
    harness.api.memberWorkspace.mockResolvedValueOnce(workspaceFixture({ version: 4, contacts: [person, teammate], groups: [privateGroup] }))
      .mockResolvedValue(workspaceFixture({ version: 5, contacts: [person], groups: [{ ...privateGroup, member_ids: [person.id] }] }));
    renderDirectory("/app/directory?section=groups");
    await user.click(await screen.findByRole("button", { name: "Message selected contacts in Planning" }));
    await screen.findByText(/Contacts changed elsewhere\. Review the current selected people before starting\./);
    expect(harness.api.createConversation).not.toHaveBeenCalled();
    expect(harness.directConversation).not.toHaveBeenCalled();
    expect(harness.launchCall).not.toHaveBeenCalled();
    expect(screen.queryByText("Alan Turing")).not.toBeInTheDocument();
  });

  it("reuses the actual direct conversation for one selected contact and URL navigation", async () => {
    const user = userEvent.setup();
    harness.api.memberWorkspace.mockResolvedValue(workspaceFixture({ version: 4, contacts: [person], groups: [{ ...privateGroup, member_ids: [person.id] }] }));
    harness.directConversation.mockResolvedValue({ data: { ...room, id: "actual-direct-contact", kind: "direct", visibility: "private" }, created: false });
    renderDirectory("/app/directory?section=contacts");
    await user.click(await screen.findByRole("button", { name: "Message Grace Hopper" }));
    await waitFor(() => expect(screen.getByLabelText("location")).toHaveTextContent("/app/?conversation=actual-direct-contact"));
    expect(harness.directConversation).toHaveBeenCalledWith(person.id);
    expect(harness.api.createConversation).not.toHaveBeenCalled();
  });
});
