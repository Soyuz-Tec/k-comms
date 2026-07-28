import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { NotificationPreference, PushSubscriptionRecord } from "../../types";
import { resetPwaRegistrationForTests } from "../../pwa/registration";
import { PushNotifications } from "./PushNotifications";

const preference: NotificationPreference = {
  email_enabled: true,
  push_enabled: false,
  in_app_enabled: true,
  muted_event_types: [],
  updated_at: "2026-07-12T10:00:00Z"
};

afterEach(() => {
  resetPwaRegistrationForTests();
  vi.unstubAllGlobals();
  Reflect.deleteProperty(navigator, "serviceWorker");
});

describe("browser push settings", () => {
  it("reuses the eagerly registered PWA worker without prompting automatically", async () => {
    const requestPermission = vi.fn().mockResolvedValue("granted");
    const browserSubscription = fakeBrowserSubscription();
    const subscribe = vi.fn().mockResolvedValue(browserSubscription);
    const registration = { pushManager: { getSubscription: vi.fn().mockResolvedValue(null), subscribe } };
    const register = vi.fn().mockResolvedValue(registration);
    installPushBrowser({ permission: "default", requestPermission, register, getRegistration: vi.fn().mockResolvedValue(undefined) });

    const record = subscriptionRecord();
    const api = pushApi({ registerPushSubscription: vi.fn().mockResolvedValue({ data: record, replayed: false }) });
    renderPush(api);

    await screen.findByRole("button", { name: "Enable on this browser" });
    expect(requestPermission).not.toHaveBeenCalled();
    expect(register).toHaveBeenCalledTimes(1);
    expect(register).toHaveBeenCalledWith(
      "/app/k-comms-sw.js?revision=development",
      {
        scope: "/app/",
        type: "module",
        updateViaCache: "none"
      }
    );

    await userEvent.click(screen.getByRole("button", { name: "Enable on this browser" }));

    await waitFor(() => expect(requestPermission).toHaveBeenCalledTimes(1));
    expect(register).toHaveBeenCalledTimes(1);
    expect(subscribe).toHaveBeenCalledWith(expect.objectContaining({ userVisibleOnly: true }));
    expect(api.registerPushSubscription).toHaveBeenCalledWith(expect.objectContaining({ endpoint: "https://push.example.test/send/browser" }));
  });

  it("does not create a push subscription after permission denial", async () => {
    const requestPermission = vi.fn().mockResolvedValue("denied");
    const registration = {
      pushManager: { getSubscription: vi.fn().mockResolvedValue(null) }
    };
    const register = vi.fn().mockResolvedValue(registration);
    installPushBrowser({ permission: "default", requestPermission, register, getRegistration: vi.fn().mockResolvedValue(undefined) });
    const api = pushApi();
    renderPush(api);

    await userEvent.click(await screen.findByRole("button", { name: "Enable on this browser" }));

    await screen.findByText(/blocked by this browser/i);
    expect(register).toHaveBeenCalledTimes(1);
    expect(api.registerPushSubscription).not.toHaveBeenCalled();
  });

  it("does not consume notification permission when worker registration fails", async () => {
    const requestPermission = vi.fn().mockResolvedValue("granted");
    const registration = {
      pushManager: { getSubscription: vi.fn().mockResolvedValue(null) }
    };
    const register = vi
      .fn()
      .mockRejectedValueOnce(new Error("service worker unavailable"))
      .mockResolvedValue(registration);
    installPushBrowser({
      permission: "default",
      requestPermission,
      register,
      getRegistration: vi.fn().mockResolvedValue(undefined)
    });
    const api = pushApi();
    renderPush(api);

    expect(
      await screen.findByText(/could not register the service worker/i)
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Enable on this browser" })
    ).toBeDisabled();
    expect(requestPermission).not.toHaveBeenCalled();
    expect(api.registerPushSubscription).not.toHaveBeenCalled();

    window.dispatchEvent(new Event("online"));

    await waitFor(() => expect(register).toHaveBeenCalledTimes(2));
    expect(
      await screen.findByRole("button", { name: "Enable on this browser" })
    ).toBeEnabled();
    expect(requestPermission).not.toHaveBeenCalled();
  });

  it("shows unsupported UX without calling the server", () => {
    vi.stubGlobal("PushManager", undefined);
    const api = pushApi();
    renderPush(api);

    expect(screen.getByText(/does not support service-worker push/i)).toBeInTheDocument();
    expect(api.pushSubscriptionConfig).not.toHaveBeenCalled();
  });
});

function renderPush(api: ApiClient) {
  return render(
    <PushNotifications
      api={api}
      preference={preference}
      onPreference={vi.fn()}
      onNotice={vi.fn()}
      onError={vi.fn()}
    />
  );
}

function pushApi(overrides: Record<string, unknown> = {}): ApiClient {
  return {
    pushSubscriptionConfig: vi.fn().mockResolvedValue({ available: true, vapid_public_key: "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo" }),
    pushSubscriptions: vi.fn().mockResolvedValue([]),
    registerPushSubscription: vi.fn(),
    revokePushSubscription: vi.fn(),
    updateNotificationPreference: vi.fn().mockResolvedValue({ ...preference, push_enabled: true }),
    ...overrides
  } as unknown as ApiClient;
}

function installPushBrowser({ permission, requestPermission, register, getRegistration }: {
  permission: NotificationPermission;
  requestPermission: ReturnType<typeof vi.fn>;
  register: ReturnType<typeof vi.fn>;
  getRegistration: ReturnType<typeof vi.fn>;
}) {
  vi.stubGlobal("PushManager", class PushManager {});
  vi.stubGlobal("Notification", { permission, requestPermission });
  Object.defineProperty(navigator, "serviceWorker", {
    configurable: true,
    value: { register, getRegistration }
  });
}

function fakeBrowserSubscription(): PushSubscription {
  return {
    expirationTime: null,
    toJSON: () => ({
      endpoint: "https://push.example.test/send/browser",
      expirationTime: null,
      keys: {
        p256dh: "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo",
        auth: "AAECAwQFBgcICQoLDA0ODw"
      }
    }),
    unsubscribe: vi.fn().mockResolvedValue(true)
  } as unknown as PushSubscription;
}

function subscriptionRecord(): PushSubscriptionRecord {
  return {
    id: "subscription-1",
    device_id: "device-1",
    endpoint_hint: "push.example.test",
    status: "active",
    inserted_at: "2026-07-12T10:00:00Z",
    updated_at: "2026-07-12T10:00:00Z"
  };
}
