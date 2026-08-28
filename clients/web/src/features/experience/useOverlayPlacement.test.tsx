import { act, fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useOverlayPlacement } from "./useOverlayPlacement";
import { OVERLAY_EDGE_GAP } from "./overlay-placement";

const SURFACE = { width: 200, height: 100 };
const STORAGE_KEY = "test.overlay.placement";

/**
 * The surface is measured with getBoundingClientRect, which jsdom always
 * reports as zero. Each test stubs it so the hook has a real box to place,
 * and reports the element's own top/left so a drag can be followed.
 */
function stubSurfaceRect(element: HTMLElement) {
  element.getBoundingClientRect = () => {
    const top = Number.parseFloat(element.style.top || "0");
    const left = Number.parseFloat(element.style.left || "0");
    return {
      top,
      left,
      width: SURFACE.width,
      height: SURFACE.height,
      right: left + SURFACE.width,
      bottom: top + SURFACE.height,
      x: left,
      y: top,
      toJSON: () => ({})
    } as DOMRect;
  };
}

let renderCount = 0;

function Overlay({ storageKey }: { storageKey?: string }) {
  const { surfaceRef, style, handleProps, applyPreset, activePreset, dragging, placement } =
    useOverlayPlacement({ storageKey });
  renderCount += 1;
  return (
    <div
      data-testid="surface"
      data-dragging={dragging}
      data-placement={`${placement.x.toFixed(3)},${placement.y.toFixed(3)}`}
      ref={(node) => {
        surfaceRef.current = node;
        if (node) stubSurfaceRect(node);
      }}
      style={style}
    >
      <button data-testid="handle" type="button" aria-label="Move call" {...handleProps} />
      <button type="button" onClick={() => applyPreset("top-left")}>Top left</button>
      <span data-testid="active-preset">{activePreset ?? "none"}</span>
    </div>
  );
}

function surface() {
  return screen.getByTestId("surface");
}

function drag(from: { x: number; y: number }, to: { x: number; y: number }) {
  const handle = screen.getByTestId("handle");
  handle.setPointerCapture = vi.fn();
  handle.hasPointerCapture = vi.fn(() => true);
  handle.releasePointerCapture = vi.fn();
  fireEvent.pointerDown(handle, { button: 0, pointerId: 1, clientX: from.x, clientY: from.y });
  fireEvent.pointerMove(handle, { pointerId: 1, clientX: to.x, clientY: to.y });
  fireEvent.pointerUp(handle, { pointerId: 1, clientX: to.x, clientY: to.y });
}

