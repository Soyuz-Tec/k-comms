import { render as renderView, screen, waitFor, within } from "@testing-library/react";
import type { ReactNode } from "react";
import { MemoryRouter, useLocation, useNavigate } from "react-router";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "../../types";
import type { SessionUpdate } from "../../app/session";
import { StepUpProvider } from "../../app/step-up";
import { workspaceFixture } from "../member-workspace/memberWorkspace.testSupport";
import { SettingsPage } from "./SettingsPage";
import * as profilePreferences from "./EnterpriseProfileSettings";
import { resetCallControlPreferencesForTest } from "../experience/call-control-preferences";

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
      memberWorkspace: vi.fn(),
      updateOnboarding: vi.fn(),
      devices: vi.fn(),
      sessions: vi.fn(),
      notificationPreference: vi.fn(),
      notifications: vi.fn(),
      notificationAttempts: vi.fn(),
      updateNotificationPreference: vi.fn(),
      revokeDevice: vi.fn(),
      revokeSession: vi.fn(),
      updateProfile: vi.fn(),
      calendarConnections: vi.fn()
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

function render(ui: ReactNode, path = "/app/you") {
  return renderView(ui, { wrapper: ({ children }) => <MemoryRouter initialEntries={[path]}><StepUpProvider>{children}</StepUpProvider></MemoryRouter> });
}

function LocationProbe() {
  const location = useLocation();
  const navigate = useNavigate();
  return <><output aria-label="Current URL">{location.pathname}{location.search}</output><button type="button" onClick={() => navigate(-1)}>Back</button></>;
}

