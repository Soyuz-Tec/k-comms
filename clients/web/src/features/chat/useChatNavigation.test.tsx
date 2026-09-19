import { useEffect, useLayoutEffect, useState } from "react";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation, useNavigate, useSearchParams } from "react-router";
import { describe, expect, it } from "vitest";
import type { Conversation } from "../../types";
import { useChatNavigation } from "./useChatNavigation";

const conversations = [{ id: "general" }, { id: "operations" }] as Conversation[];
const threadLink = "/app/?conversation=operations&message=selected-thread";

function ColdRoute() {
  const [loaded, setLoaded] = useState(false);
  useEffect(() => setLoaded(true), []);
  return loaded ? <Navigation pendingNotification /> : null;
}

function Navigation({ rows = conversations, pendingNotification = false }: {
  rows?: Conversation[];
  pendingNotification?: boolean;
}) {
  const [params, setSearchParams] = useSearchParams();
  const location = useLocation();
  const navigate = useNavigate();
  const { activeConversationId } = useChatNavigation({
    requestedConversationId: params.get("conversation"),
    conversations: rows,
    setSearchParams,
    workspaceLoading: false,
    closeConversationPanels: () => {}
  });
  // A user navigation has reached history while the cold inbox's initial
  // passive effects are still pending. No timer or retry controls the order.
  useLayoutEffect(() => {
    if (pendingNotification) void navigate(threadLink);
  }, [navigate, pendingNotification]);
  return <>
    <output aria-label="active conversation">{activeConversationId}</output>
    <output aria-label="location">{location.pathname}{location.search}</output>
  </>;
}

describe("inbox default selection", () => {
  it("does not replace a notification destination from the cold route's stale effect", async () => {
    render(<MemoryRouter initialEntries={["/app/"]}><ColdRoute /></MemoryRouter>);
    await waitFor(() => expect(screen.getByLabelText("location")).toHaveTextContent(threadLink));
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("operations");
  });

  it("shows a stable desktop default without changing the URL when activity reorders conversations", () => {
    const { rerender } = render(<MemoryRouter initialEntries={["/app/?source=inbox"]}><Navigation /></MemoryRouter>);
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("general");
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/?source=inbox");
    rerender(<MemoryRouter><Navigation rows={[...conversations].reverse()} /></MemoryRouter>);
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("general");
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/?source=inbox");
  });

  it("does not replace an explicit unavailable conversation with an unrelated default", () => {
    render(<MemoryRouter initialEntries={["/app/?conversation=unavailable&message=selected-thread"]}><Navigation /></MemoryRouter>);
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("unavailable");
    expect(screen.getByLabelText("location")).toHaveTextContent("conversation=unavailable&message=selected-thread");
  });

  it("selects a valid remaining default after the displayed conversation disappears", () => {
    const { rerender } = render(<MemoryRouter initialEntries={["/app/"]}><Navigation /></MemoryRouter>);
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("general");
    rerender(<MemoryRouter><Navigation rows={[conversations[1]!]} /></MemoryRouter>);
    expect(screen.getByLabelText("active conversation")).toHaveTextContent("operations");
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/");
  });
});
