import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOverlayVisibility } from "./useOverlayVisibility";
import {
  CALL_CONTROL_PREFERENCE_KEYS,
  resetCallControlPreferencesForTest
} from "./call-control-preferences";
import { OVERLAY_IDLE_MS, type KeepVisibleConditions } from "./overlay-visibility";

function Surface({
  enabled = true,
  conditions
}: {
  enabled?: boolean;
  conditions?: Partial<KeepVisibleConditions>;
}) {
  const { visible, surfaceProps, keepVisibleReasons, pinned, setPinned, alwaysShow, toggleAlwaysShow } =
    useOverlayVisibility({ enabled, conditions });
  return (
    <div data-testid="surface" data-visible={visible} data-reasons={keepVisibleReasons.join(",")} {...surfaceProps}>
      {/* Critical state is rendered outside whatever collapses. */}
      <span data-testid="critical">Microphone on</span>
      {visible && <button data-testid="routine" type="button">Mute</button>}
      <button data-testid="pin" type="button" onClick={() => setPinned(!pinned)}>Pin</button>
      <button data-testid="always" type="button" onClick={toggleAlwaysShow}>{String(alwaysShow)}</button>
    </div>
  );
}

const surface = () => screen.getByTestId("surface");
const isVisible = () => surface().dataset.visible === "true";

function idleOut(by = OVERLAY_IDLE_MS) {
  act(() => {
    vi.advanceTimersByTime(by);
  });
}

describe("useOverlayVisibility", () => {
  beforeEach(() => {
    window.localStorage.clear();
    // The preference snapshot is memoized for identity stability, so a test
    // seeding storage directly has to drop it first.
    resetCallControlPreferencesForTest();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("collapses routine controls after the idle window", () => {
    render(<Surface />);
    expect(isVisible()).toBe(true);
    idleOut();
    expect(isVisible()).toBe(false);
    expect(screen.queryByTestId("routine")).toBeNull();
  });

  it("keeps critical state perceivable while routine controls collapse", () => {
    // The contract's line in the sand: a call may tidy its controls away, but
    // never what the microphone is doing.
    render(<Surface />);
    idleOut();
    expect(isVisible()).toBe(false);
    expect(screen.getByTestId("critical")).toBeVisible();
  });

  it("reveals in the same task as the input, not a frame later", () => {
    render(<Surface />);
    idleOut();
    expect(isVisible()).toBe(false);

    // No timer advance between the event and the assertion: the 100ms budget
    // is met by not deferring at all.
    fireEvent.pointerMove(surface(), { clientX: 400, clientY: 400 });
    expect(isVisible()).toBe(true);
  });

  it("reveals on tap, key and focus as well as pointer movement", () => {
    for (const fire of [
      () => fireEvent.pointerDown(surface()),
      () => fireEvent.keyDown(surface(), { key: "m" }),
      () => fireEvent.focus(surface())
    ]) {
      const view = render(<Surface />);
      idleOut();
      expect(isVisible()).toBe(false);
      fire();
      expect(isVisible()).toBe(true);
      view.unmount();
    }
  });

  it("does not reset the countdown for pointer jitter", () => {
    render(<Surface />);
    fireEvent.pointerMove(surface(), { clientX: 500, clientY: 500 });

    // Two seconds of a resting hand: sub-threshold movement the whole time.
    for (let tick = 0; tick < 20; tick += 1) {
      act(() => {
        vi.advanceTimersByTime(100);
      });
      fireEvent.pointerMove(surface(), { clientX: 501, clientY: 500 });
    }
    // Without a jitter floor this would still be visible, forever.
    idleOut(1_000);
    expect(isVisible()).toBe(false);
  });

  it("stays visible while hovered, and collapses once the pointer leaves", () => {
    render(<Surface />);
    fireEvent.pointerEnter(surface());
    idleOut(OVERLAY_IDLE_MS * 3);
    expect(isVisible()).toBe(true);
    expect(surface().dataset.reasons).toContain("hovering");

    fireEvent.pointerLeave(surface());
    idleOut();
    expect(isVisible()).toBe(false);
  });

  it("stays visible while focus is inside the control system", () => {
    // Hiding controls out from under a keyboard user loses their place;
    // there is no equivalent of moving the mouse to bring them back.
    render(<Surface />);
    fireEvent.focus(surface());
    idleOut(OVERLAY_IDLE_MS * 3);
    expect(isVisible()).toBe(true);
    expect(surface().dataset.reasons).toContain("focusWithin");
  });

  it("keeps focus held while it moves between descendants", () => {
    render(<Surface />);
    fireEvent.focus(surface());
    fireEvent.blur(surface(), { relatedTarget: screen.getByTestId("pin") });
    idleOut(OVERLAY_IDLE_MS * 2);
    expect(isVisible()).toBe(true);
  });

  it("releases when focus leaves the control system entirely", () => {
    render(<Surface />);
    fireEvent.focus(surface());
    fireEvent.blur(surface(), { relatedTarget: document.body });
    idleOut();
    expect(isVisible()).toBe(false);
  });

  it.each([
    ["dragging", { dragging: true }],
    ["menuOpen", { menuOpen: true }],
    ["pendingAction", { pendingAction: true }],
    ["blockingAlert", { blockingAlert: true }]
  ] as const)("stays visible while %s", (reason, conditions) => {
    render(<Surface conditions={conditions} />);
    idleOut(OVERLAY_IDLE_MS * 3);
    expect(isVisible()).toBe(true);
    expect(surface().dataset.reasons).toContain(reason);
  });

  it("cancels a countdown already in flight when a condition appears", () => {
    // Opening a menu two seconds in must not let the controls vanish a
    // second later.
    const view = render(<Surface />);
    idleOut(2_000);
    expect(isVisible()).toBe(true);

    view.rerender(<Surface conditions={{ menuOpen: true }} />);
    idleOut(OVERLAY_IDLE_MS * 2);
    expect(isVisible()).toBe(true);
  });

  it("starts a fresh countdown when the last condition clears", () => {
    const view = render(<Surface conditions={{ menuOpen: true }} />);
    idleOut(OVERLAY_IDLE_MS * 2);
    expect(isVisible()).toBe(true);

    view.rerender(<Surface conditions={{ menuOpen: false }} />);
    idleOut();
    expect(isVisible()).toBe(false);
  });

  it("never collapses while pinned", () => {
    render(<Surface />);
    fireEvent.click(screen.getByTestId("pin"));
    idleOut(OVERLAY_IDLE_MS * 5);
    expect(isVisible()).toBe(true);
    expect(surface().dataset.reasons).toContain("pinned");
  });

  it("never collapses when Always show controls is on", () => {
    window.localStorage.setItem(CALL_CONTROL_PREFERENCE_KEYS.alwaysShow, "true");
    render(<Surface />);
    idleOut(OVERLAY_IDLE_MS * 5);
    expect(isVisible()).toBe(true);
    expect(surface().dataset.reasons).toContain("alwaysShow");
  });

  it("persists the Always show controls preference", () => {
    render(<Surface />);
    fireEvent.click(screen.getByTestId("always"));
    expect(window.localStorage.getItem(CALL_CONTROL_PREFERENCE_KEYS.alwaysShow)).toBe("true");
    idleOut(OVERLAY_IDLE_MS * 3);
    expect(isVisible()).toBe(true);
  });

  it("never collapses where auto-hide does not apply", () => {
    // The minimized companion is already the compact critical form; there is
    // nothing there worth tidying away.
    render(<Surface enabled={false} />);
    idleOut(OVERLAY_IDLE_MS * 5);
    expect(isVisible()).toBe(true);
  });
});
