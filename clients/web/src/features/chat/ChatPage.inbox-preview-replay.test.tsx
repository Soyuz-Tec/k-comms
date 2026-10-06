import { getChatPageHarness, message, resetChatPageHarness } from "./ChatPage.testSupport";
import { act, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it } from "vitest";
import type { Conversation, Message, MessagePage } from "../../types";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();
const page = (messages: Message[]): MessagePage => ({
  data: messages,
  page: { has_more: false, next_after_sequence: null, reset_required: false }
});

function deferredHistory(initial = message(1)) {
  const projection = {
    id: initial.id, sequence: initial.conversation_sequence,
    sender_user_id: initial.sender_user_id, sender_display_name: "Ada",
    status: initial.status, excerpt: Array.from(initial.body ?? "").slice(0, 200).join(""),
    inserted_at: initial.inserted_at
  };
  harness.conversations[0]!.inbox = { message: projection, draft: null };
  let resolve!: (value: MessagePage) => void;
  harness.api.messages!.mockReturnValueOnce(new Promise<MessagePage>(done => { resolve = done; }));
  render(<MemoryRouter initialEntries={["/app/"]}><ChatPage /></MemoryRouter>);
  return { projection, resolve, list: screen.getByRole("navigation", { name: "Conversation list" }) };
}

describe("authorized Inbox previews during transcript hydration", () => {
  beforeEach(() => {
    resetChatPageHarness();
    // Model the real provider's state updates, including feed invalidations.
    harness.setConversations.mockReset().mockImplementation((update: Conversation[] | ((rows: Conversation[]) => Conversation[])) => {
      harness.conversations = typeof update === "function" ? update(harness.conversations) : update;
    });
  });

  it.each([
    ["ordinary text", "Mobile-ready message body"],
    ["the 200-code-point boundary", `${"🙂".repeat(199)}Z beyond the excerpt`],
    ["combining characters", `${"e\u0301".repeat(100)} beyond the excerpt`]
  ])("retains the authorized projection after delayed matching history: %s", async (_name, body) => {
    const incoming = { ...message(1), body };
    const { projection, resolve, list } = deferredHistory(incoming);
    expect(within(list).getByText(`You: ${projection.excerpt}`)).toBeVisible();
    await act(async () => resolve(page([incoming])));
    expect(harness.conversations[0]!.inbox!.message).toBe(projection);
    expect(within(list).getByText(`You: ${projection.excerpt}`)).toBeVisible();
    expect(screen.getByText(body)).toBeVisible();
  });

  it.each([
    ["edited body", { body: "Edited text" }],
    ["deleted message", { status: "deleted", body: null }],
    ["moderated message", { status: "moderated", body: null }],
    ["different sender", { sender_user_id: "user-2" }],
    ["different tenant", { tenant_id: "other-tenant" }],
    ["different sequence", { conversation_sequence: 2 }],
    ["thread membership", { thread_root_message_id: "thread-root" }],
    ["newer main message", { id: "message-2", conversation_sequence: 2 }]
  ] satisfies Array<[string, Partial<Message>]>) ("invalidates the old projection for %s", async (_name, changes) => {
    const { resolve, list } = deferredHistory();
    await act(async () => resolve(page([{ ...message(1), ...changes }])));
    expect(harness.conversations[0]!.inbox!.message).toBeNull();
    expect(within(list).queryByText("You: Message 1")).not.toBeInTheDocument();
    expect(within(list).getByText("Room conversation")).toBeVisible();
  });

  it("cannot reconstruct a projection removed before delayed history arrives", async () => {
    const { resolve, list } = deferredHistory();
    harness.conversations[0]!.inbox = null;
    await act(async () => resolve(page([message(1)])));
    expect(harness.conversations[0]!.inbox).toBeNull();
    expect(within(list).queryByText("You: Message 1")).not.toBeInTheDocument();
  });

  it("cannot restore an active excerpt over a removed projection", async () => {
    const { resolve, list } = deferredHistory();
    harness.conversations[0]!.inbox!.message = {
      ...harness.conversations[0]!.inbox!.message!, status: "moderated", excerpt: ""
    };
    await act(async () => resolve(page([message(1)])));
    expect(harness.conversations[0]!.inbox!.message).toBeNull();
    expect(within(list).queryByText("You: Message 1")).not.toBeInTheDocument();
  });
});
