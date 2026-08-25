import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { MemberAreaLinks } from "./MemberAreaLinks";

describe("MemberAreaLinks", () => {
  it("keeps compact rail links icon-only visually and named for assistive technology", () => {
    render(
      <MemoryRouter initialEntries={["/app/"]}>
        <nav aria-label="Workspace navigation">
          <MemberAreaLinks compact />
        </nav>
      </MemoryRouter>
    );

    const navigation = screen.getByRole("navigation", { name: "Workspace navigation" });
    expect(navigation.querySelectorAll("svg")).toHaveLength(6);
    expect(screen.getByRole("link", { name: "Whiteboard" })).toHaveAttribute(
      "href",
      "/app/whiteboard"
    );
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute("title", "Inbox");
    expect(screen.getByRole("link", { name: "Inbox" }).querySelector("span")).toHaveClass(
      "visually-hidden"
    );
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "href",
      "/app/"
    );
  });

  /*
   * Five is a budget, not a preference: phones carry no overflow drawer, so a
   * sixth destination has nowhere to go. Whiteboard is the one that yields,
   * because member-ia.spec.ts encodes a two-action budget through Directory and
   * another through Files, and neither survives losing its tab. Whiteboard has
   * no such budget: it was two taps behind the drawer and is two taps from the
   * You screen.
   */
  it("keeps mobile primary navigation to the five daily destinations", () => {
    render(
      <MemoryRouter initialEntries={["/app/"]}>
        <nav aria-label="Primary navigation">
          <MemberAreaLinks variant="mobile-primary" />
        </nav>
      </MemoryRouter>
    );

    const navigation = screen.getByRole("navigation", { name: "Primary navigation" });
    expect(navigation.querySelectorAll("a")).toHaveLength(5);
    expect(screen.getByRole("link", { name: "Inbox" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Calls" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Directory" })).toHaveAttribute(
      "href",
      "/app/directory"
    );
    expect(screen.getByRole("link", { name: "Files" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "You" })).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Whiteboard" })).not.toBeInTheDocument();
  });

  it("groups desktop destinations and keeps Whiteboard in collaboration", () => {
    render(
      <MemoryRouter initialEntries={["/app/whiteboard"]}>
        <nav aria-label="Member areas">
          <MemberAreaLinks variant="grouped" />
        </nav>
      </MemoryRouter>
    );

    const collaboration = screen.getByRole("region", { name: "Collaborate" });
    expect(collaboration).toContainElement(screen.getByRole("link", { name: "Whiteboard" }));
    expect(screen.getByRole("link", { name: "Whiteboard" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(screen.getAllByRole("link")).toHaveLength(6);
  });
});
