import {
  getChatPageHarness,
  HistoryBack,
  LocationProbe,
  membershipFor,
  message,
  resetChatPageHarness,
  setMobileViewport
} from "./ChatPage.testSupport";
import {
  act,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { User } from "../../types";
import { participantDisambiguator } from "../../lib/participantIdentity";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();

describe("ChatPage durable sequence recovery", () => {
  beforeEach(resetChatPageHarness);

  it("keeps bare mobile app routes on the conversation list without clearing unread state", async () => {
    setMobileViewport(true);
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    expect(screen.getByLabelText("location-search")).toHaveTextContent("");
    expect(harness.api.messages).not.toHaveBeenCalled();
    expect(harness.markRead).not.toHaveBeenCalled();
  });

  it("opens a valid mobile conversation deep link directly in the message pane", async () => {
    setMobileViewport(true);
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
    expect(await screen.findByRole("button", { name: "Back to conversations" })).toBeInTheDocument();
    await waitFor(() => expect(harness.api.messages).toHaveBeenCalledWith("conversation-1", 0, 100));
  });

  it("renders retained departed usernames for messages and reply previews", async () => {
    const departedRoot = {
      ...message(1),
      sender_user_id: "departed-guest",
      body: "Earlier guest message"
    };
    const reply = {
      ...message(2),
      sender_user_id: "user-2",
      reply_to_message_id: departedRoot.id,
      thread_root_message_id: departedRoot.id,
      body: "Reply to departed guest"
    };
    harness.api.messages = vi.fn().mockResolvedValue({
      data: [departedRoot, reply],
      included: {
        sender_labels: [
          { id: "departed-guest", display_name: "Jordan Departed", redacted: false }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(await screen.findAllByText("Jordan Departed")).toHaveLength(2);
    expect(screen.getByText("Reply to departed guest")).toBeVisible();
  });

  it("reconciles authenticated socket replay through REST without duplicating it", async () => {
    const replayed = {
      ...message(2),
      sender_user_id: "departed-replay-member",
      body: "Authenticated replay message"
    };
    harness.api.messages = vi.fn()
      .mockResolvedValueOnce({
        data: [message(1)],
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      })
      .mockResolvedValueOnce({
        data: [replayed],
        included: {
          sender_labels: [
            {
              id: replayed.sender_user_id,
              display_name: "Morgan Replay",
              redacted: false
            }
          ]
        },
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      });
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    await screen.findByText("Message 1");

    act(() => {
      harness.callbacks?.onMessages([replayed]);
      harness.callbacks?.onCatchUpRequired(1);
    });

    expect(await screen.findByText("Morgan Replay")).toBeVisible();
    expect(screen.getAllByText("Authenticated replay message")).toHaveLength(1);
    expect(harness.api.messages).toHaveBeenCalledWith(
      "conversation-1",
      1,
      200
    );
  });

  it("retains an ordinary departed guest username after sidecar reconciliation", async () => {
    const currentMembership = {
      id: "membership-current",
      role: "member",
      joined_at: "2026-07-12T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        account_type: "human",
        role: "member",
        status: "active"
      }
    };
    const guestMembership = {
      id: "membership-new-guest",
      role: "member",
      joined_at: "2026-07-25T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "new-guest",
        tenant_id: "tenant-1",
        display_name: "Jordan Guest",
        account_type: "guest",
        role: "member",
        status: "active"
      }
    };
    harness.api.conversationMembers = vi.fn()
      .mockResolvedValueOnce([currentMembership, guestMembership])
      .mockResolvedValue([currentMembership]);
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    await waitFor(() =>
      expect(harness.api.conversationMembers).toHaveBeenCalledTimes(1)
    );
    const guestMessage = {
      ...message(2),
      sender_user_id: guestMembership.user.id,
      body: "Hello from the guest"
    };

    act(() => {
      harness.callbacks?.onMessages([guestMessage]);
    });

    expect(await screen.findByText("Jordan Guest")).toBeVisible();
    expect(screen.getByText("Hello from the guest")).toBeVisible();
    expect(harness.api.conversationMembers).toHaveBeenLastCalledWith(
      "conversation-1"
    );
    expect(harness.api.conversationMembers).toHaveBeenCalledTimes(1);

    act(() => {
      harness.callbacks?.onMembershipChanged({
        user_id: guestMembership.user.id,
        action: "removed",
        role: "member"
      });
    });

    await waitFor(() =>
      expect(harness.api.conversationMembers).toHaveBeenCalledTimes(2)
    );
    await waitFor(() =>
      expect(harness.api.messageSenderLabels).toHaveBeenCalledWith(
        "conversation-1",
        ["message-2"]
      )
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Mention" })).toBeDisabled()
    );
    expect(screen.getByText("Jordan Guest")).toBeVisible();
    expect(screen.getByText("Hello from the guest")).toBeVisible();
  });

  it("replaces a departed guest cache with the erased sidecar label", async () => {
    const currentMembership = {
      id: "membership-current",
      role: "member",
      joined_at: "2026-07-12T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        account_type: "human",
        role: "member",
        status: "active"
      }
    };
    const erasedGuestMembership = {
      ...currentMembership,
      id: "membership-erased-guest",
      user: {
        ...currentMembership.user,
        id: "erased-guest",
        display_name: "Avery Active Guest",
        account_type: "guest"
      }
    };
    const guestMessage = {
      ...message(2),
      sender_user_id: erasedGuestMembership.user.id,
      body: "Message before erasure"
    };
    harness.api.conversationMembers = vi.fn()
      .mockResolvedValueOnce([currentMembership, erasedGuestMembership])
      .mockResolvedValue([currentMembership]);
    harness.api.messages = vi.fn().mockResolvedValue({
      data: [message(1)],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    harness.api.messageSenderLabels = vi.fn().mockResolvedValue([
      {
        id: erasedGuestMembership.user.id,
        display_name: "Deleted user",
        redacted: true
      }
    ]);
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    await screen.findByText("Message 1");

    act(() => {
      harness.callbacks?.onMessages([guestMessage]);
    });
    expect(await screen.findByText("Avery Active Guest")).toBeVisible();

    act(() => {
      harness.callbacks?.onMembershipChanged({
        user_id: erasedGuestMembership.user.id,
        action: "removed",
        role: "member"
      });
    });

    expect(await screen.findByText("Deleted user")).toBeVisible();
    expect(screen.queryByText("Avery Active Guest")).not.toBeInTheDocument();
    expect(screen.getByText("Message before erasure")).toBeVisible();
    expect(harness.api.messageSenderLabels).toHaveBeenCalledWith(
      "conversation-1",
      ["message-2"]
    );
  });

  it("refreshes an erased author older than 200 rendered messages without replaying history", async () => {
    const currentMembership = {
      id: "membership-current",
      role: "member",
      joined_at: "2026-07-12T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        account_type: "human",
        role: "member",
        status: "active"
      }
    };
    const oldAuthorMembership = {
      ...currentMembership,
      id: "membership-old-author",
      user: {
        ...currentMembership.user,
        id: "old-author",
        display_name: "Avery Before Erasure",
        account_type: "guest"
      }
    };
    const renderedMessages = [
      {
        ...message(1),
        sender_user_id: oldAuthorMembership.user.id,
        body: "Old visible message"
      },
      ...Array.from({ length: 200 }, (_, index) => message(index + 2))
    ];
    harness.api.messages = vi.fn().mockResolvedValue({
      data: renderedMessages,
      included: {
        sender_labels: [
          {
            id: oldAuthorMembership.user.id,
            display_name: oldAuthorMembership.user.display_name,
            redacted: false
          }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    harness.api.conversationMembers = vi.fn()
      .mockResolvedValueOnce([currentMembership, oldAuthorMembership])
      .mockResolvedValue([currentMembership]);
    harness.api.messageSenderLabels = vi.fn().mockResolvedValue([
      {
        id: oldAuthorMembership.user.id,
        display_name: "Deleted user",
        redacted: true
      },
      { id: "user-1", display_name: "Ada", redacted: false }
    ]);

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(await screen.findByText("Avery Before Erasure")).toBeVisible();
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    act(() => {
      harness.callbacks?.onMembershipChanged({
        user_id: oldAuthorMembership.user.id,
        action: "removed",
        role: "member"
      });
    });

    expect(await screen.findByText("Deleted user")).toBeVisible();
    expect(screen.queryByText("Avery Before Erasure")).not.toBeInTheDocument();
    expect(harness.api.messageSenderLabels).toHaveBeenCalledWith(
      "conversation-1",
      ["message-1"]
    );
    expect(harness.api.messages).toHaveBeenCalledTimes(1);
  });

  it("skips hidden sender-label refreshes and backs off unchanged labels until a change resets the delay", async () => {
    let now = 0;
    const nowSpy = vi.spyOn(Date, "now").mockImplementation(() => now);
    const currentMembership = membershipFor(harness.users[0]!);
    const departedUser = {
      id: "adaptive-departed-user",
      tenant_id: "tenant-1",
      display_name: "Former teammate",
      email: null,
      account_type: "guest",
      role: "member",
      status: "active"
    } as User;
    const departedMembership = membershipFor(departedUser);
    const departedMessage = {
      ...message(2),
      sender_user_id: departedUser.id,
      body: "Adaptive sender label"
    };
    harness.api.messages = vi.fn().mockResolvedValue({
      data: [departedMessage],
      included: {
        sender_labels: [
          {
            id: departedUser.id,
            display_name: "Former teammate",
            redacted: false
          }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    const conversationMembers = vi.fn()
      .mockResolvedValueOnce([currentMembership, departedMembership])
      .mockResolvedValue([currentMembership]);
    const senderLabelsLookup = vi.fn()
      .mockResolvedValueOnce([
        {
          id: departedUser.id,
          display_name: "Former teammate",
          redacted: false
        }
      ])
      .mockResolvedValueOnce([
        {
          id: departedUser.id,
          display_name: "Former teammate",
          redacted: false
        }
      ])
      .mockResolvedValue([
        {
          id: departedUser.id,
          display_name: "Renamed teammate",
          redacted: false
        }
      ]);
    harness.api.conversationMembers = conversationMembers;
    harness.api.messageSenderLabels = senderLabelsLookup;
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await screen.findByText("Adaptive sender label");
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    const reconcile = async () => {
      const expectedMemberCalls =
        conversationMembers.mock.calls.length + 1;
      act(() => {
        harness.callbacks?.onMembershipChanged({
          user_id: departedUser.id,
          action: "removed",
          role: "member"
        });
      });
      await waitFor(() =>
        expect(conversationMembers).toHaveBeenCalledTimes(
          expectedMemberCalls
        )
      );
      await act(async () => {
        await new Promise((resolve) => window.setTimeout(resolve, 0));
      });
    };

    await reconcile();
    await waitFor(() =>
      expect(senderLabelsLookup).toHaveBeenCalledTimes(1)
    );

    now = 30_000;
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "hidden"
    });
    await reconcile();
    expect(senderLabelsLookup).toHaveBeenCalledTimes(1);

    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible"
    });
    await reconcile();
    await waitFor(() =>
      expect(senderLabelsLookup).toHaveBeenCalledTimes(2)
    );

    now = 60_000;
    await reconcile();
    expect(senderLabelsLookup).toHaveBeenCalledTimes(2);

    now = 90_000;
    await reconcile();
    await waitFor(() =>
      expect(senderLabelsLookup).toHaveBeenCalledTimes(3)
    );
    expect(await screen.findByText("Renamed teammate")).toBeVisible();

    now = 120_000;
    await reconcile();
    await waitFor(() =>
      expect(senderLabelsLookup).toHaveBeenCalledTimes(4)
    );
    nowSpy.mockRestore();
  });

  it("reconciles a disappearing Presence identity without a membership event", async () => {
    const user = userEvent.setup();
    const current = {
      id: "membership-current",
      role: "member",
      joined_at: "2026-07-12T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        account_type: "human",
        role: "member",
        status: "active"
      }
    };
    const expiring = {
      ...current,
      id: "membership-expiring",
      user: {
        ...current.user,
        id: "expiring-user",
        display_name: "Expiring User",
        account_type: "guest"
      }
    };
    harness.api.conversationMembers = vi.fn()
      .mockResolvedValueOnce([current, expiring])
      .mockResolvedValueOnce([current, expiring])
      .mockResolvedValue([current]);
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    await user.click(await screen.findByRole("button", { name: "Mention" }));
    expect(await screen.findByText("Expiring User")).toBeVisible();

    act(() => {
      harness.callbacks?.onPresence(2, ["user-1", "expiring-user"]);
    });
    await waitFor(() =>
      expect(harness.api.conversationMembers).toHaveBeenCalledTimes(2)
    );
    act(() => {
      harness.callbacks?.onPresence(1, ["user-1"]);
      harness.callbacks?.onPresence(1, ["user-1"]);
    });

    await waitFor(() =>
      expect(harness.api.conversationMembers).toHaveBeenCalledTimes(3)
    );
    await waitFor(() =>
      expect(screen.queryByText("Expiring User")).not.toBeInTheDocument()
    );
  });

  it("periodically reconciles members without overlapping duplicate ticks", async () => {
    const user = userEvent.setup();
    let reconcile: (() => void) | undefined;
    const intervalSpy = vi.spyOn(window, "setInterval").mockImplementation((handler, timeout) => {
      if (timeout === 30_000 && typeof handler === "function") {
        reconcile = handler as () => void;
      }
      return 41 as unknown as ReturnType<typeof window.setInterval>;
    });
    const current = {
      id: "membership-current",
      role: "member",
      joined_at: "2026-07-12T10:00:00Z",
      last_read_sequence: 0,
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        account_type: "human",
        role: "member",
        status: "active"
      }
    };
    const expired = {
      ...current,
      id: "membership-expired",
      user: {
        ...current.user,
        id: "expired-user",
        display_name: "Expired Offline User",
        account_type: "guest"
      }
    };
    harness.api.conversationMembers = vi.fn()
      .mockResolvedValueOnce([current, expired])
      .mockResolvedValue([current]);
    const view = render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await user.click(await screen.findByRole("button", { name: "Mention" }));
    expect(await screen.findByText("Expired Offline User")).toBeVisible();
    expect(reconcile).toBeTypeOf("function");

    act(() => {
      reconcile?.();
      reconcile?.();
    });

    await waitFor(() =>
      expect(harness.api.conversationMembers).toHaveBeenCalledTimes(2)
    );
    await waitFor(() =>
      expect(screen.queryByText("Expired Offline User")).not.toBeInTheDocument()
    );
    view.unmount();
    intervalSpy.mockRestore();
  });

  it("disambiguates duplicate active and retained sender usernames", async () => {
    const activeMessage = {
      ...message(1),
      sender_user_id: "user-2",
      body: "Active Grace"
    };
    const departedMessage = {
      ...message(2),
      sender_user_id: "departed-grace",
      body: "Departed Grace"
    };
    harness.api.messages = vi.fn().mockResolvedValue({
      data: [activeMessage, departedMessage],
      included: {
        sender_labels: [
          { id: "departed-grace", display_name: "GRACE", redacted: false }
        ]
      },
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(
      await screen.findByText(
        `Grace · #${participantDisambiguator("user-2")}`
      )
    ).toBeVisible();
    expect(
      screen.getByText(
        `GRACE · #${participantDisambiguator("departed-grace")}`
      )
    ).toBeVisible();
  });

  it("pushes the selected mobile conversation and returns to a bare focused list", async () => {
    setMobileViewport(true);
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );
    const conversationButton = within(screen.getByRole("navigation", { name: "Conversation list" }))
      .getByRole("button", { name: /General/ });

    await user.click(conversationButton);
    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent("?conversation=conversation-1"));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
    await waitFor(() => expect(screen.getByRole("button", { name: "Back to conversations" })).toHaveFocus());

    await user.click(screen.getByRole("button", { name: "Back to conversations" }));
    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(""));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    await waitFor(() => expect(conversationButton).toHaveFocus());
  });

  it("synchronizes the mobile pane and focus when browser history returns to the list", async () => {
    setMobileViewport(true);
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
        <HistoryBack />
      </MemoryRouter>
    );
    const conversationButton = within(screen.getByRole("navigation", { name: "Conversation list" }))
      .getByRole("button", { name: /General/ });

    await user.click(conversationButton);
    await waitFor(() => expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages"));
    await user.click(screen.getByRole("button", { name: "Browser back" }));

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(""));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-list");
    await waitFor(() => expect(conversationButton).toHaveFocus());
  });

  it("preserves desktop first-conversation auto-selection", async () => {
    render(
      <MemoryRouter initialEntries={["/app"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent("?conversation=conversation-1"));
    expect(document.querySelector("main#main-content")).toHaveClass("mobile-messages");
  });

  it("connects realtime after a saved conversation becomes available", async () => {
    harness.conversations = [];
    const view = render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(harness.callbacks).toBeNull();
    harness.conversations = [{ id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", counterpart_user_id: null, counterpart_display_name: null, visibility: "tenant", latest_sequence: 1, unread_count: 1, last_read_sequence: 0, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }];
    view.rerender(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );

    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    expect(await screen.findByText("Live")).toBeInTheDocument();
  });
});
