import { useEffect, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import { errorText, formatDateTime, stringValue } from "../../lib/format";
import { useSession } from "../../app/session";
import type { AccountSession, Device, NotificationAttempt, NotificationIntent, NotificationPreference } from "../../types";
import { canAdministerTenant } from "../../lib/roles";
import { ConfirmDialog } from "../../components/ActionDialog";
import { AppIcon } from "../../components/AppIcon";
import { PushNotifications } from "./PushNotifications";
import { usePwa, type PwaInstallMode } from "../../pwa/PwaProvider";
import {
  PwaInstallHelpDialog,
  type ManualInstallMode
} from "../../pwa/PwaInstallHelpDialog";
type SettingsSection = "profile" | "security" | "notifications";

const settingsSections: SettingsSection[] = ["profile", "security", "notifications"];

const notificationChoices = [
  { eventType: "message.created.v1", field: "notify_messages", label: "New messages" },
  { eventType: "mention.created.v1", field: "notify_mentions", label: "Mentions and direct attention" }
] as const;

type PendingRevocation =
  | { kind: "device"; device: Device }
  | { kind: "session"; record: AccountSession };

interface ResourceLoadFailure {
  resource: string;
  message: string;
}

export function SettingsPage({ roleTools }: { roleTools?: ReactNode } = {}) {
  const { api, session, setSession } = useSession();
  const { installMode, requestInstall } = usePwa();
  const [devices, setDevices] = useState<Device[]>([]);
  const [sessions, setSessions] = useState<AccountSession[]>([]);
  const [preference, setPreference] = useState<NotificationPreference | null>(null);
  const [notifications, setNotifications] = useState<NotificationIntent[]>([]);
  const [attempts, setAttempts] = useState<NotificationAttempt[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadFailures, setLoadFailures] = useState<ResourceLoadFailure[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [pendingRevocation, setPendingRevocation] = useState<PendingRevocation | null>(null);
  const [revocationError, setRevocationError] = useState<string | null>(null);
  const [installHelpMode, setInstallHelpMode] = useState<ManualInstallMode | null>(null);
  const [section, setSection] = useState<SettingsSection>("profile");

  async function refreshSecurity() {
    const [deviceResult, sessionResult] = await Promise.allSettled([
      api.devices(),
      api.sessions()
    ]);
    const failures: ResourceLoadFailure[] = [];
    if (deviceResult.status === "fulfilled") {
      setDevices(deviceResult.value);
    } else {
      failures.push({ resource: "Devices", message: errorText(deviceResult.reason) });
    }
    if (sessionResult.status === "fulfilled") {
      setSessions(sessionResult.value);
    } else {
      failures.push({ resource: "Sessions", message: errorText(sessionResult.reason) });
    }
    setLoadFailures((current) => [
      ...current.filter(({ resource }) => resource !== "Devices" && resource !== "Sessions"),
      ...failures
    ]);
  }

  useEffect(() => {
    let current = true;
    setLoading(true);
    setLoadFailures([]);

    function loadResource<T>(
      resource: string,
      request: Promise<T>,
      apply: (value: T) => void
    ): Promise<void> {
      return request
        .then((value) => {
          if (current) apply(value);
        })
        .catch((reason: unknown) => {
          if (!current) return;
          setLoadFailures((failures) => [
            ...failures.filter((failure) => failure.resource !== resource),
            { resource, message: errorText(reason) }
          ]);
        });
    }

    Promise.allSettled([
      loadResource("Devices", api.devices(), setDevices),
      loadResource("Sessions", api.sessions(), setSessions),
      loadResource("Notification preferences", api.notificationPreference(), setPreference),
      loadResource("Recent notifications", api.notifications(), setNotifications),
      loadResource("Notification delivery details", api.notificationAttempts(), setAttempts)
    ])
      .finally(() => current && setLoading(false));
    return () => { current = false; };
  }, [api]);

  if (!session) return null;
  const currentSession = session;

  async function updateProfile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    setBusy("profile");
    setError(null);
    try {
      const user = await api.updateProfile({ display_name: stringValue(values, "display_name") });
      setSession((latest) => {
        if (!latest) return null;

        const sameIdentity =
          latest.tenant.id === currentSession.tenant.id &&
          latest.user.id === currentSession.user.id;

        return sameIdentity ? { ...latest, user } : latest;
      });
      setNotice("Profile updated.");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function changePassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    const newPassword = stringValue(values, "new_password");
    if (newPassword !== stringValue(values, "confirm_password")) return setError("New password confirmation does not match.");
    setBusy("password");
    setError(null);
    try {
      await api.changePassword({ current_password: stringValue(values, "current_password"), new_password: newPassword });
      form.reset();
      setNotice("Password changed. Other sessions were revoked.");
      await refreshSecurity();
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function confirmRevocation() {
    if (!pendingRevocation) return;
    const busyKey = pendingRevocation.kind === "device"
      ? `device-${pendingRevocation.device.id}`
      : `session-${pendingRevocation.record.id}`;
    setBusy(busyKey);
    setError(null);
    setRevocationError(null);
    try {
      if (pendingRevocation.kind === "device") {
        await api.revokeDevice(pendingRevocation.device.id);
        if (pendingRevocation.device.id === currentSession.device.id) setSession(null); else await refreshSecurity();
      } else {
        await api.revokeSession(pendingRevocation.record.id);
        if (pendingRevocation.record.device_id === currentSession.device.id && !pendingRevocation.record.revoked_at) setSession(null); else await refreshSecurity();
      }
      setPendingRevocation(null);
    } catch (reason: unknown) {
      setRevocationError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  function closeRevocationDialog() {
    if (busy) return;
    setPendingRevocation(null);
    setRevocationError(null);
  }

  async function updateNotifications(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    const mutedKnownTypes = notificationChoices
      .filter(({ field }) => values.get(field) !== "on")
      .map(({ eventType }) => eventType);
    const additionalMutedTypes = stringValue(values, "additional_muted_event_types")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    setBusy("notifications");
    setError(null);
    try {
      const next = await api.updateNotificationPreference({
        email_enabled: values.get("email_enabled") === "on",
        push_enabled: values.get("push_enabled") === "on",
        in_app_enabled: values.get("in_app_enabled") === "on",
        muted_event_types: [...new Set([...mutedKnownTypes, ...additionalMutedTypes])]
      });
      setPreference(next);
      setNotice("Notification preferences updated.");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function retryNotification(intent: NotificationIntent) {
    setBusy(`notification-${intent.id}`);
    try {
      const next = await api.retryNotification(intent.id);
      setNotifications((current) => current.map((value) => value.id === next.id ? next : value));
      setNotice("Notification retry queued.");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(null);
    }
  }

  async function installKComms() {
    if (installMode === "manual-ios" || installMode === "manual-browser") {
      setInstallHelpMode(installMode);
      return;
    }
    if (installMode !== "native-prompt") return;
    const result = await requestInstall();
    if (result === "manual-ios" || result === "manual-browser") {
      setInstallHelpMode(result);
    }
  }

  function moveSettingsTab(key: string) {
    const currentIndex = settingsSections.indexOf(section);
    const nextIndex = key === "Home"
      ? 0
      : key === "End"
        ? settingsSections.length - 1
        : key === "ArrowLeft"
          ? (currentIndex - 1 + settingsSections.length) % settingsSections.length
          : key === "ArrowRight"
            ? (currentIndex + 1) % settingsSections.length
            : currentIndex;
    if (nextIndex === currentIndex && key !== "Home" && key !== "End") return;
    const nextSection = settingsSections[nextIndex];
    if (!nextSection) return;
    setSection(nextSection);
    document.getElementById(`settings-${nextSection}-tab`)?.focus();
  }

  return (
    <main className="page-shell settings-page" id="main-content">
      <header className="page-heading settings-page-heading"><div><h1>You</h1></div></header>
      <nav className="settings-section-tabs" aria-label="Profile and settings sections" role="tablist">
        {settingsSections.map((value) => (
          <button
            key={value}
            id={`settings-${value}-tab`}
            type="button"
            role="tab"
            aria-selected={section === value}
            aria-controls={`settings-${value}-panel`}
            tabIndex={section === value ? 0 : -1}
            onClick={() => setSection(value)}
            onKeyDown={(event) => {
              if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
                event.preventDefault();
                moveSettingsTab(event.key);
              }
            }}
          >
            {value === "profile" ? "Profile" : value === "security" ? "Security" : "Notifications"}
          </button>
        ))}
      </nav>
      {error && <div className="inline-notice error" role="alert">{error}<button type="button" aria-label="Dismiss error" onClick={() => setError(null)}><AppIcon name="x" /></button></div>}
      {notice && <div className="inline-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}><AppIcon name="x" /></button></div>}
      {loadFailures.length > 0 && (
        <div className="inline-notice settings-load-warning" role="status">
          <div>
            <strong>Some settings could not be loaded.</strong>
            <ul>
              {loadFailures.map(({ resource, message }) => (
                <li key={resource}><strong>{resource}:</strong> {message}</li>
              ))}
            </ul>
          </div>
          <button type="button" aria-label="Dismiss settings load warning" onClick={() => setLoadFailures([])}><AppIcon name="x" /></button>
        </div>
      )}
      {pendingRevocation && <ConfirmDialog
        title={pendingRevocation.kind === "device" ? "Revoke device?" : "Revoke session?"}
        description={pendingRevocation.kind === "device" ? pendingRevocation.device.name : `Session ${pendingRevocation.record.id.slice(0, 8)}`}
        impact={pendingRevocation.kind === "device"
          ? pendingRevocation.device.id === currentSession.device.id ? "This device will be revoked and you will be signed out now." : "All active sessions on this device will stop working."
          : pendingRevocation.record.device_id === currentSession.device.id ? "This browser session will end and you will be signed out now." : "The session will stop working and its user must sign in again."}
        confirmLabel={pendingRevocation.kind === "device" ? "Revoke device" : "Revoke session"}
        tone="danger"
        busy={busy !== null}
        error={revocationError}
        onCancel={closeRevocationDialog}
        onConfirm={() => void confirmRevocation()}
      />}
      {installHelpMode && (
        <PwaInstallHelpDialog
          mode={installHelpMode}
          onClose={() => setInstallHelpMode(null)}
        />
      )}

      {section === "profile" && roleTools}

      {section === "profile" && <section id="settings-profile-panel" role="tabpanel" aria-labelledby="settings-profile-tab">
        <form className="settings-card" id="profile-settings" onSubmit={(event) => void updateProfile(event)}>
          <div className="card-heading"><h2>Profile</h2></div>
          <label className="field">Display name<input name="display_name" defaultValue={session.user.display_name} maxLength={120} required /></label>
          <label className="field">Email address<input type="email" value={session.user.email || ""} readOnly aria-describedby="profile-email-help" /><small id="profile-email-help">Verified account email</small></label>
          <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "profile"}>{busy === "profile" ? "Saving…" : "Save profile"}</button></div>
        </form>
      </section>}

      {section === "security" && <section id="settings-security-panel" role="tabpanel" aria-labelledby="settings-security-tab">
        <form className="settings-card" id="password-settings" onSubmit={(event) => void changePassword(event)}>
          <div className="card-heading"><h2>Password</h2></div>
          <label className="field">Current password<input name="current_password" type="password" autoComplete="current-password" required /></label>
          <label className="field">New password<input name="new_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required /></label>
          <label className="field">Confirm new password<input name="confirm_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required /></label>
          <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "password"}>{busy === "password" ? "Changing…" : "Change password"}</button></div>
        </form>
      </section>}

      {section === "profile" && installMode !== "unavailable" && (
        <section
          className="settings-card pwa-install-card"
          id="install-settings"
          aria-labelledby="install-settings-title"
        >
          <div className="card-heading">
            <h2 id="install-settings-title">Install K-Comms</h2>
            <span className={`status-pill ${installMode === "installed" ? "success" : "neutral"}`}>
              {installMode === "installed" ? "Installed" : "Available"}
            </span>
          </div>
          {installMode !== "installed" && <p>{installDescription(installMode)}</p>}
          {installMode !== "installed" && (
            <div className="form-actions">
              <button
                className="button primary"
                type="button"
                onClick={() => void installKComms()}
              >
                {installMode === "native-prompt" ? "Install K-Comms" : "Show install steps"}
              </button>
            </div>
          )}
        </section>
      )}

      {section === "security" && <section className="settings-security-inventories" aria-label="Account security">
        <details className="data-card settings-data-card settings-disclosure" id="device-settings">
          <summary><h2>Devices</h2><span className="status-pill success">{loading ? "Loading" : `${devices.length} known`}</span></summary>
          <ul className="security-list">{devices.map((device) => <li key={device.id}><div><strong>{device.name}</strong><small>{device.platform} · Last seen {formatDateTime(device.last_seen_at)}{device.id === session.device.id ? " · This device" : ""}</small></div><span className={`status-pill ${device.revoked_at ? "neutral" : "success"}`}>{device.revoked_at ? "Revoked" : "Active"}</span>{!device.revoked_at && <button className="button danger compact" type="button" disabled={busy === `device-${device.id}`} onClick={() => { setRevocationError(null); setPendingRevocation({ kind: "device", device }); }}>{device.id === session.device.id ? "Revoke and sign out" : "Revoke device"}</button>}</li>)}</ul>
        </details>

        <details className="data-card settings-data-card settings-disclosure" id="session-settings">
          <summary><h2>Sessions</h2><span className="status-pill success">{sessions.filter(({ revoked_at }) => !revoked_at).length} active</span></summary>
          <ul className="security-list">{sessions.map((record) => <li key={record.id}><div><strong>{record.device_id === session.device.id ? "Current device session" : `Session ${record.id.slice(0, 8)}`}</strong><small>Last used {formatDateTime(record.last_used_at)} · Expires {formatDateTime(record.expires_at)}</small></div><span className={`status-pill ${record.revoked_at ? "neutral" : "success"}`}>{record.revoked_at ? "Revoked" : "Active"}</span>{!record.revoked_at && <button className="button danger compact" type="button" disabled={busy === `session-${record.id}`} onClick={() => { setRevocationError(null); setPendingRevocation({ kind: "session", record }); }}>Revoke</button>}</li>)}</ul>
        </details>
      </section>}

      {section === "notifications" && <section id="settings-notifications-panel" role="tabpanel" aria-labelledby="settings-notifications-tab">
      {preference && <form className="settings-card notification-settings" id="notification-settings" onSubmit={(event) => void updateNotifications(event)}>
        <div className="card-heading"><h2>Notification preferences</h2></div>
        <fieldset className="settings-fieldset"><legend>Where should K-Comms notify you?</legend><div className="toggle-grid"><label><input name="in_app_enabled" type="checkbox" defaultChecked={preference.in_app_enabled} />In K-Comms</label><label><input name="email_enabled" type="checkbox" defaultChecked={preference.email_enabled} />By email</label><label><input name="push_enabled" type="checkbox" defaultChecked={preference.push_enabled} />On registered browsers</label></div></fieldset>
        <fieldset className="settings-fieldset"><legend>What should notify you?</legend><div className="toggle-grid">{notificationChoices.map(({ eventType, field, label }) => <label key={eventType}><input name={field} type="checkbox" defaultChecked={!preference.muted_event_types.includes(eventType)} />{label}</label>)}</div></fieldset>
        <details className="advanced-settings"><summary>Advanced notification categories</summary><label className="field">Additional categories to mute<input name="additional_muted_event_types" defaultValue={preference.muted_event_types.filter((value) => !notificationChoices.some(({ eventType }) => eventType === value)).join(", ")} /><small>Only use technical category names supplied by your administrator or support team.</small></label></details>
        <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "notifications"}>{busy === "notifications" ? "Saving…" : "Save notifications"}</button></div>
      </form>}

      {preference && <PushNotifications api={api} preference={preference} onPreference={setPreference} onNotice={setNotice} onError={setError} />}

      <details className="data-card settings-data-card settings-disclosure" id="notification-history">
        <summary><h2>Recent notifications</h2><span className="status-pill success">{notifications.length} recent</span></summary>
        {notifications.length === 0 ? <p className="empty-copy">No recent notification deliveries.</p> : <ul className="security-list">{notifications.slice(0, 20).map((intent) => <li key={intent.id}><div><strong>{notificationName(intent.event_type)}</strong><small>{notificationChannelName(intent.channel)} · {intent.destination_hint || "destination protected"} · {attemptSummary(intent.attempt_count)} · {formatDateTime(intent.inserted_at)}</small></div><span className={`status-pill ${intent.status === "delivered" ? "success" : "neutral"}`}>{notificationStatusName(intent.status)}</span>{canAdministerTenant(session.user.role) && ["failed", "dead_letter"].includes(intent.status) && <button className="button ghost compact" type="button" disabled={busy === `notification-${intent.id}`} onClick={() => void retryNotification(intent)}>Retry</button>}</li>)}</ul>}
        <details className="advanced-settings"><summary>Technical delivery details</summary><p className="support-note">{attempts.length} delivery {attempts.length === 1 ? "attempt is" : "attempts are"} available to your account. Destinations are redacted by the server.</p></details>
      </details>
      </section>}
    </main>
  );
}

function installDescription(installMode: PwaInstallMode): string {
  if (installMode === "installed") {
    return "K-Comms is installed on this device and can be opened from your home screen or app launcher.";
  }
  if (installMode === "manual-ios") {
    return "Add K-Comms to your iPhone or iPad Home Screen so it opens like an app.";
  }
  if (installMode === "manual-browser") {
    return "Add K-Comms from your browser menu for app-like access from this device.";
  }
  return "Install K-Comms on this device for quick access from your home screen or app launcher.";
}

function notificationName(eventType: string): string {
  if (eventType === "message.created.v1") return "New message";
  if (eventType === "mention.created.v1") return "You were mentioned";
  return "Workspace update";
}

function notificationChannelName(channel: string): string {
  if (channel === "in_app") return "In K-Comms";
  if (channel === "email") return "Email";
  if (channel === "push") return "Browser notification";
  return "Notification";
}

function notificationStatusName(status: string): string {
  if (status === "delivered") return "Delivered";
  if (status === "failed" || status === "dead_letter") return "Needs attention";
  if (status === "pending" || status === "queued") return "Pending";
  return status.replaceAll("_", " ");
}

function attemptSummary(count: number): string {
  if (count === 0) return "Not attempted yet";
  return `${count} delivery ${count === 1 ? "attempt" : "attempts"}`;
}
