import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { UnifiedSearchPanel } from "./UnifiedSearchPanel";

const completeSourceLimits = { messages: false, files: false, whiteboards: false, meetings: false, artifacts: false };

describe("unified search recovery and candidate scope", () => {
  it("exposes source limits, real destination links, facets and retained results on failure", async () => {
    const user = userEvent.setup();
    const unifiedSearch = vi.fn().mockResolvedValueOnce({ data: [{ id: "board-1", kind: "whiteboard", title: "Planning", excerpt: "Quarterly plan", conversation_id: "conv-1", occurred_at: "2026-10-04T12:00:00Z", score: 100, path: "/app/whiteboard?conversation=conv-1" }], facets: { whiteboard: 1 }, page: { has_more: false, next_cursor: null, source_limits: { ...completeSourceLimits, messages: true }, ranking_scope: "authorized_source_candidates", meeting_window_days: 732 } }).mockRejectedValueOnce(new Error("network interrupted"));
    render(<MemoryRouter><UnifiedSearchPanel api={{ unifiedSearch } as unknown as ApiClient} conversations={[]} onClose={vi.fn()} /></MemoryRouter>);
    await user.type(screen.getByRole("searchbox"), "plan");
    await user.click(screen.getByRole("button", { name: /^Search$/ }));
    expect(await screen.findByRole("link", { name: /Planning/ })).toHaveAttribute("href", "/app/whiteboard?conversation=conv-1");
    expect(screen.getByText(/Some sources reached their result limit/)).toBeVisible();
    expect(screen.getByRole("option", { name: "Boards (1)" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: /^Search$/ }));
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("network interrupted"));
    expect(screen.getByRole("link", { name: /Planning/ })).toBeVisible();
  });
  it.each([401, 403, 404])("clears prior private results and facets after a %s scope denial", async status => {
    const user = userEvent.setup();
    const unifiedSearch = vi.fn().mockResolvedValueOnce({ data: [{ id: "board-1", kind: "whiteboard", title: "Private planning", excerpt: "Quarterly plan", conversation_id: "conv-1", occurred_at: "2026-10-04T12:00:00Z", score: 100, path: "/app/whiteboard?conversation=conv-1" }], facets: { whiteboard: 1 }, page: { has_more: true, next_cursor: "cursor", source_limits: completeSourceLimits, ranking_scope: "authorized_source_candidates", meeting_window_days: 732 } }).mockRejectedValueOnce({ status });
    render(<MemoryRouter><UnifiedSearchPanel api={{ unifiedSearch } as unknown as ApiClient} conversations={[]} onClose={vi.fn()} /></MemoryRouter>);
    await user.type(screen.getByRole("searchbox"), "plan");
    await user.click(screen.getByRole("button", { name: /^Search$/ }));
    await screen.findByRole("link", { name: /Private planning/ });
    await user.click(screen.getByRole("button", { name: "More results" }));
    await screen.findByRole("alert");
    expect(screen.queryByRole("link", { name: /Private planning/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Boards (1)" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "More results" })).not.toBeInTheDocument();
  });
});
