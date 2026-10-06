import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it } from "vitest";
import { WorkspaceToolNavigation } from "./WorkspaceToolNavigation";

const destinations = {
  "Private rooms": "/app/private", "Phone": "/app/calls/phone",
  "Shared documents": "/app/documents", "Recordings": "/app/artifacts",
  "Whiteboard": "/app/whiteboard", "Saved items": "/app/saved"
};

describe("WorkspaceToolNavigation", () => {
  it.each([
    { path: "/app", group: "Conversation tools", related: ["Private rooms", "Saved items"] },
    { path: "/app/calls/phone", group: "Call tools", related: ["Phone", "Recordings"] },
    { path: "/app/meetings", group: "Meeting content", related: ["Recordings"] }
  ])("keeps all tools reachable with relevant actions first at $path", ({ path, group, related }) => {
    render(<MemoryRouter initialEntries={[path]}><WorkspaceToolNavigation compact={false} /></MemoryRouter>);
    const navigation = screen.getByRole("navigation", { name: "Workspace tools" });
    const relatedGroup = screen.getByRole("region", { name: group });
    expect(within(relatedGroup).getAllByRole("link").map((link) => link.textContent)).toEqual(related);
    expect(navigation.firstElementChild).toBe(relatedGroup);
    expect(within(navigation).getAllByRole("link")).toHaveLength(6);
    Object.entries(destinations).forEach(([label, href]) => {
      expect(within(navigation).getByRole("link", { name: label })).toHaveAttribute("href", href);
    });
    ["Inbox", "Calls", "Meetings", "Content", "Files", "Directory"].forEach((name) => {
      expect(within(navigation).queryByRole("link", { name })).not.toBeInTheDocument();
    });
  });

  it.each(["/app/content", "/app/documents", "/app/files", "/app/whiteboard", "/app/artifacts", "/app/saved"])("groups libraries together at %s", (path) => {
    render(<MemoryRouter initialEntries={[path]}><WorkspaceToolNavigation compact={false} /></MemoryRouter>);
    expect(within(screen.getByRole("region", { name: "Content library" })).getAllByRole("link").map(link => link.textContent))
      .toEqual(["Files", "Shared documents", "Whiteboard", "Recordings", "Saved items"]);
    expect(within(screen.getByRole("region", { name: "Communication tools" })).getAllByRole("link").map(link => link.textContent))
      .toEqual(["Private rooms", "Phone"]);
  });

  it("keeps compact links labeled and identifies the active tool", () => {
    render(<MemoryRouter initialEntries={["/app/calls/phone"]}><WorkspaceToolNavigation compact /></MemoryRouter>);
    Object.entries(destinations).forEach(([label, href]) => {
      const link = screen.getByRole("link", { name: label });
      expect(link).toHaveAttribute("href", href);
      expect(link).toHaveAttribute("aria-label", label);
      expect(link).toHaveAttribute("title", label);
    });
    expect(screen.getByRole("link", { name: "Phone" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "Recordings" })).not.toHaveAttribute("aria-current");
  });

  it("retains the selected document and anchor when reopening its sidebar link", async () => {
    const route = "/app/documents?conversation=room%2Fone&document=notes#paragraph";
    function Location() { const value = useLocation(); return <output aria-label="Current route">{value.pathname}{value.search}{value.hash}</output>; }
    render(<MemoryRouter initialEntries={[route]}><WorkspaceToolNavigation compact={false} /><Location /></MemoryRouter>);
    const document = screen.getByRole("link", { name: "Shared documents" });
    expect(document).toHaveAttribute("href", route);
    await userEvent.setup().click(document);
    expect(screen.getByLabelText("Current route")).toHaveTextContent(route);
  });
});
