import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "../types";
import { ProductShell } from "./ProductShell";
import { RouterHistoryProvider } from "./router-history";
import { ContextualNavigation, useContextualNavigation } from "./ContextualNavigation";

const harness = vi.hoisted(() => {
  const session: Session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 900,
    tenant: { id: "tenant-1", name: "Example workspace", slug: "example", status: "active" },
    user: {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Taylor Example",
      email: "taylor@example.test",
      role: "member",
      status: "active"
    },
    device: {
      id: "device-1",
      user_id: "user-1",
      name: "Browser",
      platform: "web"
    }
  };

  return {
    session,
    availabilityApi: undefined as undefined | { availability: ReturnType<typeof vi.fn>; updateAvailability: ReturnType<typeof vi.fn> },
    logout: vi.fn(),
    teardownCall: vi.fn(),
    refreshAll: vi.fn(),
    setError: vi.fn(),
    pageMount: vi.fn(),
    pageUnmount: vi.fn(),
    callProviderMount: vi.fn(),
    callProviderUnmount: vi.fn(),
    pwa: {
      installMode: "unavailable" as
        | "native-prompt"
        | "manual-ios"
        | "manual-browser"
        | "installed"
        | "unavailable",
      updateAvailable: false,
      requestInstall: vi.fn(),
      applyUpdate: vi.fn(),
      dismissUpdate: vi.fn()
    }
  };
});

vi.mock("./session", () => ({
  useSession: () => ({
    session: harness.session,
    api: harness.availabilityApi,
    logout: harness.logout
  })
}));

vi.mock("./workspace-data", () => ({
  useWorkspaceData: () => ({
    error: null,
    setError: harness.setError,
    refreshAll: harness.refreshAll
  })
}));

vi.mock("../features/calls/CallSessionProvider", () => ({
  CallSessionProvider: ({ children }: { children: ReactNode }) => {
    useEffect(() => {
      harness.callProviderMount();
      return () => harness.callProviderUnmount();
    }, []);
    return children;
  },
  useCallSession: () => ({ teardownCall: harness.teardownCall })
}));

vi.mock("../features/telephony/TelephonyProvider", () => ({
  TelephonyProvider: ({ children }: { children: ReactNode }) => children
}));

vi.mock("../features/notifications/NotificationCenter", () => ({
  NotificationCenter: () => <button type="button">Notifications</button>
}));

vi.mock("../features/instant-room/idempotency", () => ({
  beginNewInstantRoomVisit: vi.fn()
}));

vi.mock("../features/instant-room/memberContinuity", () => ({
  clearMemberInstantRoomContinuity: vi.fn()
}));

vi.mock("../pwa/PwaProvider", () => ({
  usePwa: () => harness.pwa
}));

function WorkspacePage({ title }: { title: string }) {
  const [draft, setDraft] = useState("");
  const { hasSidebarNavigation } = useContextualNavigation();
  useEffect(() => {
    harness.pageMount();
    return () => harness.pageUnmount();
  }, []);
  return <main id="main-content">
    <h1>{title}</h1>
    <label>Unsent draft<textarea value={draft} onChange={(event) => setDraft(event.currentTarget.value)} /></label>
    <output aria-label="Visible contextual navigation">{String(hasSidebarNavigation)}</output>
    <ContextualNavigation><nav aria-label="Page sections"><button type="button">Overview</button></nav></ContextualNavigation>
  </main>;
}

function productShellTree(initialEntry = "/app") {
  return (
    <MemoryRouter initialEntries={[initialEntry]}>
      <RouterHistoryProvider>
      <Routes>
        <Route path="/app" element={<ProductShell />}>
          <Route index element={<WorkspacePage title="Inbox" />} />
          <Route path="you" element={<main id="main-content"><h1>You</h1></main>} />
        </Route>
        <Route path="/admin" element={<ProductShell />}>
          <Route index element={<WorkspacePage title="Workspace settings" />} />
        </Route>
        <Route path="/ops" element={<ProductShell />}>
          <Route index element={<WorkspacePage title="Service operations" />} />
        </Route>
      </Routes>
      </RouterHistoryProvider>
    </MemoryRouter>
  );
}

