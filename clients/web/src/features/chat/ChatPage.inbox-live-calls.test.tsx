import {
  activeCallSummary,
  getChatPageHarness,
  resetChatPageHarness
} from "./ChatPage.testSupport";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation } from "../../types";
import { ChatPage } from "./ChatPage";

const harness = getChatPageHarness();

const quietRoom: Conversation = {
  id: "conversation-2",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Release captains",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "tenant",
  latest_sequence: 4,
  unread_count: 0,
  last_read_sequence: 4,
  version: 1,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

function callsPage(conversationIds: string[]) {
  return {
    data: conversationIds.map(activeCallSummary),
    page: { limit: 100, has_more: false, next_cursor: null }
  };
}

function renderInbox() {
  return render(<MemoryRouter initialEntries={["/app"]}><ChatPage /></MemoryRouter>);
}

describe("inbox live call indicator", () => {
  let calls: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    resetChatPageHarness();
    calls = vi.fn().mockResolvedValue(callsPage([]));
    harness.api.calls = calls;
    harness.conversations = [harness.conversations[0]!, quietRoom];
    window.localStorage.setItem("k-comms:onboarding:tenant-1:user-1", "dismissed");
  });

  it("marks only the conversations that have a call running", async () => {
    calls.mockResolvedValue(callsPage(["conversation-2"]));
    renderInbox();

    const liveRow = await screen.findByRole("button", { name: /Release captains/ });
    await waitFor(() => expect(liveRow).toHaveTextContent("Active call"));
    expect(calls).toHaveBeenCalledWith({ scope: "active", limit: 100 });
    expect(screen.getByRole("button", { name: /General/ })).not.toHaveTextContent("Active call");
  });

  it("leaves the inbox unmarked when no call is running", async () => {
    renderInbox();

    await waitFor(() => expect(calls).toHaveBeenCalled());
    expect(screen.queryByText("Active call")).not.toBeInTheDocument();
  });

  it("keeps the last known rooms when the poll fails rather than clearing the badge", async () => {
    calls.mockResolvedValueOnce(callsPage(["conversation-2"]));
    renderInbox();

    const liveRow = await screen.findByRole("button", { name: /Release captains/ });
    await waitFor(() => expect(liveRow).toHaveTextContent("Active call"));

    calls.mockRejectedValue(new Error("offline"));
    window.dispatchEvent(new Event("focus"));

    await waitFor(() => expect(calls).toHaveBeenCalledTimes(2));
    expect(liveRow).toHaveTextContent("Active call");
  });

  it("drops the badge once the call ends", async () => {
    calls.mockResolvedValueOnce(callsPage(["conversation-2"]));
    renderInbox();

    const liveRow = await screen.findByRole("button", { name: /Release captains/ });
    await waitFor(() => expect(liveRow).toHaveTextContent("Active call"));

    calls.mockResolvedValue(callsPage([]));
    window.dispatchEvent(new Event("focus"));

    await waitFor(() => expect(liveRow).not.toHaveTextContent("Active call"));
  });
});
