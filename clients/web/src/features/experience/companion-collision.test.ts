import { afterEach, describe, expect, it } from "vitest";
import {
  companionDisposition,
  getProtectedSurfaces,
  NO_PROTECTED_SURFACES,
  resetProtectedSurfacesForTest,
  setProtectedSurface
} from "./companion-collision";

afterEach(() => {
  resetProtectedSurfacesForTest();
});

describe("companionDisposition", () => {
  it("leaves the companion where the user put it when nothing is protected", () => {
    expect(companionDisposition(NO_PROTECTED_SURFACES)).toEqual({
      placement: "free",
      collapsed: false,
      reason: "none"
    });
  });

  it("moves off the canvas but keeps its controls when a canvas is merely visible", () => {
    // The contract asks the companion to prefer existing non-canvas chrome.
    // Nothing is being drawn, so there is no reason to take the controls away
    // as well.
    expect(companionDisposition({ ...NO_PROTECTED_SURFACES, canvasVisible: true })).toEqual({
      placement: "top",
      collapsed: false,
      reason: "canvas-visible"
    });
  });

  it("collapses to the capsule while the canvas is being drawn on", () => {
    // "Must not float over the drawable plane while pen/stylus input or an
    // Excalidraw text editor is active."
    expect(
      companionDisposition({ ...NO_PROTECTED_SURFACES, canvasVisible: true, canvasEditing: true })
    ).toEqual({ placement: "top", collapsed: true, reason: "canvas-editing" });
  });

  it("yields to the virtual keyboard", () => {
    expect(companionDisposition({ ...NO_PROTECTED_SURFACES, keyboardOpen: true })).toEqual({
      placement: "top",
      collapsed: true,
      reason: "keyboard-open"
    });
  });

  it("ranks editing above the keyboard", () => {
    // A stylus stroke lands on the canvas immediately; a keyboard has already
    // taken its space and will not take more. The reported reason is the one
    // that would actually be violated first.
    expect(
      companionDisposition({ canvasVisible: true, canvasEditing: true, keyboardOpen: true }).reason
    ).toBe("canvas-editing");
  });

  it("yields to editing even where no canvas was reported visible", () => {
    // Defensive: a surface that reports editing without visibility is
    // inconsistent, and the safe reading of an inconsistent pair is to yield.
    expect(
      companionDisposition({ ...NO_PROTECTED_SURFACES, canvasEditing: true }).placement
    ).toBe("top");
  });

  it("never leaves the companion floating while anything is protected", () => {
    for (const key of ["canvasVisible", "canvasEditing", "keyboardOpen"] as const) {
      const disposition = companionDisposition({ ...NO_PROTECTED_SURFACES, [key]: true });
      expect(disposition.placement, `${key} should move the companion`).toBe("top");
    }
  });
});

describe("the protected surface store", () => {
  it("starts with nothing protected", () => {
    expect(getProtectedSurfaces()).toEqual(NO_PROTECTED_SURFACES);
  });

  it("records each signal independently", () => {
    setProtectedSurface("canvasVisible", true);
    expect(getProtectedSurfaces()).toEqual({
      canvasVisible: true,
      canvasEditing: false,
      keyboardOpen: false
    });

    setProtectedSurface("keyboardOpen", true);
    expect(getProtectedSurfaces().canvasVisible).toBe(true);
    expect(getProtectedSurfaces().keyboardOpen).toBe(true);
  });

  it("keeps the same snapshot when nothing changed", () => {
    // useSyncExternalStore compares by identity; a new object per write would
    // re-render every consumer on every publish.
    setProtectedSurface("canvasVisible", true);
    const snapshot = getProtectedSurfaces();
    setProtectedSurface("canvasVisible", true);
    expect(getProtectedSurfaces()).toBe(snapshot);
  });

  it("clears every signal on reset, so one test cannot leak into the next", () => {
    setProtectedSurface("canvasVisible", true);
    setProtectedSurface("canvasEditing", true);
    setProtectedSurface("keyboardOpen", true);
    resetProtectedSurfacesForTest();
    expect(getProtectedSurfaces()).toEqual(NO_PROTECTED_SURFACES);
  });
});
