import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useWindowControlsOverlay } from "./useWindowControlsOverlay";

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
afterEach(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});

function displayMode(initial: boolean) {
  let matches = initial;
  const listeners = new Set<() => void>();
  const media = {
    get matches() { return matches; },
    addEventListener: vi.fn((_event: string, listener: () => void) => listeners.add(listener)),
    removeEventListener: vi.fn((_event: string, listener: () => void) => listeners.delete(listener))
  };
  const matchMedia = vi.fn(() => media);
  Object.defineProperty(window, "matchMedia", { configurable: true, value: matchMedia });
  return { media, matchMedia, listeners, change: (next: boolean) => {
    matches = next;
    act(() => listeners.forEach((listener) => listener()));
  } };
}

describe("installed window-controls overlay", () => {
  it("reads the genuine display-mode match and follows activation/deactivation", () => {
    const mode = displayMode(false);
    const { result, unmount } = renderHook(useWindowControlsOverlay);
    expect(mode.matchMedia).toHaveBeenCalledWith("(display-mode: window-controls-overlay)");
    expect(result.current).toBe(false);
    mode.change(true); expect(result.current).toBe(true);
    mode.change(false); expect(result.current).toBe(false);
    unmount();
    expect(mode.listeners.size).toBe(0);
    expect(mode.media.removeEventListener).toHaveBeenCalledWith("change", expect.any(Function));
  });

  it("recognizes an already installed overlay without a desktop viewport condition", () => {
    const mode = displayMode(true);
    const { result } = renderHook(useWindowControlsOverlay);
    expect(result.current).toBe(true);
    expect(mode.matchMedia).toHaveBeenCalledTimes(1);
  });

  it("stays off when the platform does not provide display-mode queries", () => {
    Reflect.deleteProperty(window, "matchMedia");
    const { result } = renderHook(useWindowControlsOverlay);
    expect(result.current).toBe(false);
  });
});
