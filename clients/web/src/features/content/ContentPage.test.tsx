import { act, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ContentPage } from "./ContentPage";

const harness = vi.hoisted(() => ({ unifiedSearch: vi.fn(),
  session: { access_token: "first", refresh_token: "refresh", tenant: { id: "workspace", status: "active" },
    user: { id: "member", tenant_id: "workspace", role: "member", status: "active", version: 1, account_type: "human", access_scope: "workspace" },
    device: { id: "device", user_id: "member", revoked_at: null as string | null } },
  conversations: [{ id: "team", title: "Product team" }]
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness, session: harness.session }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ conversations: harness.conversations }) }));
const results = { data: [{ id: "file", kind: "file", title: "Launch plan", excerpt: "Review agenda", path: "/app/files?conversation=team&file=file" }], facets: { file: 1 }, page: { has_more: false, next_cursor: null, source_limits: {} } };
beforeEach(() => {
  vi.resetAllMocks(); harness.session.access_token = "first"; harness.session.user.version = 1;
  harness.conversations = [{ id: "team", title: "Product team" }];
});

describe("Content hub", () => {
  it("opens the canonical libraries without preloading private content or hiding workspace navigation", () => {
    render(<MemoryRouter><ContentPage /><nav aria-label="Other navigation"><a href="/app/directory">Directory</a></nav></MemoryRouter>);
    const categories = screen.getByRole("navigation", { name: "Browse content" });
    expect(within(categories).getAllByRole("link").map(link => link.getAttribute("href")))
      .toEqual(["/app/files", "/app/documents", "/app/whiteboard", "/app/artifacts", "/app/saved"]);
    expect(screen.getByRole("region", { name: "Search workspace" })).toBeVisible();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Other navigation" })).toBeVisible();
    expect(harness.unifiedSearch).not.toHaveBeenCalled();
  });

  it("uses authorized workspace search and opens the exact source link", async () => {
    harness.unifiedSearch.mockResolvedValue(results);
    const user = userEvent.setup();
    render(<MemoryRouter><ContentPage /></MemoryRouter>);
    await user.type(screen.getByRole("searchbox"), "launch");
    await user.selectOptions(screen.getByRole("combobox", { name: "Content type" }), "file");
    await user.selectOptions(screen.getByRole("combobox", { name: "Conversation" }), "team");
    await user.click(screen.getByRole("button", { name: "Search" }));
    expect(harness.unifiedSearch).toHaveBeenCalledWith("launch", { kind: "file", conversation_id: "team", cursor: null, limit: 25 });
    expect(await screen.findByRole("link", { name: /Launch plan/ })).toHaveAttribute("href", "/app/files?conversation=team&file=file");
    expect(screen.getByRole("option", { name: "Files (1)" })).toBeInTheDocument();
  });

  it.each(["account", "authority", "membership"])("withdraws private search excerpts and facets after an in-place %s change", async (change) => {
    harness.unifiedSearch.mockResolvedValue(results);
    const user = userEvent.setup();
    const { rerender } = render(<MemoryRouter><ContentPage /></MemoryRouter>);
    await user.type(screen.getByRole("searchbox"), "launch");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await screen.findByRole("link", { name: /Launch plan/ });
    if (change === "account") harness.session.access_token = "second";
    if (change === "authority") harness.session.user.version = 2;
    if (change === "membership") harness.conversations = [];
    rerender(<MemoryRouter><ContentPage /></MemoryRouter>);
    expect(screen.queryByRole("link", { name: /Launch plan/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Files (1)" })).not.toBeInTheDocument();
    expect(screen.getByRole("searchbox")).toHaveValue("");
  });

  it("ignores an old pending search after authority changes", async () => {
    let resolve!: (value: typeof results) => void;
    harness.unifiedSearch.mockImplementation(() => new Promise(done => { resolve = done; }));
    const user = userEvent.setup();
    const { rerender } = render(<MemoryRouter><ContentPage /></MemoryRouter>);
    await user.type(screen.getByRole("searchbox"), "launch");
    await user.click(screen.getByRole("button", { name: "Search" }));
    harness.session.user.version = 2;
    rerender(<MemoryRouter><ContentPage /></MemoryRouter>);
    await act(async () => { resolve(results); });
    expect(screen.queryByRole("link", { name: /Launch plan/ })).not.toBeInTheDocument();
    expect(screen.getByRole("searchbox")).toHaveValue("");
  });
});
