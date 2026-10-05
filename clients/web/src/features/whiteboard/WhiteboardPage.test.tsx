import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { WhiteboardPage } from "./WhiteboardPage";

const session = vi.hoisted(() => ({ api: { boardGallery: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => session }));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    conversations: [
      { id: "conversation-one", title: "Product planning" },
      { id: "conversation-two", title: "Delivery team" }
    ],
    loading: false
  })
}));

vi.mock("./CollaborativeWhiteboard", () => ({
  CollaborativeWhiteboard: ({ conversationTitle }: { conversationTitle: string }) => (
    <section aria-label={`Whiteboard for ${conversationTitle}`} />
  )
}));

function CurrentLocation() {
  const location = useLocation();
  return <output aria-label="Current location">{location.pathname}{location.search}</output>;
}

describe("WhiteboardPage workspace bar", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    session.api.boardGallery.mockReset().mockResolvedValue({ data: [], page: { truncated: false } });
  });
  it.each(["missing-conversation", ""])("does not open another board for an unavailable explicit target %s", async (target) => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={[`/app/whiteboard?conversation=${target}&focus_elements=old-shape`]}><WhiteboardPage /><CurrentLocation /></MemoryRouter>);
    expect(screen.getByRole("alert")).toHaveTextContent("Board unavailable");
    expect(screen.queryByRole("region", { name: /Whiteboard for/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Open conversation" })).not.toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "Conversation" })).toHaveValue("");
    await user.selectOptions(screen.getByRole("combobox", { name: "Conversation" }), "conversation-two");
    expect(screen.getByRole("region", { name: "Whiteboard for Delivery team" })).toBeVisible();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Current location")).toHaveTextContent("/app/whiteboard?conversation=conversation-two");
    expect(screen.getByLabelText("Current location")).not.toHaveTextContent("focus_elements");
  });

  it("defaults to the first board only when no conversation was requested", () => {
    render(<MemoryRouter initialEntries={["/app/whiteboard"]}><WhiteboardPage /></MemoryRouter>);
    expect(screen.getByRole("region", { name: "Whiteboard for Product planning" })).toBeVisible();
  });
  it("keeps the compact chat action named and scoped to the selected conversation", async () => {
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/app/whiteboard?conversation=conversation-one"]}>
        <WhiteboardPage />
        <CurrentLocation />
      </MemoryRouter>
    );

    expect(screen.getByRole("heading", { name: "Whiteboard", level: 1 })).toBeVisible();
    const chat = screen.getByRole("link", { name: "Open conversation" });
    expect(chat).toHaveTextContent("Chat");
    expect(chat).toHaveAttribute("href", "/app/?conversation=conversation-one");

    await user.selectOptions(screen.getByRole("combobox", { name: "Conversation" }), "conversation-two");

    expect(screen.getByRole("region", { name: "Whiteboard for Delivery team" })).toBeVisible();
    expect(chat).toHaveAttribute("href", "/app/?conversation=conversation-two");
    expect(screen.getByLabelText("Current location")).toHaveTextContent(
      "/app/whiteboard?conversation=conversation-two"
    );
  });

  it("opens a gallery board in its selected conversation and clears old element focus", async () => {
    session.api.boardGallery.mockResolvedValue({ data: [{ id: "board-two", conversation_id: "conversation-two", title: "Delivery roadmap", sequence: 4, library_version: 1, updated_at: "2026-10-04T12:00:00Z" }], page: { truncated: false } });
    render(<MemoryRouter initialEntries={["/app/whiteboard?conversation=conversation-one&focus_elements=old-element"]}><WhiteboardPage /><CurrentLocation /></MemoryRouter>);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Board gallery" }));
    const board = await screen.findByRole("button", { name: /Delivery roadmap/ });
    expect(within(board).getByText("Delivery team")).toBeVisible();
    expect(within(board).getByText(/Updated/)).toHaveAttribute("datetime", "2026-10-04T12:00:00Z");
    await user.click(board);
    expect(session.api.boardGallery).toHaveBeenCalledWith("");
    expect(screen.getByRole("region", { name: "Whiteboard for Delivery team" })).toBeVisible();
    expect(screen.getByRole("link", { name: "Open conversation" })).toHaveAttribute("href", "/app/?conversation=conversation-two");
    expect(screen.getByLabelText("Current location")).toHaveTextContent("/app/whiteboard?conversation=conversation-two");
    expect(screen.getByLabelText("Current location")).not.toHaveTextContent("focus_elements");
    expect(screen.queryByRole("region", { name: "Whiteboard gallery" })).not.toBeInTheDocument();
  });

  it("keeps a stale gallery destination unavailable instead of opening a different board", async () => {
    session.api.boardGallery.mockResolvedValue({ data: [{ id: "old-board", conversation_id: "removed-conversation", title: "Previously available", sequence: 4, library_version: 1, updated_at: "2026-10-04T12:00:00Z" }], page: { truncated: false } });
    render(<MemoryRouter initialEntries={["/app/whiteboard?conversation=conversation-one"]}><WhiteboardPage /><CurrentLocation /></MemoryRouter>);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Board gallery" }));
    await user.click(await screen.findByRole("button", { name: /Previously available/ }));
    expect(screen.getByRole("alert")).toHaveTextContent("Board unavailable");
    expect(screen.queryByRole("region", { name: /Whiteboard for/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Open conversation" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("Current location")).toHaveTextContent("conversation=removed-conversation");
  });

  it.each([
    { label: "network failure", reason: new Error("Network interrupted"), retains: true },
    { label: "scope denial", reason: { status: 403 }, retains: false }
  ])("handles gallery $label without retaining revoked metadata", async ({ reason, retains }) => {
    session.api.boardGallery.mockResolvedValueOnce({ data: [{ id: "board-two", conversation_id: "conversation-two", title: "Private roadmap", sequence: 4, library_version: 1, updated_at: "2026-10-04T12:00:00Z" }], page: { truncated: true } }).mockRejectedValueOnce(reason);
    render(<MemoryRouter initialEntries={["/app/whiteboard?conversation=conversation-one"]}><WhiteboardPage /></MemoryRouter>);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Board gallery" }));
    await screen.findByRole("button", { name: /Private roadmap/ });
    await user.type(screen.getByRole("searchbox", { name: "Find a board" }), "x");
    await screen.findByRole("alert");
    if (retains) expect(screen.getByRole("button", { name: /Private roadmap/ })).toBeVisible();
    else {
      expect(screen.queryByRole("button", { name: /Private roadmap/ })).not.toBeInTheDocument();
      expect(screen.queryByText(/Showing the most recent/)).not.toBeInTheDocument();
    }
    expect(screen.getByRole("region", { name: "Whiteboard for Product planning" })).toBeVisible();
  });
});
