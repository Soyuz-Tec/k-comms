import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "../types";
import { ProductShell } from "./ProductShell";

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
    logout: vi.fn(),
    teardownCall: vi.fn(),
    refreshAll: vi.fn(),
    setError: vi.fn(),
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
  CallSessionProvider: ({ children }: { children: ReactNode }) => children,
  useCallSession: () => ({ teardownCall: harness.teardownCall })
}));

vi.mock("../features/notifications/NotificationCenter", () => ({
  NotificationCenter: () => <button type="button">Notifications</button>
}));

vi.mock("../components/MemberAreaLinks", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  MemberAreaLinks: () => <a href="/app/">Inbox</a>
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

function productShellTree() {
  return (
    <MemoryRouter initialEntries={["/app"]}>
      <Routes>
        <Route path="/app" element={<ProductShell />}>
          <Route index element={<main id="main-content"><h1>Inbox</h1></main>} />
        </Route>
      </Routes>
    </MemoryRouter>
  );
}

function renderProductShell() {
  return render(productShellTree());
}

describe("ProductShell", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
    harness.pwa.installMode = "unavailable";
    harness.pwa.updateAvailable = false;
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

    const banner = screen.getByRole("status");
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

  it("renders a desktop-only safe drag region for Window Controls Overlay", () => {
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
    expect(container.querySelector(".window-titlebar-drag-region")).toHaveAttribute(
      "aria-hidden",
      "true"
    );
    expect(screen.getByRole("complementary", {
      name: "Workspace navigation"
    })).toBeVisible();
    expect(screen.queryByRole("button", {
      name: "Open more menu"
    })).not.toBeInTheDocument();
  });

  it("uses an accessible compact dock and lets users pin the expanded navigation", async () => {
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
      name: "Keep navigation open"
    });
    expect(sidebar).toHaveClass("is-collapsed");
    expect(toggle).toHaveAttribute("aria-pressed", "false");

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
      name: "Use compact navigation"
    })).toHaveAttribute("aria-pressed", "true");

    view.unmount();
    renderProductShell();
    expect(screen.getByRole("button", {
      name: "Use compact navigation"
    })).toHaveAttribute("aria-pressed", "true");
  });

  it("opens for keyboard focus and hides accessibly on Escape", async () => {
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
    const toggle = screen.getByRole("button", {
      name: "Keep navigation open"
    });
    toggle.focus();
    await waitFor(() => expect(sidebar).toHaveClass("is-expanded"));

    await user.keyboard("{Escape}");
    await waitFor(() => expect(sidebar).toHaveClass("is-collapsed"));
    expect(sidebar).toHaveAttribute("inert");
    expect(sidebar).toHaveAttribute("aria-hidden", "true");
    expect(screen.getByRole("button", { name: "Show workspace navigation" })).toBeVisible();
    expect(toggle).not.toHaveFocus();
  });
});
