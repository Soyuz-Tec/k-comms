import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { participantDisambiguator } from "../../lib/participantIdentity";
import type { Conversation, Message, User } from "../../types";
import { SearchPanel } from "./SearchPanel";

const conversations: Conversation[] = [
  { id: "general", tenant_id: "tenant-1", kind: "channel", title: "General", counterpart_user_id: null, counterpart_display_name: null, visibility: "tenant", latest_sequence: 2, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" },
  { id: "projects", tenant_id: "tenant-1", kind: "group", title: "Projects", counterpart_user_id: null, counterpart_display_name: null, visibility: "private", latest_sequence: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" }
];

const users: User[] = [
  { id: "ada", tenant_id: "tenant-1", display_name: "Ada", role: "member", status: "active" },
  { id: "grace", tenant_id: "tenant-1", display_name: "Grace", role: "member", status: "active" }
];

function result(id: string, conversationId: string, senderId: string, body: string, insertedAt = new Date().toISOString()): Message {
  return {
    id,
    tenant_id: "tenant-1",
    conversation_id: conversationId,
    sender_user_id: senderId,
    sender_device_id: "device-1",
    client_message_id: `client-${id}`,
    conversation_sequence: 1,
    body,
    metadata: {},
    status: "active",
    inserted_at: insertedAt,
    attachments: [],
    reactions: []
  };
}

function Harness() {
  const [open, setOpen] = useState(false);
  return <><button type="button" onClick={() => setOpen(true)}>Open search</button>{open && <SearchPanel api={{} as ApiClient} conversations={[]} users={[]} onClose={() => setOpen(false)} onSelect={() => undefined} />}</>;
}

describe("SearchPanel accessibility", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("closes on Escape and restores focus to its trigger", async () => {
    const user = userEvent.setup();
    render(<Harness />);
    const trigger = screen.getByRole("button", { name: "Open search" });
    await user.click(trigger);
    expect(screen.getByRole("dialog", { name: "Search messages" })).toBeVisible();
    expect(screen.getByRole("searchbox")).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    expect(trigger).toHaveFocus();
  });

  it("submits authorized server filters, appends cursor pages, and supports result navigation", async () => {
    const user = userEvent.setup();
    const onSelect = vi.fn();
    const searchMessagePage = vi
      .fn()
      .mockResolvedValueOnce({
        data: [
          result("one", "general", "ada", "First result"),
          result("two", "general", "ada", "Second result")
        ],
        page: { limit: 25, has_more: true, next_cursor: "page-two" }
      })
      .mockResolvedValueOnce({
        data: [result("three", "general", "ada", "Third result")],
        page: { limit: 25, has_more: false, next_cursor: null }
      });
    const api = { searchMessagePage } as unknown as ApiClient;

    render(<SearchPanel api={api} conversations={conversations} users={users} onClose={() => undefined} onSelect={onSelect} />);
    await user.type(screen.getByRole("searchbox"), "roadmap");
    await user.selectOptions(screen.getByLabelText("Conversation"), "general");
    await user.selectOptions(screen.getByLabelText("Sender"), "ada");
    await user.selectOptions(screen.getByLabelText("Date"), "day");
    await user.click(screen.getByRole("button", { name: "Search" }));

    await waitFor(() => expect(searchMessagePage).toHaveBeenCalledWith("roadmap", expect.objectContaining({
      limit: 25,
      cursor: null,
      conversation_id: "general",
      sender_user_id: "ada",
      after: expect.any(String)
    })));
    expect(screen.getByRole("status")).toHaveTextContent("2 results shown");

    const firstButton = screen.getByText("First result").closest("button");
    const secondButton = screen.getByText("Second result").closest("button");
    expect(firstButton).not.toBeNull();
    expect(secondButton).not.toBeNull();
    firstButton?.focus();
    await user.keyboard("{ArrowDown}");
    expect(secondButton).toHaveFocus();
    await user.keyboard("{Enter}");
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ id: "two" }));

    await user.click(screen.getByRole("button", { name: "Load more results" }));
    await waitFor(() => expect(searchMessagePage).toHaveBeenLastCalledWith("roadmap", expect.objectContaining({ cursor: "page-two" })));
    expect(screen.getByText("Third result")).toBeVisible();
    expect(screen.getByRole("status")).toHaveTextContent("3 results shown");
  });

  it("retains sender labels across result pages and disambiguates duplicate names", async () => {
    const user = userEvent.setup();
    const firstDepartedId = "departed-user-1";
    const secondDepartedId = "departed-user-2";
    const deletedId = "deleted-user-1";
    const searchMessagePage = vi
      .fn()
      .mockResolvedValueOnce({
        data: [
          result("one", "general", firstDepartedId, "First retained result"),
          result("two", "general", secondDepartedId, "Second retained result")
        ],
        included: {
          sender_labels: [
            { id: firstDepartedId, display_name: "Former teammate", redacted: false },
            { id: secondDepartedId, display_name: "Former teammate", redacted: false }
          ]
        },
        page: { limit: 25, has_more: true, next_cursor: "page-two" }
      })
      .mockResolvedValueOnce({
        data: [result("three", "general", deletedId, "Deleted author result")],
        included: {
          sender_labels: [{ id: deletedId, display_name: "Deleted user", redacted: true }]
        },
        page: { limit: 25, has_more: false, next_cursor: null }
      });

    render(
      <SearchPanel
        api={{ searchMessagePage } as unknown as ApiClient}
        conversations={conversations}
        users={users}
        onClose={() => undefined}
        onSelect={() => undefined}
      />
    );

    await user.type(screen.getByRole("searchbox"), "retained");
    await user.click(screen.getByRole("button", { name: "Search" }));

    expect(
      await screen.findByText(
        `Former teammate · #${participantDisambiguator(firstDepartedId)}`
      )
    ).toBeVisible();
    expect(
      screen.getByText(
        `Former teammate · #${participantDisambiguator(secondDepartedId)}`
      )
    ).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Load more results" }));
    expect(await screen.findByText("Deleted user")).toBeVisible();
    expect(screen.queryByText("Unknown user")).not.toBeInTheDocument();
  });

  it("refreshes erased and renamed labels with bounded, failure-isolated requests", async () => {
    const scheduledRefreshes: Array<{ handler: () => void; delay: number }> = [];
    const nativeSetTimeout = window.setTimeout.bind(window);
    vi.spyOn(window, "setTimeout").mockImplementation(
      ((handler: TimerHandler, timeout?: number) => {
        if (
          typeof handler === "function" &&
          [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
        ) {
          scheduledRefreshes.push({
            handler: handler as () => void,
            delay: timeout || 0
          });
        }
        return [30_000, 60_000, 120_000, 300_000].includes(timeout || 0)
          ? 1_000_000 + scheduledRefreshes.length
          : nativeSetTimeout(handler, timeout);
      }) as typeof window.setTimeout
    );
    const departedUserId = "departed-user";
    const searchMessagePage = vi.fn().mockResolvedValue({
      data: [
        result("one", "general", "grace", "General result"),
        result("one-again", "general", "grace", "Second General result"),
        result("two", "projects", "grace", "Project result"),
        result("three", "general", "ada", "Ada result"),
        result("four", "general", departedUserId, "Former teammate result")
      ],
      included: {
        sender_labels: [
          {
            id: departedUserId,
            display_name: "Former teammate",
            redacted: false
          }
        ]
      },
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    const messageSenderLabels = vi.fn().mockImplementation(
      async (resultConversationId: string) =>
        resultConversationId === "general"
          ? [
              { id: "grace", display_name: "Deleted user", redacted: true },
              {
                id: departedUserId,
                display_name: "Renamed teammate",
                redacted: false
              }
            ]
          : Promise.reject(new Error("Projects label lookup failed"))
    );
    const api = {
      searchMessagePage,
      messageSenderLabels
    } as unknown as ApiClient;
    const user = userEvent.setup();
    const view = render(
      <SearchPanel
        api={api}
        conversations={conversations}
        users={users}
        onClose={() => undefined}
        onSelect={() => undefined}
      />
    );

    await user.type(screen.getByRole("searchbox"), "result");
    await user.click(screen.getByRole("button", { name: "Search" }));
    expect(await screen.findByText("General result")).toBeVisible();
    const resultList = document.querySelector<HTMLElement>(".search-results");
    expect(resultList).not.toBeNull();
    expect(within(resultList!).getAllByText("Grace")).toHaveLength(3);
    expect(within(resultList!).getByText("Former teammate")).toBeVisible();
    expect(scheduledRefreshes.at(-1)?.delay).toBe(30_000);

    await act(async () => {
      scheduledRefreshes.at(-1)?.handler();
      await Promise.resolve();
    });

    await waitFor(() => {
      expect(messageSenderLabels).toHaveBeenCalledWith(
        "general",
        ["one", "three", "four"]
      );
      expect(messageSenderLabels).toHaveBeenCalledWith(
        "projects",
        ["two"]
      );
    });
    expect(
      await within(resultList!).findAllByText("Deleted user")
    ).toHaveLength(3);
    expect(within(resultList!).queryByText("Grace")).not.toBeInTheDocument();
    expect(within(resultList!).getByText("Renamed teammate")).toBeVisible();
    expect(within(resultList!).queryByText("Former teammate"))
      .not.toBeInTheDocument();
    expect(scheduledRefreshes.at(-1)?.delay).toBe(30_000);
    expect(messageSenderLabels).toHaveBeenCalledTimes(2);
    expect(searchMessagePage).toHaveBeenCalledTimes(1);

    view.unmount();
  });
});
