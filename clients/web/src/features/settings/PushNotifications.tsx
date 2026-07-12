import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import type { NotificationPreference, PushSubscriptionConfig, PushSubscriptionInput, PushSubscriptionRecord } from "../../types";
import { errorText } from "../../lib/format";

type PushState = "loading" | "unsupported" | "unavailable" | "denied" | "ready";

export function PushNotifications({
  api,
  preference,
  onPreference,
  onNotice,
  onError
}: {
  api: ApiClient;
  preference: NotificationPreference;
  onPreference: (preference: NotificationPreference) => void;
  onNotice: (notice: string) => void;
  onError: (error: string) => void;
}) {
  const [config, setConfig] = useState<PushSubscriptionConfig | null>(null);
  const [subscriptions, setSubscriptions] = useState<PushSubscriptionRecord[]>([]);
  const [state, setState] = useState<PushState>("loading");
  const [localSubscription, setLocalSubscription] = useState<PushSubscription | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let current = true;

    if (!supportsPush()) {
      setState("unsupported");
      return () => { current = false; };
    }

    Promise.all([
      api.pushSubscriptionConfig(),
      api.pushSubscriptions(),
      navigator.serviceWorker.getRegistration("/app/")
    ])
      .then(async ([nextConfig, nextSubscriptions, registration]) => {
        const browserSubscription = registration ? await registration.pushManager.getSubscription() : null;
        if (!current) return;
        setConfig(nextConfig);
        setSubscriptions(nextSubscriptions);
        setLocalSubscription(browserSubscription);
        setState(!nextConfig.available ? "unavailable" : Notification.permission === "denied" ? "denied" : "ready");
      })
      .catch((reason: unknown) => {
        if (!current) return;
        setState("unavailable");
        onError(errorText(reason));
      });

    return () => { current = false; };
  }, [api, onError]);

  const activeSubscriptions = subscriptions.filter(({ status }) => status === "active");
  const enabledOnBrowser = state === "ready" && preference.push_enabled && activeSubscriptions.length > 0 && Boolean(localSubscription);

  async function enable() {
    if (!config?.available || !config.vapid_public_key || !supportsPush()) return;
    setBusy(true);
    onError("");

    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState("denied");
        onNotice("Browser notification permission was not granted. No push subscription was created.");
        return;
      }

      const registration = await navigator.serviceWorker.register("/app/k-comms-sw.js", {
        scope: "/app/",
        type: "module"
      });

      let browserSubscription = await registration.pushManager.getSubscription();
      if (!browserSubscription) {
        browserSubscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: decodeBase64Url(config.vapid_public_key)
        });
      }

      for (const existing of activeSubscriptions) await api.revokePushSubscription(existing.id);
      const registered = await api.registerPushSubscription(toInput(browserSubscription));

      if (!preference.push_enabled) {
        const nextPreference = await api.updateNotificationPreference({
          email_enabled: preference.email_enabled,
          push_enabled: true,
          in_app_enabled: preference.in_app_enabled,
          muted_event_types: preference.muted_event_types
        });
        onPreference(nextPreference);
      }

      setSubscriptions([registered.data]);
      setLocalSubscription(browserSubscription);
      setState("ready");
      onNotice("Push notifications are enabled on this browser.");
    } catch (reason: unknown) {
      onError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  async function disable() {
    setBusy(true);
    onError("");

    try {
      for (const subscription of activeSubscriptions) await api.revokePushSubscription(subscription.id);
      if (localSubscription) await localSubscription.unsubscribe();
      setSubscriptions((current) => current.map((value) => value.status === "active" ? { ...value, status: "revoked" } : value));
      setLocalSubscription(null);
      onNotice("Push notifications are disabled on this browser.");
    } catch (reason: unknown) {
      onError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="settings-card push-settings" aria-labelledby="browser-push-title">
      <div className="card-heading">
        <div><span className="eyebrow">This device</span><h2 id="browser-push-title">Browser push</h2></div>
        <span className={`status-pill ${enabledOnBrowser ? "success" : "neutral"}`}>
          {state === "loading" ? "Checking" : enabledOnBrowser ? "Enabled" : "Off"}
        </span>
      </div>

      {state === "unsupported" && <p>This browser does not support service-worker push notifications.</p>}
      {state === "unavailable" && <p>Push registration is unavailable because the server-side Web Push configuration is incomplete.</p>}
      {state === "denied" && <p>Notifications are blocked by this browser. Allow notifications in site settings before trying again.</p>}
      {state === "ready" && <p>{enabledOnBrowser ? `Registered through ${activeSubscriptions[0]?.endpoint_hint || "your push provider"}.` : activeSubscriptions.length > 0 && localSubscription && !preference.push_enabled ? "This browser is registered, but your global push preference is off. Select Enable to turn delivery on." : "Enable push explicitly for this browser. Permission is requested only after you select Enable."}</p>}

      <div className="form-actions">
        {enabledOnBrowser ? (
          <button className="button danger compact" type="button" disabled={busy} onClick={() => void disable()}>
            {busy ? "Disabling…" : "Disable on this browser"}
          </button>
        ) : (
          <button className="button primary compact" type="button" disabled={busy || state !== "ready"} onClick={() => void enable()}>
            {busy ? "Enabling…" : "Enable on this browser"}
          </button>
        )}
      </div>
    </section>
  );
}

function supportsPush(): boolean {
  return typeof window !== "undefined" && typeof navigator.serviceWorker?.register === "function" && typeof window.PushManager !== "undefined" && typeof window.Notification !== "undefined" && typeof window.Notification.requestPermission === "function";
}

function toInput(subscription: PushSubscription): PushSubscriptionInput {
  const json = subscription.toJSON();
  const endpoint = json.endpoint;
  const p256dh = json.keys?.p256dh;
  const auth = json.keys?.auth;

  if (!endpoint || !p256dh || !auth) throw new Error("The browser returned an incomplete push subscription.");

  return {
    endpoint,
    expiration_time: subscription.expirationTime,
    keys: { p256dh, auth }
  };
}

function decodeBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const decoded = window.atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
  const bytes = new Uint8Array(new ArrayBuffer(decoded.length));
  for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index);
  return bytes;
}
