import { render, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DesktopThemeSync } from "./DesktopThemeSync";
import type { NativeDesktopShellBridge } from "../lib/desktop-shell";

function bridge() {
  const shell: NativeDesktopShellBridge = {
    getState: vi.fn().mockResolvedValue({ version: 1, platform: "win32", nativeControls: true, nativeMenu: true }),
    showMenu: vi.fn().mockResolvedValue(undefined),
    subscribe: vi.fn(() => () => undefined),
    setTheme: vi.fn().mockResolvedValue(undefined)
  };
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1, shell } });
  return shell;
}

afterEach(() => {
  Reflect.deleteProperty(window, "kCommsDesktop");
  document.documentElement.removeAttribute("data-theme");
  document.documentElement.removeAttribute("data-native-desktop");
});

describe("native theme synchronization", () => {
  it("mirrors the existing CSS theme choice and returns to system when it is removed", async () => {
    const shell = bridge();
    document.documentElement.setAttribute("data-theme", "dark");
    const view = render(<DesktopThemeSync />);
    await waitFor(() => expect(shell.setTheme).toHaveBeenLastCalledWith("dark"));
    document.documentElement.setAttribute("data-theme", "light");
    await waitFor(() => expect(shell.setTheme).toHaveBeenLastCalledWith("light"));
    document.documentElement.removeAttribute("data-theme");
    await waitFor(() => expect(shell.setTheme).toHaveBeenLastCalledWith("system"));
    expect(shell.setTheme).toHaveBeenCalledTimes(3);
    view.unmount();
    document.documentElement.setAttribute("data-theme", "dark");
    await Promise.resolve();
    expect(shell.setTheme).toHaveBeenCalledTimes(3);
  });

  it("does not alter the app theme or crash when the cosmetic native bridge fails", async () => {
    const shell = bridge();
    vi.mocked(shell.setTheme).mockRejectedValue(new Error("Host theme unavailable"));
    document.documentElement.setAttribute("data-theme", "light");
    render(<DesktopThemeSync />);
    await waitFor(() => expect(shell.setTheme).toHaveBeenCalledWith("light"));
    await Promise.resolve();
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
  });

  it("has no browser-side theme preference or native fallback", () => {
    Reflect.deleteProperty(window, "kCommsDesktop");
    document.documentElement.setAttribute("data-theme", "dark");
    render(<DesktopThemeSync />);
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(document.documentElement.hasAttribute("data-native-desktop")).toBe(false);
  });

  it.each([null, "previous-owner"])("owns the native marker during its lifecycle and restores %s", (previous) => {
    bridge();
    if (previous !== null) document.documentElement.setAttribute("data-native-desktop", previous);
    const view = render(<DesktopThemeSync />);
    expect(document.documentElement.getAttribute("data-native-desktop")).toBe("true");
    view.unmount();
    expect(document.documentElement.getAttribute("data-native-desktop")).toBe(previous);
  });

  it("does not overwrite a marker changed by another owner during cleanup", () => {
    bridge();
    const view = render(<DesktopThemeSync />);
    document.documentElement.setAttribute("data-native-desktop", "next-owner");
    view.unmount();
    expect(document.documentElement.getAttribute("data-native-desktop")).toBe("next-owner");
  });
});
