import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { beforeEach, describe, expect, it } from "vitest";
import {
  CONVERSATION_SIDEBAR_DEFAULT_WIDTH,
  CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY,
  ConversationColumnResizer,
  persistConversationSidebarWidth,
  readConversationSidebarWidth
} from "./ConversationColumnResizer";

function ResizerHarness() {
  const [width, setWidth] = useState(CONVERSATION_SIDEBAR_DEFAULT_WIDTH);
  return (
    <div>
      <ConversationColumnResizer width={width} onWidthChange={setWidth} />
      <output>{width}</output>
    </div>
  );
}

describe("ConversationColumnResizer", () => {
  beforeEach(() => window.localStorage.clear());

  it("supports precise and bounded keyboard resizing", () => {
    render(<ResizerHarness />);
    const separator = screen.getByRole("separator", {
      name: "Resize conversation list"
    });

    expect(separator).toHaveAttribute("aria-valuenow", "340");
    fireEvent.keyDown(separator, { key: "ArrowRight" });
    expect(separator).toHaveAttribute("aria-valuenow", "356");
    fireEvent.keyDown(separator, { key: "ArrowLeft", shiftKey: true });
    expect(separator).toHaveAttribute("aria-valuenow", "316");
    fireEvent.keyDown(separator, { key: "Home" });
    expect(separator).toHaveAttribute("aria-valuenow", "280");
    fireEvent.doubleClick(separator);
    expect(separator).toHaveAttribute("aria-valuenow", "340");
  });

  it("persists only a clamped numeric width", () => {
    persistConversationSidebarWidth(900);
    expect(window.localStorage.getItem(
      CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY
    )).toBe("520");
    expect(readConversationSidebarWidth()).toBe(520);

    window.localStorage.setItem(CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY, "invalid");
    expect(readConversationSidebarWidth()).toBe(
      CONVERSATION_SIDEBAR_DEFAULT_WIDTH
    );
  });
});
