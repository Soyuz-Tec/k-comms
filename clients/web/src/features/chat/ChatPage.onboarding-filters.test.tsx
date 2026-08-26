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
import { beforeEach, describe, expect, it } from "vitest";
import type { Conversation } from "../../types";
import { participantDisambiguator } from "../../lib/participantIdentity";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();

describe("ChatPage durable sequence recovery", () => {
  beforeEach(resetChatPageHarness);

  it("provides usable first actions when the workspace has no conversations", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    window.localStorage.setItem("k-comms:onboarding:tenant-1:user-1", "dismissed");
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

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
    await user.click(screen.getByRole("button", { name: "Message Grace" }));
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

  it("disambiguates duplicate usernames in onboarding without exposing internal IDs", () => {
    harness.conversations = [];
    harness.users = [
      harness.users[0]!,
      { ...harness.users[1]!, id: "grace-one", display_name: "Grace" },
      { ...harness.users[1]!, id: "grace-two", display_name: " grace " }
    ];

    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    expect(
      screen.getByRole("button", {
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

  it("shows only the next useful onboarding action and persists dismissal locally", async () => {
    const user = userEvent.setup();
    harness.conversations = [];
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    expect(screen.getByRole("heading", { name: "Start your first conversation" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Message Grace" })).toBeVisible();
    expect(screen.queryByText("Choose notification preferences")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Start a conversation" })).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Dismiss welcome guide" }));
    expect(screen.queryByRole("heading", { name: "Start your first conversation" })).not.toBeInTheDocument();
    expect(window.localStorage.getItem("k-comms:onboarding:tenant-1:user-1")).toBe("dismissed");
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

    const firstTeammate = screen.getByRole("link", { name: "Invite your first teammate" });
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

    await user.type(screen.getByLabelText("Filter conversations by title"), "project");
    expect(within(list).getByRole("button", { name: /Project Alpha/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /General/ })).not.toBeInTheDocument();

    await user.clear(screen.getByLabelText("Filter conversations by title"));
    const inboxView = screen.getByRole("group", { name: "Inbox view" });
    await user.click(within(inboxView).getByRole("button", { name: "Direct" }));
    expect(within(list).getByRole("button", { name: /Grace/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /Project Alpha/ })).not.toBeInTheDocument();

    await user.click(within(inboxView).getByRole("button", { name: "Rooms" }));
    expect(within(list).getByRole("button", { name: /General/ })).toBeVisible();
    expect(within(list).getByRole("button", { name: /Project Alpha/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /Grace/ })).not.toBeInTheDocument();

    await user.click(within(inboxView).getByRole("button", { name: "Unread" }));
    expect(within(list).getByRole("button", { name: /General/ })).toBeVisible();
    expect(within(list).queryByRole("button", { name: /Grace/ })).not.toBeInTheDocument();

    await user.click(within(inboxView).getByRole("button", { name: "All" }));
    expect(within(list).getByRole("button", { name: /Grace/ })).toBeVisible();
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
    expect(within(list).getByRole("button", { name: new RegExp(firstIdentifier) })).toBeVisible();
    expect(within(list).getByRole("button", { name: new RegExp(secondIdentifier) })).toBeVisible();
    expect(screen.getByRole("heading", { name: firstIdentifier })).toBeVisible();
    expect(screen.getByPlaceholderText(`Message ${firstIdentifier}`)).toBeVisible();
  });
});
