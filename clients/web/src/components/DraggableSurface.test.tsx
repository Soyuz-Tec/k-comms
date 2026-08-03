import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { DraggableSurface } from "./DraggableSurface";

describe("DraggableSurface", () => {
  it("offers a keyboard move handle and keeps the translated surface in view", () => {
    const { container } = render(
      <DraggableSurface dragLabel="messages">
        <p>Conversation</p>
      </DraggableSurface>
    );
    const surface = container.querySelector(".draggable-surface") as HTMLDivElement;
    vi.spyOn(surface, "getBoundingClientRect").mockReturnValue(
      new DOMRect(20, 20, 180, 120)
    );

    const handle = screen.getByRole("button", { name: "Move messages" });
    fireEvent.keyDown(handle, { key: "ArrowRight" });
    expect(surface).toHaveStyle({ transform: "translate3d(8px, 0px, 0)" });

    fireEvent.keyDown(handle, { key: "ArrowDown", shiftKey: true });
    expect(surface).toHaveStyle({ transform: "translate3d(8px, 32px, 0)" });
  });
});
