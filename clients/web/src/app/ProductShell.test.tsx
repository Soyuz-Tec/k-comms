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

describe("ProductShell PWA controls", () => {
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

  it("names the current destination in the mobile top bar", () => {
    renderProductShell();

    const topbar = document.querySelector(".mobile-workspace-heading");
    expect(topbar).toHaveTextContent("Inbox");
    expect(topbar).toHaveTextContent("Example workspace");
    expect(document.querySelector(".mobile-workspace-brand .workspace-mark")).toBeNull();
  });

  it("offers a familiar mobile install action and shows iOS instructions", async () => {
    harness.pwa.installMode = "manual-ios";
    const user = userEvent.setup();
    renderProductShell();

    await user.click(screen.getByRole("button", { name: "Open more menu" }));
    const install = screen.getByRole("button", { name: "Install K-Comms" });
    expect(install.querySelector(".lucide-download")).toBeInTheDocument();
    await user.click(install);

    const dialog = screen.getByRole("dialog", { name: "Install K-Comms" });
    expect(dialog).toHaveTextContent("Share → Add to Home Screen");
    expect(dialog).toHaveTextContent("Open as Web App");
    const close = screen.getByRole("button", { name: "Close install instructions" });
    await waitFor(() => expect(close).toHaveFocus());

    await user.tab({ shift: true });
    expect(screen.getByRole("button", { name: "Done" })).toHaveFocus();
    await user.tab();
    expect(close).toHaveFocus();

    await user.click(close);
    await waitFor(() => expect(dialog).not.toBeInTheDocument());
    await waitFor(() => expect(install).toHaveFocus());
    expect(harness.pwa.requestInstall).not.toHaveBeenCalled();
  });

  it("calls the native prompt directly, then offers manual steps after dismissal", async () => {
    harness.pwa.installMode = "native-prompt";
    harness.pwa.requestInstall.mockResolvedValue("dismissed");
    const user = userEvent.setup();
    const view = renderProductShell();

    await user.click(screen.getByRole("button", { name: "Open more menu" }));
    await user.click(screen.getByRole("button", { name: "Install K-Comms" }));

    await waitFor(() => expect(harness.pwa.requestInstall).toHaveBeenCalledOnce());
    expect(screen.queryByRole("dialog", { name: "Install K-Comms" })).not.toBeInTheDocument();

    harness.pwa.installMode = "manual-browser";
    view.rerender(productShellTree());
    await user.click(screen.getByRole("button", { name: "Install K-Comms" }));
    expect(await screen.findByRole("dialog", { name: "Install K-Comms" })).toHaveTextContent(
      "Install app or Add to Home screen"
    );
  });

  it("hides the mobile install action after installation or when unavailable", async () => {
    harness.pwa.installMode = "installed";
    const user = userEvent.setup();
    const view = renderProductShell();

    await user.click(screen.getByRole("button", { name: "Open more menu" }));
    expect(screen.queryByRole("button", { name: "Install K-Comms" })).not.toBeInTheDocument();

    view.unmount();
    harness.pwa.installMode = "unavailable";
    renderProductShell();
    await user.click(screen.getByRole("button", { name: "Open more menu" }));
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

  it("persists an accessible compact workspace rail", async () => {
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
    const collapse = screen.getByRole("button", {
      name: "Collapse navigation sidebar"
    });
    expect(collapse).toHaveAttribute("aria-pressed", "false");

    await user.click(collapse);
    expect(sidebar).toHaveClass("is-collapsed");
    expect(window.localStorage.getItem(
      "k-comms.workspace-sidebar-collapsed.v1"
    )).toBe("true");

    view.unmount();
    renderProductShell();
    expect(screen.getByRole("button", {
      name: "Expand navigation sidebar"
    })).toHaveAttribute("aria-pressed", "true");
  });
});
