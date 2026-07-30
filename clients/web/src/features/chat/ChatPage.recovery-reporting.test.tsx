import {
  getChatPageHarness,
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
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();

describe("ChatPage durable sequence recovery", () => {
  beforeEach(resetChatPageHarness);

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
