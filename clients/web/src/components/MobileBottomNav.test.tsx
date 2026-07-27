import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { MemberAreaLinks, MobileBottomNav } from "./MobileBottomNav";

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

  it("keeps compact rail links icon-only visually and named for assistive technology", () => {
    render(
      <MemoryRouter initialEntries={["/app/"]}>
        <nav aria-label="Workspace navigation">
          <MemberAreaLinks compact />
        </nav>
      </MemoryRouter>
    );

    const navigation = screen.getByRole("navigation", { name: "Workspace navigation" });
    expect(navigation.querySelectorAll("svg")).toHaveLength(5);
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute("title", "Inbox");
    expect(screen.getByRole("link", { name: "Inbox" }).querySelector("span")).toHaveClass(
      "visually-hidden"
    );
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "aria-current",
      "page"
    );
  });
});
