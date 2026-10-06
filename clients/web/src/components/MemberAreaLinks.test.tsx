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
    expect(navigation.querySelectorAll("svg")).toHaveLength(13);
    expect(screen.getByRole("link", { name: "Meetings" })).toHaveAttribute("href", "/app/meetings");
    expect(screen.getByRole("link", { name: "Saved items" })).toHaveAttribute("href", "/app/saved");
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
    expect(screen.queryByRole("link", { name: "Meetings" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Saved items" })).not.toBeInTheDocument();
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
    expect(screen.getByRole("region", { name: "Communicate" })).toContainElement(screen.getByRole("link", { name: "Meetings" }));
    expect(screen.getByRole("region", { name: "Personal" })).toContainElement(screen.getByRole("link", { name: "Saved items" }));
    expect(screen.getAllByRole("link")).toHaveLength(13);
  });

  it("makes phone and collaboration libraries discoverable and marks only the current calling destination", () => {
    render(<MemoryRouter initialEntries={["/app/calls/phone"]}><MemberAreaLinks variant="grouped" /></MemoryRouter>);
    expect(screen.getByRole("link", { name: "Phone" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "Calls" })).not.toHaveAttribute("aria-current");
    expect(screen.getByRole("link", { name: "Shared documents" })).toHaveAttribute("href", "/app/documents");
    expect(screen.getByRole("link", { name: "Recordings" })).toHaveAttribute("href", "/app/artifacts");
  });

  it("selects the mobile Calls parent while using Phone", () => {
    render(<MemoryRouter initialEntries={["/app/calls/phone"]}><nav><MemberAreaLinks variant="mobile-primary" /></nav></MemoryRouter>);
    expect(screen.getByRole("link", { name: "Calls" })).toHaveAttribute("aria-current", "page");
    expect(screen.getAllByRole("link").filter(link => link.getAttribute("aria-current") === "page")).toHaveLength(1);
  });
});
