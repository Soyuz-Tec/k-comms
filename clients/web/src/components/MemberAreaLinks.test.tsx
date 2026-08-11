import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { MemberAreaLinks, memberAreaTitle } from "./MemberAreaLinks";

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
    expect(screen.getByRole("link", { name: "Directory" })).toBeInTheDocument();
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

  it("keeps Whiteboard in the mobile More menu", () => {
    render(
      <MemoryRouter>
        <nav aria-label="More product areas">
          <MemberAreaLinks variant="mobile-more" />
        </nav>
      </MemoryRouter>
    );

    expect(screen.getByRole("link", { name: "Whiteboard" })).toHaveAttribute(
      "href",
      "/app/whiteboard"
    );
    expect(screen.getAllByRole("link")).toHaveLength(1);
  });
});

describe("memberAreaTitle", () => {
  it("names every destination the mobile top bar can land on", () => {
    expect(memberAreaTitle("/app/")).toBe("Inbox");
    expect(memberAreaTitle("/app")).toBe("Inbox");
    expect(memberAreaTitle("/app/calls")).toBe("Calls");
    expect(memberAreaTitle("/app/directory")).toBe("Directory");
    expect(memberAreaTitle("/app/files")).toBe("Files");
    expect(memberAreaTitle("/app/whiteboard")).toBe("Whiteboard");
  });

  it("uses the settings wording for You, matching the page heading", () => {
    expect(memberAreaTitle("/app/you")).toBe("Profile and settings");
  });

  it("covers the role areas reachable from the More drawer", () => {
    expect(memberAreaTitle("/admin")).toBe("Workspace administration");
    expect(memberAreaTitle("/admin/")).toBe("Workspace administration");
    expect(memberAreaTitle("/ops")).toBe("Service operations");
  });

  it("keeps a nested route under its own area rather than falling back to Inbox", () => {
    expect(memberAreaTitle("/app/files/archive")).toBe("Files");
    expect(memberAreaTitle("/admin/people")).toBe("Workspace administration");
  });

  it("falls back to the product name for routes outside the member areas", () => {
    expect(memberAreaTitle("/join")).toBe("K-Comms");
  });
});
