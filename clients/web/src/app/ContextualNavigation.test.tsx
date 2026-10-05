import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import { ContextualNavigation, ContextualNavigationProvider, useContextualNavigation } from "./ContextualNavigation";

function Page() {
  const [draft, setDraft] = useState("");
  const { hasSidebarNavigation } = useContextualNavigation();
  return <main>
    <label>Draft<input value={draft} onChange={(event) => setDraft(event.currentTarget.value)} /></label>
    <output aria-label="Persistent sidebar">{String(hasSidebarNavigation)}</output>
    <ContextualNavigation><nav aria-label="Page navigation"><button type="button">Profile</button></nav></ContextualNavigation>
  </main>;
}

describe("ContextualNavigation", () => {
  it("keeps standalone page navigation and reports no sidebar outside the shell", () => {
    render(<Page />);
    expect(screen.getByRole("main")).toContainElement(screen.getByRole("navigation", { name: "Page navigation" }));
    expect(screen.getByLabelText("Persistent sidebar")).toHaveTextContent("false");
  });

  it("moves only navigation while preserving the owning page draft", async () => {
    const target = document.createElement("aside");
    document.body.append(target);
    try {
      const view = render(<ContextualNavigationProvider target={null} hasSidebarNavigation={false}><Page /></ContextualNavigationProvider>);
      const draft = screen.getByRole("textbox", { name: "Draft" });
      await userEvent.setup().type(draft, "An unsaved profile change");

      view.rerender(<ContextualNavigationProvider target={target} hasSidebarNavigation={true}><Page /></ContextualNavigationProvider>);
      expect(target).toContainElement(screen.getByRole("navigation", { name: "Page navigation" }));
      expect(target).not.toContainElement(draft);
      expect(screen.getByRole("main")).not.toContainElement(screen.getByRole("navigation", { name: "Page navigation" }));
      expect(screen.getByLabelText("Persistent sidebar")).toHaveTextContent("true");

      // An unpinned dock can still receive navigation without replacing
      // persistent in-page shortcuts.
      view.rerender(<ContextualNavigationProvider target={target} hasSidebarNavigation={false}><Page /></ContextualNavigationProvider>);
      expect(target).toContainElement(screen.getByRole("navigation", { name: "Page navigation" }));
      expect(screen.getByLabelText("Persistent sidebar")).toHaveTextContent("false");

      view.rerender(<ContextualNavigationProvider target={null} hasSidebarNavigation={false}><Page /></ContextualNavigationProvider>);
      expect(screen.getByRole("main")).toContainElement(screen.getByRole("navigation", { name: "Page navigation" }));
      expect(screen.getByRole("textbox", { name: "Draft" })).toBe(draft);
      expect(draft).toHaveValue("An unsaved profile change");
      expect(target).toBeEmptyDOMElement();
    } finally {
      target.remove();
    }
  });
});
