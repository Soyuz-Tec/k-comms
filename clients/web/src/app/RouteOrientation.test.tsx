import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { RouteOrientation } from "./RouteOrientation";

function Harness() {
  return (
    <>
      <RouteOrientation />
      <nav><Link to="/app/settings">Settings</Link></nav>
      <Routes>
        <Route path="/app" element={<main id="main-content"><h1>Conversations</h1></main>} />
        <Route path="/app/settings" element={<main id="main-content"><h1>Profile and settings</h1></main>} />
      </Routes>
    </>
  );
}

describe("RouteOrientation", () => {
  it("updates the document title and moves focus to the routed heading", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);

    const conversations = screen.getByRole("heading", { name: "Conversations" });
    await waitFor(() => expect(conversations).toHaveFocus());
    expect(document.title).toBe("Messages | K-Comms");

    await user.click(screen.getByRole("link", { name: "Settings" }));
    const settings = screen.getByRole("heading", { name: "Profile and settings" });
    await waitFor(() => expect(settings).toHaveFocus());
    expect(document.title).toBe("Profile and settings | K-Comms");
    expect(screen.getByText("Profile and settings view")).toHaveAttribute("aria-live", "polite");
  });
});
