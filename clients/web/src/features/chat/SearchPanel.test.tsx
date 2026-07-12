import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import type { ApiClient } from "../../api";
import { SearchPanel } from "./SearchPanel";

function Harness() {
  const [open, setOpen] = useState(false);
  return <><button type="button" onClick={() => setOpen(true)}>Open search</button>{open && <SearchPanel api={{} as ApiClient} conversations={[]} users={[]} onClose={() => setOpen(false)} onSelect={() => undefined} />}</>;
}

describe("SearchPanel accessibility", () => {
  it("closes on Escape and restores focus to its trigger", async () => {
    const user = userEvent.setup();
    render(<Harness />);
    const trigger = screen.getByRole("button", { name: "Open search" });
    await user.click(trigger);
    expect(screen.getByRole("dialog", { name: "Search messages" })).toBeVisible();
    expect(screen.getByRole("searchbox")).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    expect(trigger).toHaveFocus();
  });
});
