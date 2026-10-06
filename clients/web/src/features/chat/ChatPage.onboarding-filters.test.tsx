import {
  getChatPageHarness,
  LocationProbe,
  resetChatPageHarness
} from "./ChatPage.testSupport";
import {
  fireEvent,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation } from "../../types";
import { participantDisambiguator } from "../../lib/participantIdentity";
import { ChatPage } from "./ChatPage";
import { workspaceFixture } from "../member-workspace/memberWorkspace.testSupport";

const harness = getChatPageHarness();

describe("ChatPage durable sequence recovery", () => {
  beforeEach(resetChatPageHarness);

  it("offers explicit browser setup and synchronizes skipping the guide", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);
    const welcome = await screen.findByRole("region", { name: "Start your first conversation" });
    expect(within(welcome).getByRole("link", { name: "Check audio & video" })).toHaveAttribute("href", "/app/you?section=audio-video");
    expect(within(welcome).getByRole("link", { name: "Set up notifications" })).toHaveAttribute("href", "/app/you?section=notifications");
    await user.click(within(welcome).getByRole("button", { name: "Skip for now" }));
    await waitFor(() => expect(screen.queryByRole("link", { name: "Check audio & video" })).not.toBeInTheDocument());
    expect(harness.api.updateOnboarding).toHaveBeenCalledWith({ version: 1, action: "dismiss" });
    expect(window.localStorage.getItem("k-comms:onboarding:tenant-1:user-1")).toBeNull();
  });

  it("opens global content search from the Go To route and clears the hint on close", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/?search=content"]}><ChatPage /><LocationProbe /></MemoryRouter>);
    const dialog = await screen.findByRole("dialog", { name: "Search workspace" });
    expect(within(dialog).getByLabelText("Conversation")).toHaveValue("");
    await user.click(within(dialog).getByRole("button", { name: "Close workspace search" }));
    expect(screen.queryByRole("dialog", { name: "Search workspace" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("location-search")).not.toHaveTextContent("search=content");
  });

  it("keeps title filtering distinct from global search and scopes the header search to the conversation", async () => {
    const user = userEvent.setup();
    window.localStorage.setItem("k-comms:onboarding:tenant-1:user-1", "dismissed");
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    expect(screen.getByRole("searchbox", { name: "Filter conversation titles" })).toBeVisible();
    await user.type(screen.getByRole("searchbox", { name: "Filter conversation titles" }), "General");
    expect(harness.api.unifiedSearch).not.toHaveBeenCalled();
    await user.click(within(screen.getByLabelText("Conversations")).getByRole("button", { name: "Search workspace content" }));
    let search = screen.getByRole("dialog", { name: "Search workspace" });
    expect(within(search).getByLabelText("Conversation")).toHaveValue("");
    await user.type(within(search).getByRole("searchbox"), "roadmap");
    await user.click(within(search).getByRole("button", { name: "Search" }));
    await waitFor(() => expect(harness.api.unifiedSearch).toHaveBeenLastCalledWith("roadmap", expect.objectContaining({ conversation_id: undefined, kind: "all" })));
    await user.click(screen.getByRole("button", { name: "Close workspace search" }));
    await user.click(screen.getByRole("button", { name: "Search messages" }));
    search = screen.getByRole("dialog", { name: "Search workspace" });
    expect(within(search).getByLabelText("Conversation")).toHaveValue("conversation-1");
    await user.type(within(search).getByRole("searchbox"), "roadmap");
    await user.click(within(search).getByRole("button", { name: "Search" }));
    await waitFor(() => expect(harness.api.unifiedSearch).toHaveBeenLastCalledWith("roadmap", expect.objectContaining({ conversation_id: "conversation-1" })));
  });

  it("focuses the attachment control from Files without opening a file picker", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/?conversation=conversation-1&compose=attachment"]}><ChatPage /><LocationProbe /></MemoryRouter>);
    const attachmentInput = screen.getByLabelText("Attach files");
    const clicked = vi.fn();
    attachmentInput.addEventListener("click", clicked);
    await waitFor(() => expect(screen.getByRole("button", { name: "Choose files to attach" })).toHaveFocus());
    expect(clicked).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.getByLabelText("location-search")).not.toHaveTextContent("compose=attachment"));
    await user.keyboard("{Enter}");
    expect(clicked).toHaveBeenCalledTimes(1);
  });

  it("provides usable first actions when the workspace has no conversations", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    harness.api.memberWorkspace!.mockResolvedValue(workspaceFixture({ onboarding: {
      dismissed_at: "2026-10-05T00:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: true
    } }));
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    await waitFor(() => expect(harness.api.memberWorkspace).toHaveBeenCalled());
    await user.click(screen.getByRole("button", { name: "Start a conversation" }));
    expect(screen.getByRole("heading", { name: "New conversation" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    const browseActions = screen.getAllByRole("button", { name: "Browse channels" });
    await user.click(browseActions.at(-1)!);
    expect(await screen.findByRole("dialog", { name: "Browse channels" })).toBeVisible();
  });

  /*
   * Browsing channels used to sit in the inbox heading. Moving it beside the
   * scope chips briefly tied it to the chips" + String.fromCharCode(39) + " own render condition, so it vanished
   * on an empty inbox -- the moment it is most useful. The scope row renders
   * whether or not there is anything to scope.
   */
  it("keeps the channel browser reachable from the filter row with no conversations", () => {
    harness.conversations = [];
    window.localStorage.setItem("k-comms:onboarding:tenant-1:user-1", "dismissed");
    const { container } = render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    const filterRow = container.querySelector(".conversation-filters");
    expect(filterRow).not.toBeNull();
    expect(filterRow!.querySelector(".inbox-filter-trigger")).not.toBeNull();
    expect(filterRow!.querySelector(".inbox-segments")).toBeNull();
  });

  it("starts or resumes a direct conversation from onboarding in one action without exposing email", async () => {
    const user = userEvent.setup();
    const direct: Conversation = {
      id: "direct-1",
      tenant_id: "tenant-1",
      kind: "direct",
      title: null,
      counterpart_user_id: "user-2",
      counterpart_display_name: "Grace",
      visibility: "private",
      latest_sequence: 0,
      version: 1,
      inserted_at: "2026-07-24T00:00:00Z",
      updated_at: "2026-07-24T00:00:00Z"
    };
    let resolveDirect!: (conversation: Conversation) => void;
    const pendingDirect = new Promise<Conversation>((resolve) => {
      resolveDirect = resolve;
    });
    harness.conversations = [];
    harness.startDirectConversation.mockReturnValue(pendingDirect);

    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(screen.queryByText("grace@example.test")).not.toBeInTheDocument();
    await user.click(await screen.findByRole("button", { name: "Message Grace" }));
    const opening = await screen.findByRole("button", { name: "Opening Grace…" });
    expect(opening).toBeDisabled();
    expect(opening).toHaveAttribute("aria-busy", "true");
    fireEvent.click(opening);
    expect(harness.startDirectConversation).toHaveBeenCalledTimes(1);

    harness.conversations = [direct];
    resolveDirect(direct);
    await waitFor(() => expect(harness.startDirectConversation).toHaveBeenCalledWith("user-2"));
    expect(harness.createConversation).not.toHaveBeenCalled();
    await waitFor(() => {
      expect(screen.getByLabelText("location-search")).toHaveTextContent(
        "?conversation=direct-1"
      );
      expect(screen.getByLabelText("Message")).toHaveFocus();
    });
  });

  it("disambiguates duplicate usernames in onboarding without exposing internal IDs", async () => {
    harness.conversations = [];
    harness.users = [
      harness.users[0]!,
      { ...harness.users[1]!, id: "grace-one", display_name: "Grace" },
      { ...harness.users[1]!, id: "grace-two", display_name: " grace " }
    ];

    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    expect(
      await screen.findByRole("button", {
        name: `Message Grace · #${participantDisambiguator("grace-one")}`
      })
    ).toBeVisible();
    expect(
      screen.getByRole("button", {
        name: `Message grace · #${participantDisambiguator("grace-two")}`
      })
    ).toBeVisible();
    expect(screen.queryByText(/grace-(one|two)/)).not.toBeInTheDocument();
    expect(screen.queryByText("grace@example.test")).not.toBeInTheDocument();
  });

  it("shows the next useful action and synchronizes dismissal without local authority", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("heading", { name: "Start your first conversation" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Message Grace" })).toBeVisible();
    expect(screen.queryByText("Choose notification preferences")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Start a conversation" })).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Dismiss welcome guide" }));
    await waitFor(() => expect(screen.queryByRole("heading", { name: "Start your first conversation" })).not.toBeInTheDocument());
    expect(harness.api.updateOnboarding).toHaveBeenCalledWith({ version: 1, action: "dismiss" });
    expect(window.localStorage.getItem("k-comms:onboarding:tenant-1:user-1")).toBeNull();
  });

  it("routes an owner with only the bootstrap room directly to one invitation action", async () => {
    const user = userEvent.setup();
    harness.userRole = "owner";
    harness.users = [harness.users[0]!];
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <Routes>
          <Route path="/app" element={<><ChatPage /><LocationProbe /></>} />
          <Route path="/admin" element={<LocationProbe />} />
        </Routes>
      </MemoryRouter>
    );

    const firstTeammate = await screen.findByRole("link", { name: "Invite your first teammate" });
    expect(firstTeammate).toHaveAttribute("href", "/admin?section=people#admin-invitations");
    expect(screen.getAllByRole("link", { name: "Invite your first teammate" })).toHaveLength(1);

    await user.click(firstTeammate);
    await waitFor(() => {
      expect(screen.getByLabelText("location-search")).toHaveTextContent(
        "?section=people#admin-invitations"
      );
    });
  });

  it("routes an owner with an inactive teammate to access management instead of a duplicate invitation", async () => {
    harness.userRole = "owner";
    harness.users = [
      harness.users[0]!,
      { ...harness.users[1]!, status: "suspended" }
    ];
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
      </MemoryRouter>
    );

    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    expect(screen.getByRole("heading", { name: "Reconnect your teammate" })).toBeVisible();
    expect(screen.queryByRole("link", { name: "Invite your first teammate" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Manage teammate access" })).toHaveAttribute(
      "href",
      "/admin?section=people#people-title"
    );
  });

  it("filters the Inbox by title and the accessible All, Unread, Direct, and Rooms segments", async () => {
    const user = userEvent.setup();
    harness.conversations = [
      { ...harness.conversations[0]!, id: "conversation-1", title: "General", kind: "channel", unread_count: 1 },
      { ...harness.conversations[0]!, id: "conversation-2", title: "Project Alpha", kind: "group", unread_count: 0 },
      { ...harness.conversations[0]!, id: "conversation-3", title: null, counterpart_user_id: "user-2", counterpart_display_name: "Grace", kind: "direct", unread_count: 0 }
    ];
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    const list = screen.getByRole("navigation", { name: "Conversation list" });
    expect(screen.getByLabelText("3 conversations shown")).toHaveTextContent("3");

    await user.type(screen.getByLabelText("Filter conversation titles"), "project");
    expect(within(list).getByRole("button", { name: /^Project Alpha/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /^General/ })).not.toBeInTheDocument();
    expect(screen.getByLabelText("1 conversation shown")).toHaveTextContent("1");

    await user.clear(screen.getByLabelText("Filter conversation titles"));
    const inboxView = screen.getByRole("group", { name: "Inbox view" });
    await user.click(within(inboxView).getByRole("button", { name: "Direct" }));
    expect(within(list).getByRole("button", { name: /^Grace/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /^Project Alpha/ })).not.toBeInTheDocument();
    expect(screen.getByLabelText("1 conversation shown")).toHaveTextContent("1");

    await user.click(within(inboxView).getByRole("button", { name: "Rooms" }));
    expect(within(list).getByRole("button", { name: /^General/ })).toBeVisible();
    expect(within(list).getByRole("button", { name: /^Project Alpha/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /^Grace/ })).not.toBeInTheDocument();
    expect(screen.getByLabelText("2 conversations shown")).toHaveTextContent("2");

    await user.click(within(inboxView).getByRole("button", { name: "Unread" }));
    expect(within(list).getByRole("button", { name: /^General/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /^Grace/ })).not.toBeInTheDocument();
    expect(screen.getByLabelText("1 conversation shown")).toHaveTextContent("1");

    await user.click(within(inboxView).getByRole("button", { name: "All" }));
    expect(within(list).getByRole("button", { name: /^Grace/ })).toBeVisible();
    expect(screen.getByLabelText("3 conversations shown")).toHaveTextContent("3");
  });

  it("disambiguates duplicate direct-chat usernames in the list, header, and composer", () => {
    harness.conversations = [
      {
        ...harness.conversations[0]!,
        id: "direct-grace-one",
        kind: "direct",
        title: null,
        counterpart_user_id: "grace-one",
        counterpart_display_name: "Grace",
        visibility: "private",
        unread_count: 0
      },
      {
        ...harness.conversations[0]!,
        id: "direct-grace-two",
        kind: "direct",
        title: null,
        counterpart_user_id: "grace-two",
        counterpart_display_name: " grace ",
        visibility: "private",
        unread_count: 0
      }
    ];

    render(
      <MemoryRouter initialEntries={["/app?conversation=direct-grace-one"]}>
        <ChatPage />
      </MemoryRouter>
    );

    const firstIdentifier = `Grace · #${participantDisambiguator("grace-one")}`;
    const secondIdentifier = `grace · #${participantDisambiguator("grace-two")}`;
    const list = screen.getByRole("navigation", { name: "Conversation list" });
    expect(within(list).getByRole("button", { name: new RegExp(`^${firstIdentifier}`) })).toBeVisible();
    expect(within(list).getByRole("button", { name: new RegExp(`^${secondIdentifier}`) })).toBeVisible();
    expect(screen.getByRole("heading", { name: firstIdentifier })).toBeVisible();
    expect(screen.getByPlaceholderText(`Message ${firstIdentifier}`)).toBeVisible();
  });
});
