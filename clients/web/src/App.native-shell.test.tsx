import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";
import { instantRoomIdempotencyKey } from "./features/instant-room/idempotency";
import type { NativeDesktopShellBridge, NativeShellAction } from "./lib/desktop-shell";

const appHarness = vi.hoisted(() => ({
  session: null as object | null,
  transportPolicyReady: true,
  workspaceLoads: vi.fn()
}));

vi.mock("./app/session", () => ({
  SessionProvider: ({ children }: { children: React.ReactNode }) => children,
  useSession: () => ({ session: appHarness.session, transportPolicyReady: appHarness.transportPolicyReady })
}));
vi.mock("./app/workspace-data", () => ({ WorkspaceDataProvider: ({ children }: { children: React.ReactNode }) => {
  appHarness.workspaceLoads(); return children;
} }));
vi.mock("./app/step-up", () => ({ StepUpProvider: ({ children }: { children: React.ReactNode }) => children }));
vi.mock("./app/ProductShell", async () => {
  const { Outlet } = await import("react-router");
  const { useRouterHistory } = await import("./app/router-history");
  return { ProductShell: () => {
    const history = useRouterHistory();
    return <><header aria-label="Member shell"><button disabled={!history.canGoBack} onClick={history.onBack}>Member back</button></header><Outlet /></>;
  } };
});
vi.mock("./features/chat/ChatPage", () => ({ ChatPage: () => <h1>Member inbox</h1> }));
vi.mock("./features/auth/AuthScreen", () => ({ AuthScreen: () => <h1>Authentication gateway</h1> }));
vi.mock("./features/guest/GuestAccessPage", () => ({ GuestAccessPage: () => <h1>Guest join</h1> }));
vi.mock("./features/instant-room/InstantRoomPage", () => ({ InstantRoomPage: ({ authenticationGateway }: { authenticationGateway?: React.ReactNode }) =>
  <main><h1>Instant front door</h1>{authenticationGateway}</main>
}));

const member = { user: { id: "synthetic-member", display_name: "Private member name" }, tenant: { id: "synthetic-tenant", name: "Private workspace name" } };
let nativeIntent: ((action: NativeShellAction) => void) | undefined;
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
const originalWidth = Object.getOwnPropertyDescriptor(window, "innerWidth");
const originalHeight = Object.getOwnPropertyDescriptor(window, "innerHeight");

function windowControlsOverlay(initial: boolean) {
  let matches = initial;
  const listeners = new Set<() => void>();
  const media = { get matches() { return matches; },
    addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener)
  };
  const otherMedia = { matches: false, addEventListener: () => undefined, removeEventListener: () => undefined };
  Object.defineProperty(window, "matchMedia", { configurable: true, value: (query: string) =>
    query === "(display-mode: window-controls-overlay)" ? media : otherMedia
  });
  return (next: boolean) => { matches = next; act(() => listeners.forEach((listener) => listener())); };
}

function nativeBridge() {
  const shell: NativeDesktopShellBridge = {
    getState: vi.fn().mockResolvedValue({ version: 1, platform: "win32", nativeControls: true, nativeMenu: true }),
    showMenu: vi.fn().mockResolvedValue(undefined),
    subscribe: vi.fn((listener) => { nativeIntent = listener; return () => { nativeIntent = undefined; }; }),
    setTheme: vi.fn().mockResolvedValue(undefined)
  };
  const desktop = { version: 1, shell, getState: vi.fn(), credentials: { load: vi.fn(), replace: vi.fn() } };
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: desktop });
  return desktop;
}

async function intent(action: NativeShellAction) {
  await waitFor(() => expect(nativeIntent).toBeDefined());
  act(() => nativeIntent?.(action));
}

beforeEach(() => {
  appHarness.session = null;
  appHarness.transportPolicyReady = true;
  appHarness.workspaceLoads.mockClear();
  nativeIntent = undefined;
  Reflect.deleteProperty(window, "kCommsDesktop");
  window.history.replaceState({ idx: 0, key: "native-public-start" }, "", "/");
});
afterEach(() => {
  Reflect.deleteProperty(window, "kCommsDesktop"); nativeIntent = undefined;
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
  if (originalWidth) Object.defineProperty(window, "innerWidth", originalWidth);
  if (originalHeight) Object.defineProperty(window, "innerHeight", originalHeight);
});

