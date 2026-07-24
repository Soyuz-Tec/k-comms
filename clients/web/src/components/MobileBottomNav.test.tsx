import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { MobileBottomNav } from "./MobileBottomNav";

describe("MobileBottomNav", () => {
  it("exposes exactly the five member destinations and marks the current one", () => {
    render(
      <MemoryRouter initialEntries={["/app/directory"]}>
        <MobileBottomNav />
      </MemoryRouter>
    );

    const navigation = screen.getByRole("navigation", { name: "Mobile product areas" });
    const links = Array.from(navigation.querySelectorAll("a"));
    expect(links.map((link) => link.textContent)).toEqual([
      "Inbox",
      "Calls",
      "Directory",
      "Files",
      "You"
    ]);
    expect(screen.getByRole("link", { name: "Directory" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(navigation).not.toHaveTextContent("Admin");
    expect(navigation).not.toHaveTextContent("Operations");
  });
});
