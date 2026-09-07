import { act, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useAutoHideWhiteboardToolbar } from "./useAutoHideWhiteboardToolbar";

function Harness() {
  const { surfaceRef, hidden, reveal } = useAutoHideWhiteboardToolbar();
  return (
    <div ref={surfaceRef} data-hidden={hidden}>
      <div className="App-top-bar" />
      {hidden && <button type="button" onClick={reveal}>Show drawing tools</button>}
    </div>
  );
}

describe("useAutoHideWhiteboardToolbar", () => {
  afterEach(() => vi.useRealTimers());

  it("hides after idle and exposes a compact reveal affordance", () => {
    vi.useFakeTimers();
    render(<Harness />);

    act(() => vi.advanceTimersByTime(8_000));

    expect(document.querySelector(".App-top-bar")).toHaveAttribute(
      "aria-hidden",
      "true"
    );
    expect(screen.getByRole("button", { name: "Show drawing tools" })).toBeVisible();
  });

  it("reveals when the pointer dwells at the top edge", () => {
    vi.useFakeTimers();
    render(<Harness />);
    act(() => vi.advanceTimersByTime(8_000));
    expect(document.querySelector(".App-top-bar")).toHaveAttribute("aria-hidden", "true");

    act(() => {
      document.dispatchEvent(new PointerEvent("pointermove", { clientY: 4, pointerType: "mouse" }));
      vi.advanceTimersByTime(250);
    });

    expect(document.querySelector(".App-top-bar")).toHaveAttribute("aria-hidden", "false");
    expect(screen.queryByRole("button", { name: "Show drawing tools" })).not.toBeInTheDocument();
  });
});