describe("useOverlayPlacement", () => {
  beforeEach(() => {
    window.localStorage.clear();
    renderCount = 0;
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1000 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 600 });
  });

  it("rests at the default preset, inside the edge gap", () => {
    render(<Overlay />);
    expect(surface().style.left).toBe(`${1000 - SURFACE.width - OVERLAY_EDGE_GAP}px`);
    expect(surface().style.top).toBe(`${600 - SURFACE.height - OVERLAY_EDGE_GAP}px`);
    expect(screen.getByTestId("active-preset")).toHaveTextContent("bottom-right");
  });

  it("does not render once per pointer frame", () => {
    // The contract is explicit: keep pointer coordinates in refs and commit
    // React state only on semantic changes. A render per pointermove is what
    // makes a drag drop frames.
    render(<Overlay />);
    const handle = screen.getByTestId("handle");
    handle.setPointerCapture = vi.fn();
    handle.hasPointerCapture = vi.fn(() => true);
    handle.releasePointerCapture = vi.fn();

    fireEvent.pointerDown(handle, { button: 0, pointerId: 1, clientX: 800, clientY: 500 });
    const afterPress = renderCount;

    for (let step = 0; step < 30; step += 1) {
      fireEvent.pointerMove(handle, { pointerId: 1, clientX: 800 - step * 5, clientY: 500 - step * 3 });
    }
    expect(renderCount).toBe(afterPress);

    // The move is still visible: it is written straight to the compositor.
    expect(surface().style.transform).toMatch(/^translate3d\(-?\d/);

    fireEvent.pointerUp(handle, { pointerId: 1, clientX: 655, clientY: 413 });
    expect(renderCount).toBeGreaterThan(afterPress);
    expect(surface().style.transform).toBe("");
  });

  it("commits the placement once the pointer is released", () => {
    render(<Overlay />);
    // Resting bottom-right at top 492 / left 792, so this drag carries the
    // surface past both start edges and it settles clamped in the corner.
    drag({ x: 900, y: 550 }, { x: 0, y: 0 });
    expect(surface().dataset.placement).toBe("0.000,0.000");
    expect(screen.getByTestId("active-preset")).toHaveTextContent("top-left");
  });

  it("commits the proportion actually dragged, not the nearest corner", () => {
    render(<Overlay />);
    // Up 450px from top 492 lands at 42, which is 34px into 484px of travel.
    drag({ x: 900, y: 550 }, { x: 100, y: 100 });
    expect(surface().dataset.placement).toBe("0.000,0.070");
    expect(screen.getByTestId("active-preset")).toHaveTextContent("none");
  });

  it("cannot be dragged out of bounds", () => {
    render(<Overlay />);
    drag({ x: 900, y: 550 }, { x: -5_000, y: -5_000 });
    expect(Number.parseFloat(surface().style.left)).toBeGreaterThanOrEqual(0);
    expect(Number.parseFloat(surface().style.top)).toBeGreaterThanOrEqual(0);
  });

  it("treats a press that never moved as a press, not a placement", () => {
    render(<Overlay storageKey={STORAGE_KEY} />);
    drag({ x: 900, y: 550 }, { x: 901, y: 551 });
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });

  it("moves by keyboard, so placement is never pointer-only", () => {
    render(<Overlay />);
    const before = Number.parseFloat(surface().style.left);
    fireEvent.keyDown(screen.getByTestId("handle"), { key: "ArrowLeft" });
    expect(Number.parseFloat(surface().style.left)).toBeCloseTo(before - 8, 0);

    fireEvent.keyDown(screen.getByTestId("handle"), { key: "ArrowLeft", shiftKey: true });
    expect(Number.parseFloat(surface().style.left)).toBeCloseTo(before - 40, 0);
  });

  it("moves by preset control", () => {
    render(<Overlay />);
    fireEvent.click(screen.getByRole("button", { name: "Top left" }));
    expect(surface().style.left).toBe(`${OVERLAY_EDGE_GAP}px`);
    expect(surface().style.top).toBe(`${OVERLAY_EDGE_GAP}px`);
  });

  it("persists placement normalized, not in pixels", () => {
    render(<Overlay storageKey={STORAGE_KEY} />);
    fireEvent.click(screen.getByRole("button", { name: "Top left" }));
    expect(JSON.parse(window.localStorage.getItem(STORAGE_KEY)!)).toEqual({ x: 0, y: 0 });
  });

  it("restores a saved placement on the next mount", () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ x: 0, y: 0 }));
    render(<Overlay storageKey={STORAGE_KEY} />);
    expect(surface().style.left).toBe(`${OVERLAY_EDGE_GAP}px`);
  });

  it("never restores off-screen after the viewport shrinks", () => {
    // A saved pixel offset from a large window would land outside a small one.
    // A normalized placement cannot.
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ x: 1, y: 1 }));
    render(<Overlay storageKey={STORAGE_KEY} />);

    act(() => {
      Object.defineProperty(window, "innerWidth", { configurable: true, value: 320 });
      Object.defineProperty(window, "innerHeight", { configurable: true, value: 480 });
      window.dispatchEvent(new Event("resize"));
    });

    expect(Number.parseFloat(surface().style.left) + SURFACE.width).toBeLessThanOrEqual(320);
    expect(Number.parseFloat(surface().style.top) + SURFACE.height).toBeLessThanOrEqual(480);
  });

  it("ignores a corrupt stored placement rather than rendering at NaN", () => {
    window.localStorage.setItem(STORAGE_KEY, "{ not json");
    render(<Overlay storageKey={STORAGE_KEY} />);
    expect(surface().style.left).toBe(`${1000 - SURFACE.width - OVERLAY_EDGE_GAP}px`);
  });

  it("reports dragging state for keep-visible conditions", () => {
    render(<Overlay />);
    const handle = screen.getByTestId("handle");
    handle.setPointerCapture = vi.fn();
    handle.hasPointerCapture = vi.fn(() => true);
    handle.releasePointerCapture = vi.fn();

    fireEvent.pointerDown(handle, { button: 0, pointerId: 1, clientX: 900, clientY: 550 });
    expect(surface().dataset.dragging).toBe("true");
    fireEvent.pointerUp(handle, { pointerId: 1, clientX: 900, clientY: 550 });
    expect(surface().dataset.dragging).toBe("false");
  });
});
