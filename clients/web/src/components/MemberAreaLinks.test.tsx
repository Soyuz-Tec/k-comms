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
    expect(navigation.querySelectorAll("svg")).toHaveLength(5);
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
});
