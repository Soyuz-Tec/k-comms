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
      updateProfile: vi.fn()
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
    harness.api.updateProfile.mockResolvedValue({
      ...harness.initialSession.user,
      display_name: "Updated Name"
    });
  });

  it("renders the recovery email read-only and submits only the display name", async () => {
    const user = userEvent.setup();
    render(<SettingsPage />);

    await screen.findByText("0 known");
    const email = screen.getByRole("textbox", { name: /Email address/i });
    expect(email).toHaveValue("verified@example.test");
    expect(email).toHaveAttribute("readonly");
    expect(screen.getByText(/separate verified email-change flow/i)).toBeVisible();

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

    await screen.findByText("0 known");
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

    await screen.findByText("0 known");
    await user.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(harness.api.updateProfile).toHaveBeenCalledOnce());

    harness.currentSession = null;
    pending.resolve({ ...harness.initialSession.user, display_name: "Late Update" });

    await waitFor(() => expect(harness.setSession).toHaveBeenCalledWith(expect.any(Function)));
    expect(harness.currentSession).toBeNull();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}