describe("installed-client public shell", () => {
  it("does not add native public controls to the browser front door", () => {
    render(<App />);
    expect(screen.getByRole("heading", { name: "Instant front door" })).toBeVisible();
    expect(screen.queryByRole("menubar", { name: "Application menu" })).not.toBeInTheDocument();
    expect(document.querySelector(".native-public-shell")).toBeNull();
  });

  it("adds public titlebar actions only while the installed overlay is active", () => {
    const overlay = windowControlsOverlay(false);
    render(<App />);
    expect(screen.queryByRole("menubar", { name: "Application menu" })).not.toBeInTheDocument();
    overlay(true);
    expect(screen.getByRole("menubar", { name: "Application menu" })).toBeVisible();
    expect(document.querySelector(".native-public-shell")).not.toBeNull();
    expect(screen.queryByRole("menuitem", { name: "Edit" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Toggle workspace navigation" })).not.toBeInTheDocument();
    overlay(false);
    expect(screen.queryByRole("menubar", { name: "Application menu" })).not.toBeInTheDocument();
    expect(document.querySelector(".native-public-shell")).toBeNull();
    expect(window.location.pathname).toBe("/");
  });

  it("keeps narrow and short installed guest titlebars identity-free with real app Help", () => {
    windowControlsOverlay(true);
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 360 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 480 });
    appHarness.session = member;
    window.history.replaceState({ idx: 0, key: "overlay-guest" }, "", "/join#guest=synthetic-bearer");
    render(<App />);
    expect(screen.getByRole("heading", { name: "Guest join" })).toBeVisible();
    expect(screen.getAllByRole("menubar", { name: "Application menu" })).toHaveLength(1);
    for (const privateValue of ["synthetic-bearer", "Private member name", "Private workspace name"]) {
      expect(document.body).not.toHaveTextContent(privateValue);
    }
    expect(appHarness.workspaceLoads).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("menuitem", { name: "Help" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "About K-Comms" }));
    expect(screen.getByRole("dialog", { name: "K-Comms" })).toBeVisible();
    expect(screen.queryByText("Unsigned desktop evaluation. Automatic updates are off.")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Close window" })).not.toBeInTheDocument();
  });

  it("routes installed File actions through sign-in and yields to the member shell", async () => {
    windowControlsOverlay(true);
    const view = render(<App />);
    fireEvent.click(screen.getByRole("menuitem", { name: "File" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Open workspace" }));
    expect(await screen.findByRole("heading", { name: "Authentication gateway" })).toBeVisible();
    expect(window.location.pathname).toBe("/sign-in");
    expect(appHarness.workspaceLoads).not.toHaveBeenCalled();
    appHarness.session = member;
    view.rerender(<App />);
    expect(await screen.findByRole("heading", { name: "Member inbox" })).toBeVisible();
    expect(document.querySelector(".native-public-shell")).toBeNull();
    expect(screen.getByRole("button", { name: "Member back" })).toBeEnabled();
  });

  it("keeps identity-free native menus available during transport-policy loading", async () => {
    const desktop = nativeBridge();
    appHarness.session = member;
    appHarness.transportPolicyReady = false;
    window.history.replaceState({ idx: 0, key: "loading" }, "", "/app/");
    render(<App />);
    expect(screen.getByRole("heading", { name: "Loading K-Comms…" })).toBeVisible();
    await screen.findByRole("menuitem", { name: "Edit" });
    expect(screen.getAllByRole("menubar", { name: "Application menu" })).toHaveLength(1);
    expect(screen.queryByRole("button", { name: "Toggle workspace navigation" })).not.toBeInTheDocument();
    expect(document.body).not.toHaveTextContent("Private member name");
    expect(document.body).not.toHaveTextContent("Private workspace name");
    expect(appHarness.workspaceLoads).not.toHaveBeenCalled();
    expect(desktop.getState).not.toHaveBeenCalled();
    expect(desktop.credentials.load).not.toHaveBeenCalled();
  });

  it("keeps guest entry public and opens the real About dialog", async () => {
    nativeBridge();
    appHarness.session = member;
    window.history.replaceState({ idx: 0, key: "guest" }, "", "/join#guest=synthetic-bearer");
    render(<App />);
    expect(screen.getByRole("heading", { name: "Guest join" })).toBeVisible();
    await intent("open-help");
    expect(screen.getByRole("dialog", { name: "K-Comms" })).toBeVisible();
    expect(screen.getByText("Unsigned desktop evaluation. Automatic updates are off.")).toBeVisible();
    for (const privateValue of ["synthetic-bearer", "Private member name", "Private workspace name"]) {
      expect(document.body).not.toHaveTextContent(privateValue);
    }
    fireEvent.click(screen.getByRole("button", { name: "Close About K-Comms" }));
    expect(screen.queryByRole("dialog", { name: "K-Comms" })).not.toBeInTheDocument();
  });

  it("starts a new room visit and returns to the front door from authentication", async () => {
    nativeBridge();
    window.history.replaceState({ idx: 0, key: "signin" }, "", "/sign-in");
    const previousVisit = instantRoomIdempotencyKey();
    render(<App />);
    expect(screen.getByRole("heading", { name: "Authentication gateway" })).toBeVisible();
    await intent("new-instant-room");
    await waitFor(() => expect(window.location.pathname).toBe("/"));
    expect(instantRoomIdempotencyKey()).not.toBe(previousVisit);
    expect(screen.queryByRole("heading", { name: "Authentication gateway" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Go back" })).toBeEnabled();
  });

  it.each(["open-workspace", "open-search"] as const)("routes native %s through the authentication boundary", async (action) => {
    nativeBridge();
    render(<App />);
    await intent(action);
    expect(await screen.findByRole("heading", { name: "Authentication gateway" })).toBeVisible();
    expect(window.location.pathname).toBe("/sign-in");
    expect(appHarness.workspaceLoads).not.toHaveBeenCalled();
  });

  it("preserves known history when the public shell becomes the member shell", async () => {
    nativeBridge();
    const view = render(<App />);
    await intent("open-workspace");
    await screen.findByRole("heading", { name: "Authentication gateway" });
    appHarness.session = member;
    view.rerender(<App />);
    expect(await screen.findByRole("heading", { name: "Member inbox" })).toBeVisible();
    expect(window.location.pathname).toBe("/app/");
    expect(document.querySelector(".native-public-shell")).toBeNull();
    expect(screen.queryByRole("menubar", { name: "Application menu" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Member back" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Member back" }));
    expect(await screen.findByRole("heading", { name: "Instant front door" })).toBeVisible();
    expect(window.location.pathname).toBe("/");
    expect(screen.getAllByRole("menubar", { name: "Application menu" })).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Go forward" })).toBeEnabled();
    expect(document.body).not.toHaveTextContent("Private workspace name");
    fireEvent.click(screen.getByRole("button", { name: "Go forward" }));
    expect(await screen.findByRole("heading", { name: "Member inbox" })).toBeVisible();
    expect(document.querySelector(".native-public-shell")).toBeNull();
  });
});
