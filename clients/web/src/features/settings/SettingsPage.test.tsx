import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "../../types";
import type { SessionUpdate } from "../../app/session";
import { SettingsPage } from "./SettingsPage";

const harness = vi.hoisted(() => {
  const session: Session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 900,
    tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
    user: {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Original Name",
      email: "verified@example.test",
      role: "member" as const,
      status: "active"
    },
    device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
  };

  return {
    initialSession: session,
    currentSession: session as Session | null,
    api: {
      devices: vi.fn(),
      sessions: vi.fn(),
      notificationPreference: vi.fn(),
      notifications: vi.fn(),
      notificationAttempts: vi.fn(),
      updateNotificationPreference: vi.fn(),
      revokeDevice: vi.fn(),
      revokeSession: vi.fn(),
      updateProfile: vi.fn()
    },
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
    },
    setSession: vi.fn()
  };
});

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: harness.currentSession,
    setSession: harness.setSession
  })
}));

vi.mock("../../pwa/PwaProvider", () => ({
  usePwa: () => harness.pwa
}));

describe("profile settings", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.currentSession = structuredClone(harness.initialSession);
    harness.setSession.mockImplementation((update: SessionUpdate) => {
      harness.currentSession =
        typeof update === "function" ? update(harness.currentSession) : update;
    });
    harness.api.devices.mockResolvedValue([]);
    harness.api.sessions.mockResolvedValue([]);
    harness.api.notificationPreference.mockResolvedValue(null);
    harness.api.notifications.mockResolvedValue([]);
    harness.api.notificationAttempts.mockResolvedValue([]);
    harness.api.updateNotificationPreference.mockResolvedValue({
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: [],
      updated_at: "2026-07-14T12:00:00Z"
    });
    harness.api.revokeDevice.mockResolvedValue(undefined);
    harness.api.revokeSession.mockResolvedValue(undefined);
    harness.api.updateProfile.mockResolvedValue({
      ...harness.initialSession.user,
      display_name: "Updated Name"
    });
    harness.pwa.installMode = "unavailable";
    harness.pwa.requestInstall.mockResolvedValue("accepted");
  });

  it("renders the recovery email read-only and submits only the display name", async () => {
    const user = userEvent.setup();
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const email = screen.getByRole("textbox", { name: /Email address/i });
    expect(email).toHaveValue("verified@example.test");
    expect(email).toHaveAttribute("readonly");
    expect(screen.getByText("Verified account email")).toBeVisible();

    const displayName = screen.getByLabelText("Display name");
    await user.clear(displayName);
    await user.type(displayName, "Updated Name");
    await user.click(screen.getByRole("button", { name: "Save profile" }));

    await waitFor(() =>
      expect(harness.api.updateProfile).toHaveBeenCalledWith({ display_name: "Updated Name" })
    );
    await waitFor(() => expect(harness.setSession).toHaveBeenCalledWith(expect.any(Function)));
    expect(harness.currentSession?.user.display_name).toBe("Updated Name");
  });

  it("merges a delayed profile response into the latest refreshed credentials", async () => {
    const pending = deferred<Session["user"]>();
    harness.api.updateProfile.mockReturnValue(pending.promise);
    const user = userEvent.setup();
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const displayName = screen.getByLabelText("Display name");
    await user.clear(displayName);
    await user.type(displayName, "Updated After Refresh");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledOnce());

    harness.currentSession = {
      ...harness.initialSession,
      access_token: "refreshed-access-token",
      refresh_token: "rotated-refresh-token",
      received_at: Date.now()
    };

    pending.resolve({
      ...harness.initialSession.user,
      display_name: "Updated After Refresh"
    });

    await waitFor(() => expect(harness.setSession).toHaveBeenCalledWith(expect.any(Function)));
    expect(harness.currentSession?.access_token).toBe("refreshed-access-token");
    expect(harness.currentSession?.refresh_token).toBe("rotated-refresh-token");
    expect(harness.currentSession?.user.display_name).toBe("Updated After Refresh");
  });

  it("does not restore a revoked session when a delayed profile response completes", async () => {
    const pending = deferred<Session["user"]>();
    harness.api.updateProfile.mockReturnValue(pending.promise);
    const user = userEvent.setup();
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledOnce());

    harness.currentSession = null;
    pending.resolve({ ...harness.initialSession.user, display_name: "Late Update" });

    await waitFor(() => expect(harness.setSession).toHaveBeenCalledWith(expect.any(Function)));
    expect(harness.currentSession).toBeNull();
  });

  it("uses plain-language notification choices while preserving advanced muted categories", async () => {
    harness.api.notificationPreference.mockResolvedValue({
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: ["mention.created.v1", "custom.workflow.v1"],
      updated_at: "2026-07-14T11:00:00Z"
    });
    const user = userEvent.setup();
    render(<SettingsPage />);

    await user.click(screen.getByRole("tab", { name: "Notifications" }));
    const messages = await screen.findByRole("checkbox", { name: "New messages" });
    const mentions = screen.getByRole("checkbox", { name: "Mentions and direct attention" });
    expect(messages).toBeChecked();
    expect(mentions).not.toBeChecked();
    expect(screen.queryByText("message.created.v1")).not.toBeInTheDocument();

    await user.click(messages);
    await user.click(screen.getByRole("button", { name: "Save notifications" }));

    await waitFor(() => expect(harness.api.updateNotificationPreference).toHaveBeenCalledWith({
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: ["message.created.v1", "mention.created.v1", "custom.workflow.v1"]
    }));
  });

  it("keeps successful settings sections usable when another resource fails", async () => {
    harness.api.devices.mockRejectedValue(new Error("Device service is unavailable"));
    harness.api.sessions.mockResolvedValue([{
      id: "session-12345678",
      user_id: "user-1",
      device_id: "device-2",
      expires_at: "2026-07-21T12:00:00Z",
      last_used_at: "2026-07-14T12:00:00Z",
      inserted_at: "2026-07-14T11:00:00Z",
      revoked_at: null
    }]);
    harness.api.notificationPreference.mockResolvedValue({
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: [],
      updated_at: "2026-07-14T11:00:00Z"
    });

    const user = userEvent.setup();
    render(<SettingsPage />);

    const warning = await screen.findByRole("status");
    expect(warning).toHaveTextContent("Some settings could not be loaded");
    expect(warning).toHaveTextContent("Devices:");
    expect(warning).toHaveTextContent("Device service is unavailable");
    expect(screen.queryByText("Sessions:")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save profile" })).toBeEnabled();

    await user.click(screen.getByRole("tab", { name: "Security" }));
    expect(screen.queryByRole("button", { name: "Save profile" })).not.toBeInTheDocument();
    await user.click(screen.getByText("Sessions"));
    expect(screen.getByText("Session session-")).toBeVisible();

    await user.click(screen.getByRole("tab", { name: "Notifications" }));
    expect(screen.getByRole("checkbox", { name: "New messages" })).toBeEnabled();
    expect(
      screen.getByRole("button", { name: "Dismiss settings load warning" })
    ).toBeEnabled();
  });

  it("shows one settings section at a time", async () => {
    harness.api.notificationPreference.mockResolvedValue({
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: [],
      updated_at: "2026-07-14T11:00:00Z"
    });
    const user = userEvent.setup();
    const { container } = render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    expect(container.querySelector("#profile-settings")).toBeVisible();
    expect(container.querySelector("#password-settings")).not.toBeInTheDocument();
    expect(container.querySelector("#notification-settings")).not.toBeInTheDocument();

    const profileTab = screen.getByRole("tab", { name: "Profile" });
    profileTab.focus();
    await user.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Security" })).toHaveFocus();
    expect(screen.getByRole("tab", { name: "Security" })).toHaveAttribute("aria-selected", "true");
    expect(container.querySelector("#password-settings")).toBeVisible();
    expect(container.querySelector("#profile-settings")).not.toBeInTheDocument();

    await user.click(screen.getByRole("tab", { name: "Notifications" }));
    expect(container.querySelector("#notification-settings")).toBeVisible();
    expect(container.querySelector("#password-settings")).not.toBeInTheDocument();
  });

  it("shows installed status without offering another install action", async () => {
    harness.pwa.installMode = "installed";
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const card = screen.getByRole("heading", { name: "Install K-Comms" }).closest("section");
    expect(card).toHaveTextContent("Installed");
    expect(screen.queryByRole("button", { name: "Install K-Comms" })).not.toBeInTheDocument();
  });

  it("opens iPhone and iPad install help with trapped focus and restores the trigger", async () => {
    harness.pwa.installMode = "manual-ios";
    const user = userEvent.setup();
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const trigger = screen.getByRole("button", { name: "Show install steps" });
    trigger.focus();
    await user.click(trigger);

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
    await waitFor(() => expect(trigger).toHaveFocus());
    expect(harness.pwa.requestInstall).not.toHaveBeenCalled();
  });

  it("uses the native prompt and offers manual browser steps after dismissal", async () => {
    harness.pwa.installMode = "native-prompt";
    harness.pwa.requestInstall.mockResolvedValue("dismissed");
    const user = userEvent.setup();
    const view = render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.click(screen.getByRole("button", { name: "Install K-Comms" }));

    await waitFor(() => expect(harness.pwa.requestInstall).toHaveBeenCalledOnce());
    expect(screen.queryByRole("dialog", { name: "Install K-Comms" })).not.toBeInTheDocument();

    harness.pwa.installMode = "manual-browser";
    view.rerender(<SettingsPage />);
    await user.click(screen.getByRole("button", { name: "Show install steps" }));
    expect(await screen.findByRole("dialog", { name: "Install K-Comms" })).toHaveTextContent(
      "Install app or Add to Home screen"
    );
  });

  it("hides install settings when this browser cannot support installation", async () => {
    harness.pwa.installMode = "unavailable";
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    expect(screen.queryByRole("heading", { name: "Install K-Comms" })).not.toBeInTheDocument();
  });

  it("reviews device revocation in an accessible dialog before calling the API", async () => {
    harness.api.devices.mockResolvedValue([{
      id: "device-2",
      user_id: "user-1",
      name: "Shared kiosk",
      platform: "web",
      last_seen_at: "2026-07-14T10:00:00Z"
    }]);
    const user = userEvent.setup();
    render(<SettingsPage />);

    await user.click(screen.getByRole("tab", { name: "Security" }));
    await screen.findByText("1 known");
    await user.click(screen.getByText("Devices"));
    await user.click(screen.getByRole("button", { name: "Revoke device" }));

    const dialog = screen.getByRole("alertdialog", { name: "Revoke device?" });
    expect(dialog).toHaveTextContent("All active sessions on this device will stop working");
    await user.click(screen.getByRole("button", { name: "Revoke device" }));

    await waitFor(() => expect(harness.api.revokeDevice).toHaveBeenCalledWith("device-2"));
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}
