import {
  getChatPageHarness,
  LocationProbe,
  membershipFor,
  message,
  resetChatPageHarness
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
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "../../types";
import { loadDraft, storeDraft } from "../../lib/drafts";
import { participantDisambiguator } from "../../lib/participantIdentity";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();

describe("ChatPage durable sequence recovery", () => {
  beforeEach(resetChatPageHarness);

  it("offers distinct audio and video calls from the message header when tenant policy enables them", async () => {
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByRole("button", { name: "Start audio call" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Start video call" })).toBeVisible();
    expect(harness.api.audioCall).not.toHaveBeenCalled();
  });

  it("makes an empty conversation actionable and reports draft persistence only after typing", async () => {
    const user = userEvent.setup();
    harness.api.messages!.mockResolvedValue({
      data: [],
      page: {
        has_more: false,
        next_after_sequence: null,
        reset_required: false
      }
    });
    render(<MemoryRouter initialEntries={["/app?conversation=conversation-1"]}><ChatPage /></MemoryRouter>);

    expect(await screen.findByText("No messages yet")).toBeVisible();
    expect(screen.queryByText(/open a private call lobby/i)).not.toBeInTheDocument();
    expect(screen.queryByText("Saved on this device")).not.toBeInTheDocument();

    const composer = screen.getByRole("textbox", { name: "Message" });
    await user.click(composer);
    expect(composer).toHaveFocus();
    await user.type(composer, "Hello UAE office");
    expect(screen.getByText("Draft to General")).toBeVisible();
    expect(screen.getByText("Saved on this device")).toBeVisible();
  });

  it("marks the current call in the content-free Inbox summary", async () => {
    harness.callTargetConversation = harness.conversations[0]!;
    harness.callSessionState = { joined: true };
    render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);

    const general = await screen.findByRole("button", { name: /General/ });
    expect(within(general).getByText("Active call")).toBeVisible();
    expect(general).toHaveClass("has-active-call");
    expect(within(general).getByText("1 unread")).toBeVisible();
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

  it("forwards and clears the one-shot office readiness mode", async () => {
    render(
      <MemoryRouter initialEntries={["/app?conversation=conversation-1&call=audio&call_readiness=office&source=calls"]}>
        <ChatPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await waitFor(() => expect(harness.launchCall).toHaveBeenCalledWith(
      expect.objectContaining({ id: "conversation-1" }),
      "audio",
      "office"
    ));
    const location = screen.getByLabelText("location-search");
    await waitFor(() => expect(location).not.toHaveTextContent("call="));
    expect(location).not.toHaveTextContent("call_readiness=");
    expect(location).toHaveTextContent("conversation=conversation-1");
    expect(location).toHaveTextContent("source=calls");
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
