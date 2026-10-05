import { afterEach, expect, it, vi } from "vitest";
import { getDesktopShellBridge, isNativeShellAction, syncDesktopShellTheme, validateDesktopShellState } from "./desktop-shell";
import type { DesktopShellTheme } from "./desktop-shell";

afterEach(() => { Reflect.deleteProperty(window, "kCommsDesktop"); });

it("keeps the native adapter unavailable to ordinary browsers and incomplete bridges", () => {
  expect(getDesktopShellBridge()).toBeNull();
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1, shell: { showMenu() {} } } });
  expect(getDesktopShellBridge()).toBeNull();
});

it("accepts only versioned OS-owned menu state", () => {
  expect(validateDesktopShellState({ version: 1, platform: "darwin", nativeControls: true, nativeMenu: true })).toEqual({ version: 1, platform: "darwin", nativeControls: true, nativeMenu: true });
  for (const value of [null, { version: 2 }, { version: 1, platform: "browser", nativeControls: true, nativeMenu: true }, { version: 1, platform: "win32", nativeControls: false, nativeMenu: true }]) {
    expect(() => validateDesktopShellState(value)).toThrow("Desktop menu state is unavailable");
  }
  expect(isNativeShellAction("toggle-sidebar")).toBe(true);
  expect(isNativeShellAction("close-window")).toBe(false);
  expect(isNativeShellAction({ action: "toggle-sidebar" })).toBe(false);
});

it("sends only a finite theme selection and propagates native rejection", async () => {
  await expect(syncDesktopShellTheme("system")).resolves.toBeUndefined();
  const setTheme = vi.fn().mockResolvedValue(undefined);
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1, shell: {
    getState: vi.fn(), showMenu: vi.fn(), subscribe: vi.fn(), setTheme
  } } });
  await syncDesktopShellTheme("dark");
  expect(setTheme).toHaveBeenCalledWith("dark");
  await expect(syncDesktopShellTheme("arbitrary-css" as DesktopShellTheme)).rejects.toThrow("Unsupported desktop theme");
  expect(setTheme).toHaveBeenCalledOnce();
  setTheme.mockRejectedValueOnce(new Error("Native frame rejected"));
  await expect(syncDesktopShellTheme("light")).rejects.toThrow("Native frame rejected");
});
