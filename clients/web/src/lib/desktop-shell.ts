import type { DesktopBridge } from "../desktop/session";

export type NativeShellMenu = "file" | "edit" | "view" | "help";
export type NativeShellAction = "new-instant-room" | "open-workspace" | "open-search" | "toggle-sidebar" | "open-help";
export type DesktopShellTheme = "light" | "dark" | "system";

export interface NativeDesktopShellState {
  version: 1;
  platform: "win32" | "darwin" | "linux";
  nativeControls: true;
  nativeMenu: true;
}

export interface NativeDesktopShellBridge {
  getState: () => Promise<NativeDesktopShellState>;
  showMenu: (menu: NativeShellMenu) => Promise<void>;
  subscribe: (listener: (action: NativeShellAction) => void) => () => void;
  setTheme: (theme: DesktopShellTheme) => Promise<void>;
}

declare module "../desktop/session" {
  interface DesktopBridge {
    readonly shell?: NativeDesktopShellBridge;
  }
}

/** A fixed menu boundary; no native window, clipboard, path or URL commands. */
export function getDesktopShellBridge(): NativeDesktopShellBridge | null {
  if (typeof window === "undefined") return null;
  const desktop: DesktopBridge | undefined = window.kCommsDesktop;
  const shell = desktop?.shell;
  return desktop?.version === 1 && shell && typeof shell.getState === "function" &&
    typeof shell.showMenu === "function" && typeof shell.subscribe === "function" ? shell : null;
}

export function validateDesktopShellState(value: unknown): NativeDesktopShellState {
  if (!value || typeof value !== "object") throw new Error("Desktop menu state is unavailable");
  const state = value as Partial<NativeDesktopShellState>;
  if (state.version !== 1 || !["win32", "darwin", "linux"].includes(state.platform ?? "") ||
    state.nativeControls !== true || state.nativeMenu !== true) {
    throw new Error("Desktop menu state is unavailable");
  }
  return { version: 1, platform: state.platform!, nativeControls: true, nativeMenu: true };
}

export function isNativeShellAction(value: unknown): value is NativeShellAction {
  return typeof value === "string" && ["new-instant-room", "open-workspace", "open-search", "toggle-sidebar", "open-help"].includes(value);
}

/** The native host chooses its own fixed palette for the requested app theme. */
export async function syncDesktopShellTheme(theme: DesktopShellTheme): Promise<void> {
  if (!["light", "dark", "system"].includes(theme)) throw new Error("Unsupported desktop theme");
  const bridge = getDesktopShellBridge();
  if (bridge && typeof bridge.setTheme === "function") await bridge.setTheme(theme);
}
