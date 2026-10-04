import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { GuestLinkEntry } from "./GuestLinkEntry";

function CurrentLocation() {
  const location = useLocation();
  return <output aria-label="Location">{location.pathname}{location.search}{location.hash}</output>;
}

describe("guest invite link entry", () => {
  it("opens the existing guest preview route for a pasted link", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/"]}><GuestLinkEntry /><CurrentLocation /></MemoryRouter>);
    await user.type(screen.getByLabelText("Room invite link"), `${window.location.origin}/join#guest=room-token`);
    await user.click(screen.getByRole("button", { name: "Open room invite" }));
    expect(screen.getByLabelText("Location")).toHaveTextContent("/join#guest=room-token");
    expect(screen.getByLabelText("Room invite link")).toHaveValue("");
  });
  it("retains entry and explains errors without navigating to an external link", async () => {
    const onJoin = vi.fn();
    const user = userEvent.setup();
    render(<MemoryRouter><GuestLinkEntry onJoin={onJoin} /></MemoryRouter>);
    await user.type(screen.getByLabelText("Room invite link"), "https://outside.test/join#guest=secret");
    await user.click(screen.getByRole("button", { name: "Open room invite" }));
    expect(onJoin).not.toHaveBeenCalled();
    expect(screen.getByRole("alert")).toHaveTextContent("for this K-Comms site");
    expect(screen.getByLabelText("Room invite link")).toHaveAttribute("aria-invalid", "true");
  });
});
