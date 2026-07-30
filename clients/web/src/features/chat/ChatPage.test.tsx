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
  fireEvent,
  render,
  screen,
  waitFor,
  within
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation, Message, User } from "../../types";
import { loadDraft, storeDraft } from "../../lib/drafts";
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

  it("offers distinct audio and video calls from the message header when tenant policy enables them", async () => {
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Start video call" })).toBeVisible();
    expect(harness.api.audioCall).not.toHaveBeenCalled();
  });

  it("consumes a one-shot call deep link and opens the default-off prejoin lobby", async () => {
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1&call=audio&source=directory"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await waitFor(() => expect(harness.launchCall).toHaveBeenCalledWith(
      expect.objectContaining({ id: "conversation-1" }),
      "audio"
    ));
    const location = screen.getByLabelText("location-search");
    await waitFor(() => expect(location).not.toHaveTextContent("call="));
    expect(location).toHaveTextContent("conversation=conversation-1");
    expect(location).toHaveTextContent("source=directory");
  });

  it("disables the audio action without probing calls when the media provider is unavailable", async () => {
    harness.audioCallsAvailable = false;
    harness.videoCallsAvailable = false;
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("button", { name: "Audio calls disabled" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Video calls disabled" })).toBeDisabled();
    expect(screen.getByText(
      "Calling is temporarily unavailable. Keep messaging and refresh call availability from Calls."
    )).toBeVisible();
    expect(screen.getByRole("link", { name: "Open Calls" })).toHaveAttribute("href", "/app/calls");
    expect(harness.api.audioCall).not.toHaveBeenCalled();
  });

  it("forwards conversation realtime call events to the persistent owner", async () => {
    const realtimeCall = {
      id: "call-1",
      conversation_id: "conversation-1",
      started_by_user_id: "user-2",
      status: "active" as const,
      started_at: "2026-07-15T10:00:00Z",
      expires_at: "2026-07-15T11:00:00Z",
      can_end: false
    };
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    act(() => harness.callbacks?.onAudioCallStarted(realtimeCall));
    expect(harness.publishRealtimeEvent).toHaveBeenCalledWith(realtimeCall);

    const endedCall = {
      ...realtimeCall,
      status: "ended",
      ended_at: "2026-07-15T10:30:00Z",
      end_reason: "ended_by_user"
    } as const;
    act(() => harness.callbacks?.onAudioCallEnded(endedCall));
    expect(harness.publishRealtimeEvent).toHaveBeenCalledWith(endedCall);
  });

  it("fetches a missing durable sequence and never marks past the contiguous cursor", async () => {
    let resolveCatchUp: ((value: unknown) => void) | undefined;
    const catchUp = new Promise((resolve) => { resolveCatchUp = resolve; });
    harness.api.messages!
      .mockResolvedValueOnce({ data: [message(1)], page: { has_more: false, next_after_sequence: null, reset_required: false } })
      .mockReturnValueOnce(catchUp);

    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    act(() => harness.callbacks?.onMessages([message(3)]));
    await waitFor(() => expect(harness.api.messages).toHaveBeenCalledWith("conversation-1", 1, 200));
    await new Promise((resolve) => window.setTimeout(resolve, 550));
    expect(harness.markRead).not.toHaveBeenCalledWith(3);

    resolveCatchUp?.({ data: [message(2), message(3)], page: { has_more: false, next_after_sequence: null, reset_required: false } });
    await waitFor(() => expect(harness.markRead).toHaveBeenCalledWith(3), { timeout: 2_000 });
  });

  it("merges a realtime reply into an open canonical thread", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Start thread" }));
    expect(await screen.findByRole("dialog", { name: "Thread" })).toBeInTheDocument();

    const reply = {
      ...message(2),
      body: "Realtime thread reply",
      reply_to_message_id: "message-1",
      thread_root_message_id: "message-1",
      thread_reply_count: 1
    };
    act(() => harness.callbacks?.onMessages([reply]));

    expect(await screen.findAllByText("Realtime thread reply")).toHaveLength(2);
  });

  it("opens a safely parsed notification message deep link as a thread", async () => {
    const linkedMessageId = "33333333-3333-4333-8333-333333333333";
    render(
      <MemoryRouter initialEntries={[`/app?conversation=conversation-1&message=${linkedMessageId}`]}>
        <ChatPage />
      </MemoryRouter>
    );

    await waitFor(() =>
      expect(harness.api.messageThread).toHaveBeenCalledWith("conversation-1", linkedMessageId)
    );
  });

  it("turns a search result into a reloadable focused-message deep link", async () => {
    const user = userEvent.setup();
    const result = {
      ...message(42),
      id: "44444444-4444-4444-8444-444444444444"
    };
    harness.api.searchMessagePage!.mockResolvedValue({
      data: [result],
      page: { limit: 25, has_more: false, next_cursor: null }
    });

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await user.click(within(screen.getByLabelText("Conversations")).getByRole("button", { name: "Search messages" }));
    await user.type(screen.getByRole("searchbox", { name: "Search accessible messages" }), "Message 42");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await user.click(await screen.findByText("Message 42"));

    await waitFor(() => expect(screen.getByLabelText("location-search")).toHaveTextContent(
      "conversation=conversation-1&search_message=44444444-4444-4444-8444-444444444444&search_sequence=42"
    ));
  });

  it("keeps an exact-source history window loaded after its highlight expires", async () => {
    const sourceId = "55555555-5555-4555-8555-555555555555";
    const sourceSequence = 142;
    const historyWindow = Array.from({ length: 60 }, (_, index) => {
      const sequence = 83 + index;
      return sequence === sourceSequence
        ? { ...message(sequence), id: sourceId, body: "Archived source message" }
        : message(sequence);
    });
    harness.api.messages = vi.fn().mockResolvedValue({
      data: historyWindow,
      page: { has_more: false, next_after_sequence: null, reset_required: false }
    });

    render(
      <MemoryRouter initialEntries={[
        `/app?conversation=conversation-1&search_message=${sourceId}&search_sequence=${sourceSequence}`
      ]}>
        <ChatPage />
      </MemoryRouter>
    );

    expect(await screen.findByText("Archived source message")).toBeVisible();
    expect(harness.api.messages).toHaveBeenCalledWith("conversation-1", 82, 100);
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 3_100));
    });

    expect(screen.getByText("Archived source message")).toBeVisible();
    expect(harness.api.messages).toHaveBeenCalledTimes(1);
  });

  it("keeps explicit mention IDs across a failed-send retry and hides service identities", async () => {
    const user = userEvent.setup();
    harness.sendMessage
      .mockRejectedValueOnce(new Error("temporary disconnect"))
      .mockResolvedValueOnce({ ...message(2), mentioned_user_ids: ["user-2"] });

    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Mention" }));
    expect(screen.queryByText("Build bot")).not.toBeInTheDocument();
    await user.click(screen.getByRole("checkbox", { name: "Grace" }));
    await user.type(screen.getByLabelText("Message"), "Mention retry");
    await user.click(screen.getByRole("button", { name: /Send/ }));

    await user.click(await screen.findByRole("button", { name: "Retry" }));
    await waitFor(() => expect(harness.sendMessage).toHaveBeenCalledTimes(2));
    expect(harness.sendMessage.mock.calls[0]?.[0]).toMatchObject({ mentioned_user_ids: ["user-2"] });
    expect(harness.sendMessage.mock.calls[1]?.[0]).toMatchObject({ mentioned_user_ids: ["user-2"] });
  });

  it("clears a confirmed send from its original draft without touching the newly selected conversation", async () => {
    const user = userEvent.setup();
    harness.conversations = [
      harness.conversations[0]!,
      {
        ...harness.conversations[0]!,
        id: "conversation-2",
        title: "Operations",
        latest_sequence: 1,
        unread_count: 0
      }
    ];
    harness.api.messages = vi.fn().mockImplementation(
      async (conversationId: string) => ({
        data: [{
          ...message(1),
          id: `${conversationId}-message-1`,
          conversation_id: conversationId
        }],
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      })
    );
    storeDraft(
      "tenant-1",
      "user-1",
      "conversation-2",
      "Keep the Operations draft"
    );
    const pendingSend = deferred<Message>();
    harness.sendMessage.mockImplementationOnce(() => pendingSend.promise);

    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    const composerA = await screen.findByLabelText("Message");
    await user.type(composerA, "Send from General");
    await user.click(screen.getByRole("button", { name: /Send/ }));
    await waitFor(() => expect(harness.sendMessage).toHaveBeenCalledTimes(1));

    const conversations = screen.getByRole("navigation", {
      name: "Conversation list"
    });
    await user.click(
      within(conversations).getByRole("button", { name: /Operations/ })
    );
    const composerB = await screen.findByLabelText("Message");
    await waitFor(() =>
      expect(composerB).toHaveValue("Keep the Operations draft")
    );

    await act(async () => pendingSend.resolve({
      ...message(2),
      body: "Send from General"
    }));

    expect(composerB).toHaveValue("Keep the Operations draft");
    expect(loadDraft(
      "tenant-1",
      "user-1",
      "conversation-2"
    )).toBe("Keep the Operations draft");
    expect(loadDraft(
      "tenant-1",
      "user-1",
      "conversation-1"
    )).toBe("");

    await user.click(
      within(conversations).getByRole("button", { name: /General/ })
    );
    await waitFor(() => expect(screen.getByLabelText("Message")).toHaveValue(""));
  });

  it("keeps the reader's history position and offers an announced jump for new messages", async () => {
    const user = userEvent.setup();
    const scrollIntoView = vi.spyOn(Element.prototype, "scrollIntoView");
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    const messageScroll = document.querySelector<HTMLElement>(".message-scroll");
    expect(messageScroll).not.toBeNull();
    Object.defineProperties(messageScroll!, {
      scrollHeight: { configurable: true, value: 1_000 },
      clientHeight: { configurable: true, value: 300 },
      scrollTop: { configurable: true, value: 100, writable: true }
    });
    fireEvent.scroll(messageScroll!);
    expect(await screen.findByRole("button", { name: "Jump to latest" })).toBeVisible();
    scrollIntoView.mockClear();

    act(() => harness.callbacks?.onMessages([{ ...message(2), sender_user_id: "user-2" }]));

    const jump = await screen.findByRole("button", { name: "1 new message · Jump to latest" });
    expect(screen.getByRole("status", { name: "" })).toHaveTextContent("1 new message");
    expect(scrollIntoView).not.toHaveBeenCalled();
    await user.click(jump);
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: /Jump to latest/ })).not.toBeInTheDocument();
    scrollIntoView.mockRestore();
  });

  it("clears the online count when realtime is no longer live", async () => {
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    act(() => harness.callbacks?.onPresence(2, ["user-1", "user-2"]));
    expect(screen.getByText("2 online")).toBeVisible();

    act(() => harness.callbacks?.onStatus("reconnecting"));
    expect(screen.getByText("Reconnecting")).toBeVisible();
    expect(screen.queryByText("2 online")).not.toBeInTheDocument();
  });

  it("disambiguates duplicate usernames in the live typing list", async () => {
    const duplicateGrace = {
      ...harness.users[1]!,
      id: "user-3",
      display_name: " grace "
    };
    harness.users = [...harness.users, duplicateGrace];
    Object.assign(harness.api, {
      conversationMembers: vi.fn().mockResolvedValue([
        membershipFor(harness.users[0]!),
        membershipFor(harness.users[1]!),
        membershipFor(duplicateGrace)
      ])
    });

    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());
    await waitFor(() => expect(harness.api.conversationMembers).toHaveBeenCalled());

    act(() => {
      harness.callbacks?.onTyping("user-2", true);
      harness.callbacks?.onTyping("user-3", true);
    });

    expect(
      screen.getByText(
        `Grace · #${participantDisambiguator("user-2")}, grace · #${participantDisambiguator("user-3")} are typing…`
      )
    ).toBeVisible();
  });

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

  it("discards stale older messages and sender labels after switching conversations", async () => {
    const user = userEvent.setup();
    const recentFirstConversation = {
      ...message(3),
      body: "Recent first-conversation message"
    };
    const secondConversationMessage = {
      ...message(1),
      id: "conversation-2-message-1",
      conversation_id: "conversation-2",
      body: "Second-conversation message"
    };
    const staleOlderMessage = {
      ...message(1),
      sender_user_id: "stale-departed-user",
      body: "Stale older message"
    };
    harness.conversations = [
      {
        ...harness.conversations[0]!,
        latest_sequence: 102
      },
      {
        ...harness.conversations[0]!,
        id: "conversation-2",
        title: "Project Alpha",
        kind: "group",
        latest_sequence: 1,
        unread_count: 0
      }
    ];
    let resolveOlder: ((page: unknown) => void) | undefined;
    const olderPage = new Promise((resolve) => {
      resolveOlder = resolve;
    });
    harness.api.messages = vi.fn(
      (
        conversationId: string,
        _afterSequence: number,
        _limit: number,
        beforeSequence?: number
      ) => {
        if (conversationId === "conversation-1" && beforeSequence === 3) {
          return olderPage;
        }
        if (conversationId === "conversation-2") {
          return Promise.resolve({
            data: [secondConversationMessage],
            page: {
              has_more: false,
              next_after_sequence: null,
              reset_required: false
            }
          });
        }
        return Promise.resolve({
          data: [recentFirstConversation],
          page: {
            has_more: false,
            next_after_sequence: null,
            reset_required: false
          }
        });
      }
    );
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1"]}>
        <ChatPage />
      </MemoryRouter>
    );
    expect(
      await screen.findByText("Recent first-conversation message")
    ).toBeVisible();

    await user.click(
      screen.getByRole("button", { name: "Load older messages" })
    );
    await waitFor(() =>
      expect(harness.api.messages).toHaveBeenCalledWith(
        "conversation-1",
        0,
        200,
        3
      )
    );
    await user.click(
      within(
        screen.getByRole("navigation", { name: "Conversation list" })
      ).getByRole("button", { name: /Project Alpha/u })
    );
    expect(await screen.findByText("Second-conversation message")).toBeVisible();

    await act(async () => {
      resolveOlder?.({
        data: [staleOlderMessage],
        included: {
          sender_labels: [
            {
              id: staleOlderMessage.sender_user_id,
              display_name: "Stale Departed",
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
      await Promise.resolve();
    });

    expect(screen.queryByText("Stale older message")).not.toBeInTheDocument();
    expect(screen.queryByText("Stale Departed")).not.toBeInTheDocument();
    expect(screen.getByText("Second-conversation message")).toBeVisible();
  });

  it("submits a message report with the same moderated payload through an accessible dialog", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);
    await waitFor(() => expect(harness.callbacks).not.toBeNull());

    await user.click(await screen.findByRole("button", { name: "Report" }));
    const dialog = screen.getByRole("alertdialog", { name: "Report this message?" });
    const reason = within(dialog).getByLabelText("Reason for reporting this message");
    const submit = within(dialog).getByRole("button", { name: "Submit report" });
    expect(dialog).toBeVisible();
    fireEvent.change(reason, { target: { value: "Contains a sensitive customer identifier" } });
    expect(reason).toHaveValue("Contains a sensitive customer identifier");
    expect(submit).toBeEnabled();
    fireEvent.submit(submit.closest("form")!);

    await waitFor(() => expect(harness.api.createModerationCase).toHaveBeenCalledWith({
      message_id: "message-1",
      conversation_id: "conversation-1",
      category: "message_content",
      summary: "Contains a sensitive customer identifier",
      details: "Contains a sensitive customer identifier",
      priority: "normal"
    }));
    expect(await screen.findByText("Report submitted to workspace moderators.")).toBeVisible();
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