function renderProductShell() {
  return render(productShellTree());
}

function responsiveViewport(initialDesktop: boolean) {
  let desktop = initialDesktop;
  const listeners = new Set<() => void>();
  vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
    get matches() { return desktop && query === "(min-width: 761px) and (min-height: 561px)"; },
    media: query,
    onchange: null,
    addEventListener: (_type: string, listener: EventListenerOrEventListenerObject) => {
      if (query === "(min-width: 761px) and (min-height: 561px)") listeners.add(listener as () => void);
    },
    removeEventListener: (_type: string, listener: EventListenerOrEventListenerObject) => listeners.delete(listener as () => void),
    addListener: vi.fn(), removeListener: vi.fn(), dispatchEvent: vi.fn()
  }));
  return (nextDesktop: boolean) => act(() => {
    desktop = nextDesktop;
    listeners.forEach((listener) => listener());
  });
}

describe("ProductShell", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
    harness.pwa.installMode = "unavailable";
    harness.pwa.updateAvailable = false;
    harness.availabilityApi = undefined;
    harness.session.user.role = "member";
    harness.session.user.account_type = "human";
    harness.session.user.access_scope = "workspace";
    harness.session.user.platform_role = null;
    harness.session.user.platform_role_expires_at = null;
    harness.pwa.requestInstall.mockResolvedValue("accepted");
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      writable: true,
      value: vi.fn().mockImplementation((query: string) => ({
        matches: false,
        media: query,
        onchange: null,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn()
      }))
    });
  });

  it("offers persistent quick status from the desktop account menu and links to its schedule", async () => {
    responsiveViewport(true);
    const value = { status: "available", presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: {}, dnd_active: false, retry_at: null, timezone: "Etc/UTC" };
    harness.availabilityApi = { availability: vi.fn().mockResolvedValue(value), updateAvailability: vi.fn().mockResolvedValue({ ...value, status: "dnd", presence_state: "dnd", dnd_active: true }) };
    renderProductShell();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Account menu for Taylor Example" }));
    await user.click(await screen.findByRole("button", { name: "Pause notifications" }));
    expect(await screen.findByText("Do not disturb saved.")).toBeVisible();
    expect(harness.availabilityApi.updateAvailability).toHaveBeenCalledWith(expect.objectContaining({ presence_state: "dnd", dnd_schedule: {} }));
    await user.click(screen.getByRole("link", { name: "Schedule and notification settings" }));
    expect(screen.getByRole("heading", { name: "You" })).toBeVisible();
    expect(document.querySelector(".workspace-account-menu")).not.toHaveAttribute("open");
  });

  it("separates administration from daily destinations and returns to the workspace", async () => {
    harness.session.user.role = "owner";
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(min-width: 761px) and (min-height: 561px)", media: query,
      onchange: null, addEventListener: vi.fn(), removeEventListener: vi.fn(),
      addListener: vi.fn(), removeListener: vi.fn(), dispatchEvent: vi.fn()
    }));
    render(productShellTree("/admin"));
    expect(screen.getByRole("navigation", { name: "Administration navigation" })).toBeVisible();
    expect(screen.queryByRole("navigation", { name: "Workspace tools" })).not.toBeInTheDocument();
    const sidebar = screen.getByRole("complementary", { name: "Workspace navigation" });
    expect(sidebar).toContainElement(screen.getByRole("navigation", { name: "Page sections" }));
    expect(screen.queryByRole("button", { name: "New instant room" })).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("link", { name: "Return to workspace" }));
    expect(screen.getByRole("navigation", { name: "Workspace tools" })).toBeVisible();
    expect(screen.getByRole("button", { name: "New instant room" })).toBeVisible();
  });

  /*
   * The phone shell used to carry a top bar that named the surface from the
   * pathname. A conversation is addressed by query string, so on the busiest
   * screen in the product that bar read "Inbox" while you were reading a room —
   * and the bottom bar was already saying which destination you were in. There
   * is now nothing above the content at all.
   */
  it("renders no shell chrome above the content on a phone", () => {
    renderProductShell();

    expect(document.querySelector(".topbar")).toBeNull();
    expect(document.querySelector(".mobile-workspace-heading")).toBeNull();
    expect(screen.queryByRole("button", { name: "Open more menu" })).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "More" })).not.toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Primary navigation" })).toBeVisible();
    const primary = screen.getByRole("navigation", { name: "Primary navigation" });
    expect(within(primary).getAllByRole("link").map((link) => link.textContent)).toEqual(["Inbox", "Calls", "Directory", "Files", "You"]);
  });

  /*
   * Installation moved to the You screen, which already carried the install
   * card; the drawer copy was a duplicate. SettingsPage.test.tsx owns that
   * behaviour now, so the shell only has to prove it stopped offering it.
   */
  it("leaves installation to the You screen", () => {
    harness.pwa.installMode = "manual-ios";
    renderProductShell();

    expect(screen.queryByRole("button", { name: "Install K-Comms" })).not.toBeInTheDocument();
  });

  it("shows an explicit update warning and reloads only when requested", async () => {
    harness.pwa.updateAvailable = true;
    const user = userEvent.setup();
    renderProductShell();

    const banner = screen.getByRole("status", { name: "Update ready" });
    expect(banner).toHaveTextContent("Update ready");
    expect(banner).toHaveTextContent("Finish active calls and save any drafts");
    expect(harness.pwa.applyUpdate).not.toHaveBeenCalled();

    await user.click(screen.getByRole("button", { name: "Reload" }));
    expect(harness.pwa.applyUpdate).toHaveBeenCalledOnce();
    expect(harness.pwa.dismissUpdate).not.toHaveBeenCalled();
  });

  it("lets a user defer an update without applying it", async () => {
    harness.pwa.updateAvailable = true;
    const user = userEvent.setup();
    renderProductShell();

    await user.click(screen.getByRole("button", { name: "Later" }));
    expect(harness.pwa.dismissUpdate).toHaveBeenCalledOnce();
    expect(harness.pwa.applyUpdate).not.toHaveBeenCalled();
  });

  it("renders desktop workspace controls and persistent shortcuts without browser window buttons", () => {
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(min-width: 761px) and (min-height: 561px)",
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }));

    const { container } = renderProductShell();
    expect(container.querySelector(".desktop-shell-header")).toBeVisible();
    expect(screen.getByRole("navigation", { name: "Workspace shortcuts" })).toBeVisible();
    expect(screen.getByRole("link", { name: "Open Calls" })).toHaveAttribute("href", "/app/calls");
    expect(screen.queryByRole("button", { name: "Minimize" })).not.toBeInTheDocument();
    expect(screen.getByRole("complementary", {
      name: "Workspace navigation"
    })).toBeVisible();
    expect(screen.queryByRole("button", {
      name: "Open more menu"
    })).not.toBeInTheDocument();
  });

  it("keeps titlebar actions in a narrow installed overlay without adding a desktop rail", () => {
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(display-mode: window-controls-overlay)", media: query,
      onchange: null, addEventListener: vi.fn(), removeEventListener: vi.fn(),
      addListener: vi.fn(), removeListener: vi.fn(), dispatchEvent: vi.fn()
    }));
    const { container } = renderProductShell();
    expect(container.querySelector(".app-shell")).toHaveClass("desktop-chrome");
    expect(screen.getByRole("menubar", { name: "Application menu" })).toBeInTheDocument();
    expect(screen.queryByRole("navigation", { name: "Workspace shortcuts" })).not.toBeInTheDocument();
    expect(screen.queryByRole("complementary", { name: "Workspace navigation" })).not.toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Primary navigation" })).toBeInTheDocument();
  });

  it("uses an accessible compact dock and lets users pin the expanded navigation", async () => {
    window.localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "false");
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(min-width: 761px) and (min-height: 561px)",
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }));
    const user = userEvent.setup();
    const view = renderProductShell();

    const sidebar = screen.getByRole("complementary", {
      name: "Workspace navigation"
    });
    const toggle = screen.getByRole("button", {
      name: "Toggle workspace navigation"
    });
    expect(sidebar).toHaveClass("is-collapsed");
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    await user.hover(sidebar);
    expect(sidebar).toHaveClass("is-collapsed");
    await user.unhover(sidebar);
    expect(sidebar).toHaveClass("is-collapsed");

    await user.click(toggle);
    expect(sidebar).toHaveClass("is-expanded");
    expect(window.localStorage.getItem(
      "k-comms.workspace-sidebar-collapsed.v1"
    )).toBe("true");
    expect(screen.getByRole("button", {
      name: "Toggle workspace navigation"
    })).toHaveAttribute("aria-expanded", "true");

    view.unmount();
    renderProductShell();
    expect(screen.getByRole("button", {
      name: "Toggle workspace navigation"
    })).toHaveAttribute("aria-expanded", "true");
  });

  it("opens for keyboard focus and hides accessibly on Escape", async () => {
    window.localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "false");
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(min-width: 761px) and (min-height: 561px)",
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }));
    const user = userEvent.setup();
    renderProductShell();

    const sidebar = screen.getByRole("complementary", {
      name: "Workspace navigation"
    });
    const focusedControl = screen.getByRole("button", { name: "Switch conversation or screen" });
    act(() => focusedControl.focus());
    await waitFor(() => expect(sidebar).toHaveClass("is-expanded"));

    await user.keyboard("{Escape}");
    await waitFor(() => expect(sidebar).toHaveClass("is-collapsed"));
    expect(sidebar).toHaveAttribute("inert");
    expect(sidebar).toHaveAttribute("aria-hidden", "true");
    expect(screen.getByRole("button", { name: "Show workspace navigation" })).toBeVisible();
    expect(focusedControl).not.toHaveFocus();
  });

  it("keeps labeled navigation visible by default and exposes direct personal settings", async () => {
    vi.mocked(window.matchMedia).mockImplementation((query: string) => ({
      matches: query === "(min-width: 761px) and (min-height: 561px)", media: query,
      onchange: null, addEventListener: vi.fn(), removeEventListener: vi.fn(),
      addListener: vi.fn(), removeListener: vi.fn(), dispatchEvent: vi.fn()
    }));
    const user = userEvent.setup();
    renderProductShell();
    const sidebar = screen.getByRole("complementary", { name: "Workspace navigation" });
    expect(sidebar).toHaveClass("is-expanded");
    await user.click(screen.getByRole("heading", { name: "Inbox" }));
    expect(sidebar).not.toHaveAttribute("inert");
    await user.click(screen.getByLabelText("Account menu for Taylor Example"));
    expect(screen.getByRole("link", { name: "Profile & settings" })).toHaveAttribute("href", "/app/you?section=profile");
    expect(screen.getByRole("link", { name: "Audio & video" })).toHaveAttribute("href", "/app/you?section=audio-video");
  });

  it("assigns each desktop destination to one navigation surface and keeps a single account control", () => {
    responsiveViewport(true);
    renderProductShell();

    const rail = screen.getByRole("navigation", { name: "Workspace shortcuts" });
    const sidebar = screen.getByRole("complementary", { name: "Workspace navigation" });
    expect(within(rail).getAllByRole("link", { name: /^Open / }).map((link) => link.getAttribute("href"))).toEqual([
      "/app/", "/app/calls", "/app/meetings", "/app/content", "/app/files", "/app/directory"
    ]);
    expect(within(sidebar).getAllByRole("link").map((link) => link.getAttribute("href"))).toEqual([
      "/app/private", "/app/saved", "/app/calls/phone", "/app/artifacts", "/app/documents", "/app/whiteboard"
    ]);
    expect(within(sidebar).getByRole("button", { name: "New instant room" })).toBeVisible();
    expect(screen.getAllByLabelText("Account menu for Taylor Example")).toHaveLength(1);
    expect(rail).toContainElement(screen.getByLabelText("Account menu for Taylor Example"));
    expect(within(sidebar).queryByLabelText("Account menu for Taylor Example")).not.toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Toggle workspace navigation" })).toHaveLength(1);
  });

  it.each([
    { role: "member" as const, scope: "workspace" as const, administration: false },
    { role: "owner" as const, scope: "workspace" as const, administration: true },
    { role: "moderator" as const, scope: "workspace" as const, administration: true },
    { role: "owner" as const, scope: "conversation_only" as const, administration: false }
  ])("filters role shortcuts for $role with $scope access", async ({ role, scope, administration }) => {
    responsiveViewport(true);
    harness.session.user.role = role;
    harness.session.user.access_scope = scope;
    renderProductShell();
    const rail = screen.getByRole("navigation", { name: "Workspace shortcuts" });
    expect(Boolean(within(rail).queryByRole("link", { name: "Open Workspace administration" }))).toBe(administration);
    expect(within(rail).queryByRole("link", { name: "Open Service operations" })).not.toBeInTheDocument();

    await userEvent.setup().click(screen.getByLabelText("Account menu for Taylor Example"));
    expect(Boolean(screen.queryByRole("link", { name: "Workspace administration" }))).toBe(administration);
    expect(screen.queryByRole("link", { name: "Service operations" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Profile & settings" })).toHaveAttribute("href", "/app/you?section=profile");
  });

  it("keeps operations access separate from tenant authority", async () => {
    responsiveViewport(true);
    harness.session.user.platform_role = "platform_operator";
    harness.session.user.platform_role_expires_at = "2099-01-01T00:00:00Z";
    render(productShellTree("/ops"));
    expect(screen.getByRole("link", { name: "Open Service operations" })).toHaveAttribute("href", "/ops");
    expect(screen.queryByRole("link", { name: "Open Workspace administration" })).not.toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Administration navigation" })).toContainElement(screen.getByRole("link", { name: "Return to workspace" }));
    expect(screen.queryByRole("navigation", { name: "Workspace tools" })).not.toBeInTheDocument();
    const sidebar = screen.getByRole("complementary", { name: "Workspace navigation" });
    expect(sidebar).toContainElement(screen.getByRole("navigation", { name: "Page sections" }));

    await userEvent.setup().click(screen.getByLabelText("Account menu for Taylor Example"));
    expect(screen.getByRole("link", { name: "Service operations" })).toHaveAttribute("href", "/ops");
  });

  it("closes the account menu outside, on Escape and after selecting settings", async () => {
    responsiveViewport(true);
    const user = userEvent.setup();
    renderProductShell();
    const trigger = screen.getByLabelText("Account menu for Taylor Example");
    const menu = trigger.closest("details")!;
    await user.click(trigger);
    expect(menu).toHaveAttribute("open");
    await user.click(screen.getByRole("heading", { name: "Inbox" }));
    expect(menu).not.toHaveAttribute("open");

    await user.click(trigger);
    await user.keyboard("{Escape}");
    expect(menu).not.toHaveAttribute("open");
    expect(trigger).toHaveFocus();

    await user.click(trigger);
    await user.click(screen.getByRole("link", { name: "Profile & settings" }));
    expect(screen.getByRole("heading", { name: "You" })).toBeVisible();
    expect(menu).not.toHaveAttribute("open");
  });

  it("moves page navigation on resize without remounting content or the call provider", async () => {
    const resize = responsiveViewport(true);
    const user = userEvent.setup();
    renderProductShell();
    await user.type(screen.getByRole("textbox", { name: "Unsent draft" }), "Keep this unsent message");
    const draft = screen.getByRole("textbox", { name: "Unsent draft" });
    expect(screen.getByRole("complementary", { name: "Workspace navigation" })).toContainElement(screen.getByRole("navigation", { name: "Page sections" }));
    expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("true");

    resize(false);
    expect(screen.queryByRole("complementary", { name: "Workspace navigation" })).not.toBeInTheDocument();
    expect(screen.getByRole("main")).toContainElement(screen.getByRole("navigation", { name: "Page sections" }));
    expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("false");
    expect(within(screen.getByRole("navigation", { name: "Primary navigation" })).getAllByRole("link")).toHaveLength(5);

    resize(true);
    expect(screen.getByRole("complementary", { name: "Workspace navigation" })).toContainElement(screen.getByRole("navigation", { name: "Page sections" }));
    expect(screen.getByRole("textbox", { name: "Unsent draft" })).toBe(draft);
    expect(draft).toHaveValue("Keep this unsent message");
    expect(harness.pageMount).toHaveBeenCalledOnce();
    expect(harness.pageUnmount).not.toHaveBeenCalled();
    expect(harness.callProviderMount).toHaveBeenCalledOnce();
    expect(harness.callProviderUnmount).not.toHaveBeenCalled();
  });

  it("auto-hides only the unpinned dock and keeps the sidebar navigation contract stable", () => {
    vi.useFakeTimers();
    try {
      window.localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "false");
      responsiveViewport(true);
      const { container } = renderProductShell();
      const sidebar = screen.getByRole("complementary", { name: "Workspace navigation" });
      expect(container.querySelector(".app-shell")).toHaveClass("workspace-sidebar-collapsed");
      expect(container.querySelector(".app-shell")).not.toHaveClass("workspace-navigation-pinned");
      expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("false");
      act(() => vi.advanceTimersByTime(8_000));
      expect(sidebar).toHaveClass("is-hidden");
      expect(sidebar).toHaveAttribute("inert");
      expect(sidebar).toHaveAttribute("aria-hidden", "true");
      expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("false");
      fireEvent.click(screen.getByRole("button", { name: "Show workspace navigation" }));
      expect(sidebar).not.toHaveAttribute("inert");
      expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("false");
      fireEvent.click(screen.getByRole("button", { name: "Toggle workspace navigation" }));
      expect(container.querySelector(".app-shell")).toHaveClass("workspace-navigation-pinned");
      expect(screen.getByLabelText("Visible contextual navigation")).toHaveTextContent("true");
      act(() => vi.advanceTimersByTime(16_000));
      expect(sidebar).not.toHaveClass("is-hidden");
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves editor shortcuts and modal consent before opening quick navigation", () => {
    renderProductShell();
    fireEvent.keyDown(screen.getByRole("textbox", { name: "Unsent draft" }), { key: "k", ctrlKey: true });
    expect(screen.queryByRole("dialog", { name: "Go to…" })).not.toBeInTheDocument();
    const modal = document.createElement("section");
    modal.setAttribute("aria-modal", "true");
    document.body.append(modal);
    try {
      fireEvent.keyDown(document, { key: "k", ctrlKey: true });
      expect(screen.queryByRole("dialog", { name: "Go to…" })).not.toBeInTheDocument();
    } finally {
      modal.remove();
    }
    fireEvent.keyDown(document, { key: "k", ctrlKey: true });
    expect(screen.getByRole("dialog", { name: "Go to…" })).toBeVisible();
  });

  it("dismisses quick navigation on browser history before a pending route commits", () => {
    renderProductShell();
    fireEvent.keyDown(document, { key: "k", ctrlKey: true });
    expect(screen.getByRole("dialog", { name: "Go to…" })).toBeVisible();
    fireEvent(window, new PopStateEvent("popstate"));
    expect(screen.queryByRole("dialog", { name: "Go to…" })).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Inbox" })).toBeVisible();
  });
});
