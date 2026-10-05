import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { InstantWorkspaceDraft } from "../features/instant-room/InstantWorkspaceDraft";
import { PublicDesktopShell } from "./PublicDesktopShell";
import { RouterHistoryProvider } from "./router-history";

const canvasLifecycle = vi.hoisted(() => ({ mount: vi.fn(), unmount: vi.fn() }));
vi.mock("./session", () => ({ useSession: () => ({ session: null, transportPolicyReady: true }) }));
vi.mock("../features/whiteboard/KCommsDrawingCanvas", async () => {
  const { useEffect } = await import("react");
  return { KCommsDrawingCanvas: () => {
    useEffect(() => { canvasLifecycle.mount(); return () => { canvasLifecycle.unmount(); }; }, []);
    return <div data-testid="local-canvas">Local canvas</div>;
  } };
});

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeEach(() => {
  window.localStorage.clear();
  canvasLifecycle.mount.mockClear(); canvasLifecycle.unmount.mockClear();
  Reflect.deleteProperty(window, "kCommsDesktop");
});
afterEach(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});

describe("public display-mode continuity", () => {
  it("retains the actual draft, focused input, and canvas mount when WCO activates and deactivates", async () => {
    let overlay = false;
    const listeners = new Set<() => void>();
    const query = { get matches() { return overlay; },
      addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener)
    };
    Object.defineProperty(window, "matchMedia", { configurable: true, value: () => query });
    const onActivate = vi.fn().mockResolvedValue(true);
    const user = userEvent.setup();
    const view = render(<MemoryRouter><RouterHistoryProvider><PublicDesktopShell>
      <InstantWorkspaceDraft activating={false} error="" identityManaged={false} retrySeconds={0} onActivate={onActivate} />
    </PublicDesktopShell></RouterHistoryProvider></MemoryRouter>);
    await user.click(screen.getByText("Add a first message"));
    const message = screen.getByRole("textbox", { name: "Optional first message" });
    const canvas = screen.getByTestId("local-canvas");
    await user.type(message, "Keep this unsent public draft");
    expect(message).toHaveFocus();
    expect(canvasLifecycle.mount).toHaveBeenCalledTimes(1);

    for (const nextMode of [true, false]) {
      overlay = nextMode;
      act(() => listeners.forEach((listener) => listener()));
      expect(Boolean(document.querySelector(".native-public-shell"))).toBe(nextMode);
      expect(screen.getByRole("textbox", { name: "Optional first message" })).toBe(message);
      expect(message).toHaveValue("Keep this unsent public draft");
      expect(message).toHaveFocus();
      expect(screen.getByTestId("local-canvas")).toBe(canvas);
      expect(canvasLifecycle.mount).toHaveBeenCalledTimes(1);
      expect(canvasLifecycle.unmount).not.toHaveBeenCalled();
      expect(onActivate).not.toHaveBeenCalled();
    }
    view.unmount();
    expect(canvasLifecycle.unmount).toHaveBeenCalledTimes(1);
  });
});
