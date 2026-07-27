import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiClient, loadStoredSession, storeSession } from "../api";
import type { ServiceStatus, Session } from "../types";
import { SessionProvider, useSession } from "./session";

const session: Session = {
  access_token: "member-access",
  refresh_token: "member-refresh",
  token_type: "Bearer",
  expires_in: 900,
  tenant: {
    id: "tenant-1",
    name: "Acme",
    slug: "acme",
    status: "active"
  },
  user: {
    id: "user-1",
    tenant_id: "tenant-1",
    display_name: "Taylor",
    email: "taylor@example.test",
    account_type: "human",
    role: "member",
    status: "active"
  },
  device: {
    id: "device-1",
    user_id: "user-1",
    name: "Browser",
    platform: "web",
    last_seen_at: "2026-07-25T00:00:00Z"
  }
};

function serviceStatus(
  secureAccountActions: boolean,
  secureMediaActions = secureAccountActions
): ServiceStatus {
  return {
    service: "k-comms",
    version: "test",
    status: "operational",
    capabilities: {
      administration: true,
      audio_calls: true,
      video_calls: true,
      attachment_scanning: true,
      bootstrap: false,
      guest_links: true,
      instant_rooms: true,
      notifications: true,
      push_notifications: true,
      realtime: true,
      secure_account_actions: secureAccountActions,
      secure_media_actions: secureMediaActions,
      webhooks: true
    }
  };
}

function PolicyProbe() {
  const {
    session: currentSession,
    setSession,
    transportPolicyReady,
    accountActionsAllowed,
    mediaActionsAllowed
  } = useSession();

  return (
    <main>
      <output aria-label="Policy ready">{String(transportPolicyReady)}</output>
      <output aria-label="Account actions">{String(accountActionsAllowed)}</output>
      <output aria-label="Media actions">{String(mediaActionsAllowed)}</output>
      <output aria-label="Member session">
        {currentSession?.user.id || "none"}
      </output>
      <button type="button" onClick={() => setSession(session)}>
        Store member session
      </button>
    </main>
  );
}

describe("SessionProvider transport policy", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    vi.restoreAllMocks();
  });

  afterEach(() => vi.useRealTimers());

  it("does not expose or replace retained member credentials while policy is unresolved", async () => {
    let resolveStatus: ((status: ServiceStatus) => void) | undefined;
    vi.spyOn(ApiClient.prototype, "status").mockReturnValue(
      new Promise((resolve) => {
        resolveStatus = resolve;
      })
    );
    storeSession(session);
    const user = userEvent.setup();

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("false");
    expect(screen.getByLabelText("Account actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Media actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("none");

    await user.click(
      screen.getByRole("button", { name: "Store member session" })
    );
    expect(loadStoredSession()).toEqual(session);

    await act(async () => {
      resolveStatus?.(serviceStatus(true));
    });

    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("true");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("user-1");
  });

  it("restores a retained localhost development session after the server allows it", async () => {
    vi.spyOn(ApiClient.prototype, "status").mockResolvedValue(
      serviceStatus(true)
    );
    storeSession(session);

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    expect(screen.getByLabelText("Member session")).toHaveTextContent("none");
    expect(
      await screen.findByText("user-1", {
        selector: "output[aria-label='Member session']"
      })
    ).toBeVisible();
    expect(screen.getByLabelText("Account actions")).toHaveTextContent("true");
    expect(screen.getByLabelText("Media actions")).toHaveTextContent("true");
    expect(loadStoredSession()).toEqual(session);
  });

  it("clears a retained session when a LAN-configured loopback response denies secure actions", async () => {
    vi.spyOn(ApiClient.prototype, "status").mockResolvedValue(
      serviceStatus(false)
    );
    storeSession(session);

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    await waitFor(() =>
      expect(screen.getByLabelText("Policy ready")).toHaveTextContent("true")
    );
    expect(screen.getByLabelText("Account actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Media actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("none");
    expect(loadStoredSession()).toBeNull();
  });

  it("preserves hidden credentials and recovers after a transient status failure", async () => {
    vi.useFakeTimers();
    const status = vi.spyOn(ApiClient.prototype, "status")
      .mockRejectedValueOnce(new Error("status unavailable"))
      .mockResolvedValue(serviceStatus(true));
    storeSession(session);

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    await act(async () => {
      await Promise.resolve();
    });
    expect(status).toHaveBeenCalledTimes(1);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("false");
    expect(screen.getByLabelText("Account actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Media actions")).toHaveTextContent("false");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("none");
    expect(loadStoredSession()).toEqual(session);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000);
    });

    expect(status).toHaveBeenCalledTimes(2);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("true");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("user-1");
    expect(loadStoredSession()).toEqual(session);
  });

  it("recovers on a capped recurring retry after a long status outage", async () => {
    vi.useFakeTimers();
    const status = vi.spyOn(ApiClient.prototype, "status")
      .mockRejectedValueOnce(new Error("initial status unavailable"))
      .mockRejectedValueOnce(new Error("first retry unavailable"))
      .mockRejectedValueOnce(new Error("second retry unavailable"))
      .mockRejectedValueOnce(new Error("third retry unavailable"))
      .mockResolvedValue(serviceStatus(true));
    storeSession(session);

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    await act(async () => {
      await Promise.resolve();
      await vi.advanceTimersByTimeAsync(1_000);
      await vi.advanceTimersByTimeAsync(3_000);
      await vi.advanceTimersByTimeAsync(10_000);
    });

    expect(status).toHaveBeenCalledTimes(4);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("false");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("none");
    expect(loadStoredSession()).toEqual(session);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(29_999);
    });
    expect(status).toHaveBeenCalledTimes(4);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });

    expect(status).toHaveBeenCalledTimes(5);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("true");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("user-1");
    expect(loadStoredSession()).toEqual(session);
  });

  it("retries immediately when the browser comes back online", async () => {
    vi.useFakeTimers();
    const status = vi.spyOn(ApiClient.prototype, "status")
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValue(serviceStatus(true));
    storeSession(session);

    render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    await act(async () => {
      await Promise.resolve();
    });
    expect(status).toHaveBeenCalledTimes(1);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("false");
    expect(loadStoredSession()).toEqual(session);

    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await Promise.resolve();
    });

    expect(status).toHaveBeenCalledTimes(2);
    expect(screen.getByLabelText("Policy ready")).toHaveTextContent("true");
    expect(screen.getByLabelText("Member session")).toHaveTextContent("user-1");
  });

  it("cleans up retry timers and the online listener when unmounted", async () => {
    vi.useFakeTimers();
    const status = vi.spyOn(ApiClient.prototype, "status").mockRejectedValue(
      new Error("offline")
    );
    const view = render(
      <SessionProvider>
        <PolicyProbe />
      </SessionProvider>
    );

    await act(async () => {
      await Promise.resolve();
    });
    expect(status).toHaveBeenCalledTimes(1);

    view.unmount();
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await vi.advanceTimersByTimeAsync(60_000);
    });

    expect(status).toHaveBeenCalledTimes(1);
  });
});