describe("profile settings", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
    window.localStorage.clear();
    // The preference snapshot is memoized for identity stability, so tests
    // that seed or clear storage directly must drop it first.
    resetCallControlPreferencesForTest();
    harness.currentSession = structuredClone(harness.initialSession);
    harness.setSession.mockImplementation((update: SessionUpdate) => {
      harness.currentSession =
        typeof update === "function" ? update(harness.currentSession) : update;
    });
    harness.api.memberWorkspace.mockResolvedValue(workspaceFixture());
    harness.api.updateOnboarding.mockResolvedValue(workspaceFixture());
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
    harness.api.calendarConnections.mockResolvedValue({ data: [], meta: {
      mode: "one_way_hosted_occurrences", policy: { export_allowed: true, version: 7 },
      providers: [{ provider: "google", configured: false, qualified: false }, { provider: "microsoft", configured: false, qualified: false }]
    } });
    harness.pwa.installMode = "unavailable";
    harness.pwa.requestInstall.mockResolvedValue("accepted");
  });

  it("renders the recovery email read-only and submits only the display name", async () => {
    const user = userEvent.setup();
    render(<SettingsPage />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    expect(screen.getByText("verified@example.test")).toBeVisible();
    expect(screen.queryByRole("textbox", { name: /Email address/i })).not.toBeInTheDocument();
    expect(screen.getByText("Verified account email")).toBeVisible();
    expect(screen.getByText("Example · Member")).toBeVisible();

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

  it("hydrates a pristine display name from the current same-identity profile", async () => {
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    expect(screen.getByLabelText("Display name")).toHaveValue("Original Name");

    harness.currentSession = {
      ...harness.initialSession,
      user: { ...harness.initialSession.user, display_name: "Reviewed in another browser" }
    };
    view.rerender(<SettingsPage />);

    await waitFor(() => expect(screen.getByLabelText("Display name"))
      .toHaveValue("Reviewed in another browser"));
  });

  it("groups name, avatar and timezone in one profile form and saves an edited timezone with the name", async () => {
    const user = userEvent.setup();
    render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const profile = document.getElementById("profile-settings")!;
    expect(profile).toContainElement(screen.getByLabelText("Display name"));
    expect(profile).toContainElement(screen.getByLabelText("Avatar image", { exact: true }));
    expect(profile).toContainElement(screen.getByLabelText("Time zone", { exact: true }));
    expect(screen.queryByRole("button", { name: "Save avatar and timezone" })).not.toBeInTheDocument();
    await user.clear(screen.getByLabelText("Time zone", { exact: true }));
    await user.type(screen.getByLabelText("Time zone", { exact: true }), "Asia/Kolkata");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledWith({ display_name: "Original Name", timezone: "Asia/Kolkata" }));
  });

  it("keeps a pending timezone edit across same-identity refreshes and clears it on identity change", async () => {
    const user = userEvent.setup();
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.clear(screen.getByLabelText("Time zone", { exact: true }));
    await user.type(screen.getByLabelText("Time zone", { exact: true }), "Europe/London");
    harness.currentSession = { ...harness.initialSession, user: { ...harness.initialSession.user, timezone: "Asia/Tokyo" } };
    view.rerender(<SettingsPage />);
    expect(screen.getByLabelText("Time zone", { exact: true })).toHaveValue("Europe/London");
    harness.currentSession = { ...harness.initialSession, user: { ...harness.initialSession.user, id: "user-2", timezone: "America/New_York" } };
    view.rerender(<SettingsPage />);
    await waitFor(() => expect(screen.getByLabelText("Time zone", { exact: true })).toHaveValue("America/New_York"));
  });

  it("removes an existing avatar through the same profile save without sending an unchanged timezone", async () => {
    harness.currentSession = { ...harness.initialSession, user: { ...harness.initialSession.user, avatar_url: "data:image/png;base64,c2FtcGxl" } };
    const user = userEvent.setup(); render(<SettingsPage />);
    await user.click(screen.getByLabelText("Remove avatar"));
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledWith({ display_name: "Original Name", avatar_url: null }));
  });

  it("does not send an avatar save to a different actor after image conversion finishes", async () => {
    const image = deferred<string>();
    const conversion = vi.spyOn(profilePreferences, "avatarData").mockReturnValueOnce(image.promise);
    const user = userEvent.setup(); const view = render(<SettingsPage />);
    const file = new File(["sample"], "avatar.png", { type: "image/png" });
    await user.upload(screen.getByLabelText("Avatar image", { exact: true }), file);
    // jsdom's form serialization does not retain the synthetic uploaded File.
    const readField = FormData.prototype.get;
    const serializedFile = vi.spyOn(FormData.prototype, "get").mockImplementation(function(this: FormData, name) {
      return name === "avatar" ? file : readField.call(this, name);
    });
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(conversion).toHaveBeenCalledOnce());
    harness.currentSession = { ...harness.initialSession, user: { ...harness.initialSession.user, id: "user-2" } };
    view.rerender(<SettingsPage />);
    image.resolve("data:image/png;base64,c2FtcGxl");
    await waitFor(() => expect(screen.getByRole("button", { name: "Save profile" })).toBeEnabled());
    expect(harness.api.updateProfile).not.toHaveBeenCalled();
    conversion.mockRestore();
    serializedFile.mockRestore();
  });

  it("preserves a newer timezone edit when an earlier combined profile save finishes", async () => {
    const pending = deferred<Session["user"]>();
    harness.api.updateProfile.mockReturnValueOnce(pending.promise);
    const user = userEvent.setup(); render(<SettingsPage />);
    await user.clear(screen.getByLabelText("Time zone", { exact: true }));
    await user.type(screen.getByLabelText("Time zone", { exact: true }), "Europe/London");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledOnce());
    await user.clear(screen.getByLabelText("Time zone", { exact: true }));
    await user.type(screen.getByLabelText("Time zone", { exact: true }), "Asia/Tokyo");
    pending.resolve({ ...harness.initialSession.user, timezone: "Europe/London" });
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Profile updated."));
    expect(screen.getByLabelText("Time zone", { exact: true })).toHaveValue("Asia/Tokyo");
  });

  it("preserves a pending profile edit when the same actor receives fresh profile and role data", async () => {
    const user = userEvent.setup();
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.clear(screen.getByLabelText("Display name"));
    await user.type(screen.getByLabelText("Display name"), "Pending local edit");

    harness.currentSession = {
      ...harness.initialSession,
      user: { ...harness.initialSession.user, display_name: "Reviewed in another browser", role: "owner" }
    };
    harness.api.updateProfile.mockResolvedValue({
      ...harness.currentSession.user,
      display_name: "Pending local edit"
    });
    view.rerender(<SettingsPage />);

    expect(screen.getByLabelText("Display name")).toHaveValue("Pending local edit");
    expect(screen.getByRole("button", { name: "Save profile" })).toBeEnabled();
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile)
      .toHaveBeenCalledWith({ display_name: "Pending local edit" }));
    expect(harness.currentSession?.user.role).toBe("owner");
  });

  it.each(["user", "tenant"] as const)("clears a pending profile edit across a %s identity switch", async (changedIdentity) => {
    const user = userEvent.setup();
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.clear(screen.getByLabelText("Display name"));
    await user.type(screen.getByLabelText("Display name"), "First identity's pending edit");

    const next = structuredClone(harness.initialSession);
    next.user.display_name = "Other identity's current name";
    if (changedIdentity === "user") {
      next.user.id = "user-2";
      next.device.user_id = "user-2";
    } else {
      next.tenant.id = "tenant-2";
      next.user.tenant_id = "tenant-2";
    }
    harness.currentSession = next;
    view.rerender(<SettingsPage />);
    await waitFor(() => expect(screen.getByLabelText("Display name"))
      .toHaveValue("Other identity's current name"));

    harness.currentSession = structuredClone(harness.initialSession);
    view.rerender(<SettingsPage />);
    await waitFor(() => expect(screen.getByLabelText("Display name"))
      .toHaveValue("Original Name"));
    expect(screen.getByRole("button", { name: "Save profile" })).toBeEnabled();
  });

  it("accepts a canonical saved name and then hydrates later profile data after a padded submission", async () => {
    const pending = deferred<Session["user"]>();
    harness.api.updateProfile.mockReturnValue(pending.promise);
    const user = userEvent.setup();
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.clear(screen.getByLabelText("Display name"));
    await user.type(screen.getByLabelText("Display name"), "  Canonical Name  ");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile)
      .toHaveBeenCalledWith({ display_name: "Canonical Name" }));

    pending.resolve({ ...harness.initialSession.user, display_name: "Canonical Name" });
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Profile updated."));
    expect(screen.getByLabelText("Display name")).toHaveValue("Canonical Name");

    harness.currentSession = {
      ...harness.initialSession,
      user: { ...harness.initialSession.user, display_name: "Later current profile" }
    };
    view.rerender(<SettingsPage />);
    await waitFor(() => expect(screen.getByLabelText("Display name"))
      .toHaveValue("Later current profile"));
  });

  it("keeps a newer pending edit when an earlier submitted profile response completes", async () => {
    const pending = deferred<Session["user"]>();
    harness.api.updateProfile.mockReturnValue(pending.promise);
    const user = userEvent.setup();
    const view = render(<SettingsPage />);
    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    await user.clear(screen.getByLabelText("Display name"));
    await user.type(screen.getByLabelText("Display name"), "  Earlier submission  ");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile)
      .toHaveBeenCalledWith({ display_name: "Earlier submission" }));
    await user.clear(screen.getByLabelText("Display name"));
    await user.type(screen.getByLabelText("Display name"), "Newer pending edit");

    pending.resolve({ ...harness.initialSession.user, display_name: "Earlier submission" });
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Profile updated."));
    expect(screen.getByLabelText("Display name")).toHaveValue("Newer pending edit");

    harness.currentSession = {
      ...harness.initialSession,
      user: { ...harness.initialSession.user, display_name: "Later current profile" }
    };
    view.rerender(<SettingsPage />);
    expect(screen.getByLabelText("Display name")).toHaveValue("Newer pending edit");
    expect(screen.getByRole("button", { name: "Save profile" })).toBeEnabled();
  });

  it("keeps personal profile content before workspace and role tools", async () => {
    render(<SettingsPage roleTools={<aside aria-label="Workspace tools">Workspace tools</aside>} />);

    await waitFor(() => expect(harness.api.devices).toHaveBeenCalled());
    const profileCard = document.getElementById("profile-settings");
    const roleTools = screen.getByRole("complementary", { name: "Workspace tools" });
    expect(profileCard).not.toBeNull();
    expect(profileCard!.compareDocumentPosition(roleTools) & Node.DOCUMENT_POSITION_FOLLOWING)
      .toBeTruthy();
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

    const warning = (await screen.findByText("Some settings could not be loaded.")).closest('[role="status"]');
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

  it("opens a linked settings section, preserves other query values, and restores it on Back", async () => {
    const user = userEvent.setup();
    render(<><SettingsPage /><LocationProbe /></>, "/app/you?section=security&source=account");
    expect(screen.getByRole("tab", { name: "Security" })).toHaveAttribute("aria-selected", "true");
    await user.click(screen.getByRole("tab", { name: "Notifications" }));
    expect(screen.getByLabelText("Current URL")).toHaveTextContent("section=notifications&source=account");
    await user.click(screen.getByRole("button", { name: "Back" }));
    expect(screen.getByRole("tab", { name: "Security" })).toHaveAttribute("aria-selected", "true");
  });

  it("opens the calendar OAuth return directly in personal settings with scheduling access", async () => {
    render(<><SettingsPage /><LocationProbe /></>, "/app/you?section=calendar&calendar_result=connected&source=oauth");

    expect(screen.getByText("Personal settings")).toBeVisible();
    expect(screen.getByRole("tab", { name: "Connected calendars" })).toHaveAttribute("aria-selected", "true");
    const panel = screen.getByRole("tabpanel", { name: "Connected calendars" });
    expect(within(panel).getByRole("heading", { name: "Connected calendars" })).toBeVisible();
    expect(within(panel).getByRole("link", { name: "Meetings & scheduling" })).toHaveAttribute("href", "/app/meetings");
    expect(await within(panel).findByRole("heading", { name: "Google Calendar" })).toBeVisible();
    expect(within(panel).getByText(/Existing external events are never imported/)).toBeVisible();
    expect(panel.querySelector("details")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Display name")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Current URL")).toHaveTextContent("section=calendar&calendar_result=connected&source=oauth");
    expect(harness.api.calendarConnections).toHaveBeenCalledTimes(1);
  });

  it("loads calendar connections only when selected and preserves callback query values across settings", async () => {
    const user = userEvent.setup();
    render(<><SettingsPage /><LocationProbe /></>, "/app/you?section=profile&calendar_result=rejected");
    expect(harness.api.calendarConnections).not.toHaveBeenCalled();

    await user.click(screen.getByRole("tab", { name: "Connected calendars" }));
    expect(await screen.findByRole("heading", { name: "Google Calendar" })).toBeVisible();
    expect(screen.getByLabelText("Current URL")).toHaveTextContent("section=calendar&calendar_result=rejected");
    await user.click(screen.getByRole("tab", { name: "Profile" }));
    expect(screen.queryByRole("heading", { name: "Connected calendars" })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Back" }));
    expect(screen.getByRole("tab", { name: "Connected calendars" })).toHaveAttribute("aria-selected", "true");
    expect(await screen.findByRole("heading", { name: "Google Calendar" })).toBeVisible();
  });

  it.each([
    { name: "a limited account", accessScope: "conversation_only" as const, exportAllowed: true },
    { name: "disabled workspace export policy", accessScope: "workspace" as const, exportAllowed: false }
  ])("preserves calendar cleanup for $name while disabling new connections", async ({ accessScope, exportAllowed }) => {
    harness.currentSession = { ...harness.initialSession, user: {
      ...harness.initialSession.user, account_type: "human", access_scope: accessScope
    } };
    harness.api.calendarConnections.mockResolvedValue({
      data: [{ id: "connection-1", provider: "google", version: 3, status: "reauthorization_required", managed_events_pending_removal: 1 }],
      meta: { mode: "one_way_hosted_occurrences", policy: { export_allowed: exportAllowed, version: 7 },
        providers: [{ provider: "google", configured: true, qualified: true }, { provider: "microsoft", configured: true, qualified: true }]
      }
    });
    render(<SettingsPage />, "/app/you?section=calendar");

    expect(await screen.findByRole("button", { name: "Authorize the same account for cleanup" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Connect Microsoft" })).toBeDisabled();
  });

  it("keeps workspace and account tools available outside Profile", async () => {
    const user = userEvent.setup();
    render(<SettingsPage roleTools={<aside aria-label="Workspace tools">Workspace tools</aside>} />);
    await user.click(screen.getByRole("tab", { name: "Security" }));
    expect(screen.getByRole("complementary", { name: "Workspace tools" })).toBeVisible();
  });

  it("maps notification presets to supported category policy without changing delivery or custom categories", async () => {
    harness.api.notificationPreference.mockResolvedValue({
      email_enabled: true, push_enabled: false, in_app_enabled: true,
      muted_event_types: ["custom.workflow.v1"], updated_at: "2026-07-14T11:00:00Z"
    });
    const user = userEvent.setup();
    render(<SettingsPage />, "/app/you?section=notifications");
    await user.selectOptions(await screen.findByLabelText("Message notification preset"), "mentions");
    expect(screen.getByRole("checkbox", { name: "New messages" })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "Mentions and direct attention" })).toBeChecked();
    await user.click(screen.getByRole("button", { name: "Save notifications" }));
    await waitFor(() => expect(harness.api.updateNotificationPreference).toHaveBeenCalledWith({
      email_enabled: true, push_enabled: false, in_app_enabled: true,
      muted_event_types: ["message.created.v1", "custom.workflow.v1"]
    }));
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

  it("offers all three call control preferences, independently", async () => {
    const user = userEvent.setup();
    render(<SettingsPage />);
    await user.click(await screen.findByRole("tab", { name: "Accessibility" }));

    const solid = screen.getByRole("checkbox", { name: /Solid background behind controls/ });
    const contrast = screen.getByRole("checkbox", { name: /Higher contrast controls/ });
    const always = screen.getByRole("checkbox", { name: /Always show call controls/ });

    await user.click(solid);
    expect(solid).toBeChecked();
    // Independent: someone may want a solid backdrop without raising contrast.
    expect(contrast).not.toBeChecked();
    expect(always).not.toBeChecked();

    await user.click(contrast);
    expect(solid).toBeChecked();
    expect(contrast).toBeChecked();

    expect(window.localStorage.getItem("k-comms.call-controls-opaque.v1")).toBe("true");
    expect(window.localStorage.getItem("k-comms.call-controls-high-contrast.v1")).toBe("true");
  });

  it("says what stays visible whatever is chosen", async () => {
    // "Controls fade" is alarming on its own, and the thing people would
    // reasonably fear losing is the thing that never fades.
    const user = userEvent.setup();
    render(<SettingsPage />);
    await user.click(await screen.findByRole("tab", { name: "Accessibility" }));
    expect(
      screen.getByText(/Microphone, camera, screen-sharing and connection state stay visible/)
    ).toBeVisible();
  });

  it("offers Always show call controls, reachable without joining a call", async () => {
    // The preference has to be settable outside a call: someone who needs the
    // controls to stay put should not have to join one, find a menu, and
    // change it while a call is running.
    window.localStorage.removeItem("k-comms.always-show-call-controls.v1");
    const user = userEvent.setup();
    render(<SettingsPage />);

    await user.click(await screen.findByRole("tab", { name: "Accessibility" }));
    const toggle = screen.getByRole("checkbox", { name: /Always show call controls/ });
    expect(toggle).not.toBeChecked();

    await user.click(toggle);
    expect(toggle).toBeChecked();
    expect(window.localStorage.getItem("k-comms.always-show-call-controls.v1")).toBe("true");

    await user.click(toggle);
    expect(window.localStorage.getItem("k-comms.always-show-call-controls.v1")).toBe("false");
  });

  it("restores the saved control preference when the page is reopened", async () => {
    window.localStorage.setItem("k-comms.always-show-call-controls.v1", "true");
    const user = userEvent.setup();
    render(<SettingsPage />);

    await user.click(await screen.findByRole("tab", { name: "Accessibility" }));
    expect(screen.getByRole("checkbox", { name: /Always show call controls/ })).toBeChecked();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}
