import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { WhiteboardPage } from "./WhiteboardPage";

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
});
