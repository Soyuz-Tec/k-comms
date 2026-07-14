import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { errorText, formatDateTime, stringValue } from "../../lib/format";
import { useSession } from "../../app/session";
import type { AccountSession, Device, NotificationAttempt, NotificationIntent, NotificationPreference } from "../../types";
import { canAdministerTenant } from "../../lib/roles";
import { ConfirmDialog } from "../../components/ActionDialog";
import { PushNotifications } from "./PushNotifications";

const notificationChoices = [
  { eventType: "message.created.v1", field: "notify_messages", label: "New messages" },
  { eventType: "mention.created.v1", field: "notify_mentions", label: "Mentions and direct attention" }
] as const;

type PendingRevocation =
  | { kind: "device"; device: Device }
  | { kind: "session"; record: AccountSession };

export function SettingsPage() {
  const { api, session, setSession } = useSession();
  const [devices, setDevices] = useState<Device[]>([]);
  const [sessions, setSessions] = useState<AccountSession[]>([]);
  const [preference, setPreference] = useState<NotificationPreference | null>(null);
  const [notifications, setNotifications] = useState<NotificationIntent[]>([]);
  const [attempts, setAttempts] = useState<NotificationAttempt[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [pendingRevocation, setPendingRevocation] = useState<PendingRevocation | null>(null);
  const [revocationError, setRevocationError] = useState<string | null>(null);

  async function refreshSecurity() {
    const [nextDevices, nextSessions] = await Promise.all([api.devices(), api.sessions()]);
    setDevices(nextDevices);
    setSessions(nextSessions);
  }

  useEffect(() => {
    let current = true;
    Promise.all([api.devices(), api.sessions(), api.notificationPreference(), api.notifications(), api.notificationAttempts()])
      .then(([nextDevices, nextSessions, nextPreference, nextNotifications, nextAttempts]) => {
        if (!current) return;
        setDevices(nextDevices);
        setSessions(nextSessions);
        setPreference(nextPreference);
        setNotifications(nextNotifications);
        setAttempts(nextAttempts);
      })
      .catch((reason: unknown) => current && setError(errorText(reason)))
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

  return (
    <main className="page-shell" id="main-content">
      <header className="page-heading"><div><span className="eyebrow">Personal workspace</span><h1>Profile and settings</h1><p>Manage your identity, password, devices and active browser sessions.</p></div></header>
      {error && <div className="inline-notice error" role="alert">{error}<button type="button" aria-label="Dismiss error" onClick={() => setError(null)}>×</button></div>}
      {notice && <div className="inline-notice" role="status">{notice}<button type="button" aria-label="Dismiss notice" onClick={() => setNotice(null)}>×</button></div>}
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

      <div className="settings-grid">
        <form className="settings-card" onSubmit={(event) => void updateProfile(event)}>
          <div className="card-heading"><h2>Profile</h2><span className="status-pill success">Live API</span></div>
          <label className="field">Display name<input name="display_name" defaultValue={session.user.display_name} maxLength={120} required /></label>
          <label className="field">Email address<input type="email" value={session.user.email || ""} readOnly aria-describedby="profile-email-help" /><small id="profile-email-help">This recovery address is read-only until a separate verified email-change flow is available.</small></label>
          <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "profile"}>{busy === "profile" ? "Saving…" : "Save profile"}</button></div>
        </form>

        <form className="settings-card" onSubmit={(event) => void changePassword(event)}>
          <div className="card-heading"><h2>Password</h2><span className="status-pill success">Live API</span></div>
          <label className="field">Current password<input name="current_password" type="password" autoComplete="current-password" required /></label>
          <label className="field">New password<input name="new_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required /></label>
          <label className="field">Confirm new password<input name="confirm_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required /></label>
          <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "password"}>{busy === "password" ? "Changing…" : "Change password"}</button></div>
        </form>
      </div>

      <section className="data-card settings-data-card" aria-labelledby="devices-title">
        <div className="card-heading"><div><span className="eyebrow">Account security</span><h2 id="devices-title">Devices</h2></div><span className="status-pill success">{loading ? "Loading" : `${devices.length} known`}</span></div>
        <ul className="security-list">{devices.map((device) => <li key={device.id}><div><strong>{device.name}</strong><small>{device.platform} · Last seen {formatDateTime(device.last_seen_at)}{device.id === session.device.id ? " · This device" : ""}</small></div><span className={`status-pill ${device.revoked_at ? "neutral" : "success"}`}>{device.revoked_at ? "Revoked" : "Active"}</span>{!device.revoked_at && <button className="button danger compact" type="button" disabled={busy === `device-${device.id}`} onClick={() => { setRevocationError(null); setPendingRevocation({ kind: "device", device }); }}>{device.id === session.device.id ? "Revoke and sign out" : "Revoke device"}</button>}</li>)}</ul>
      </section>

      <section className="data-card settings-data-card" aria-labelledby="sessions-title">
        <div className="card-heading"><div><span className="eyebrow">Account security</span><h2 id="sessions-title">Sessions</h2></div><span className="status-pill success">{sessions.filter(({ revoked_at }) => !revoked_at).length} active</span></div>
        <ul className="security-list">{sessions.map((record) => <li key={record.id}><div><strong>{record.device_id === session.device.id ? "Current device session" : `Session ${record.id.slice(0, 8)}`}</strong><small>Last used {formatDateTime(record.last_used_at)} · Expires {formatDateTime(record.expires_at)}</small></div><span className={`status-pill ${record.revoked_at ? "neutral" : "success"}`}>{record.revoked_at ? "Revoked" : "Active"}</span>{!record.revoked_at && <button className="button danger compact" type="button" disabled={busy === `session-${record.id}`} onClick={() => { setRevocationError(null); setPendingRevocation({ kind: "session", record }); }}>Revoke</button>}</li>)}</ul>
      </section>

      {preference && <form className="settings-card notification-settings" onSubmit={(event) => void updateNotifications(event)}>
        <div className="card-heading"><h2>Notification preferences</h2><span className="status-pill success">Live API</span></div>
        <fieldset className="settings-fieldset"><legend>Where should K-Comms notify you?</legend><div className="toggle-grid"><label><input name="in_app_enabled" type="checkbox" defaultChecked={preference.in_app_enabled} />In K-Comms</label><label><input name="email_enabled" type="checkbox" defaultChecked={preference.email_enabled} />By email</label><label><input name="push_enabled" type="checkbox" defaultChecked={preference.push_enabled} />On registered browsers</label></div></fieldset>
        <fieldset className="settings-fieldset"><legend>What should notify you?</legend><div className="toggle-grid">{notificationChoices.map(({ eventType, field, label }) => <label key={eventType}><input name={field} type="checkbox" defaultChecked={!preference.muted_event_types.includes(eventType)} />{label}</label>)}</div></fieldset>
        <details className="advanced-settings"><summary>Advanced notification categories</summary><label className="field">Additional categories to mute<input name="additional_muted_event_types" defaultValue={preference.muted_event_types.filter((value) => !notificationChoices.some(({ eventType }) => eventType === value)).join(", ")} /><small>Only use technical category names supplied by your administrator or support team.</small></label></details>
        <div className="form-actions"><button className="button primary compact" type="submit" disabled={busy === "notifications"}>{busy === "notifications" ? "Saving…" : "Save notifications"}</button></div>
      </form>}

      {preference && <PushNotifications api={api} preference={preference} onPreference={setPreference} onNotice={setNotice} onError={setError} />}

      <section className="data-card settings-data-card" aria-labelledby="notification-history-title">
        <div className="card-heading"><div><span className="eyebrow">Delivery visibility</span><h2 id="notification-history-title">Recent notifications</h2></div><span className="status-pill success">{notifications.length} recent</span></div>
        {notifications.length === 0 ? <p className="empty-copy">No recent notification deliveries.</p> : <ul className="security-list">{notifications.slice(0, 20).map((intent) => <li key={intent.id}><div><strong>{notificationName(intent.event_type)}</strong><small>{notificationChannelName(intent.channel)} · {intent.destination_hint || "destination protected"} · {attemptSummary(intent.attempt_count)} · {formatDateTime(intent.inserted_at)}</small></div><span className={`status-pill ${intent.status === "delivered" ? "success" : "neutral"}`}>{notificationStatusName(intent.status)}</span>{canAdministerTenant(session.user.role) && ["failed", "dead_letter"].includes(intent.status) && <button className="button ghost compact" type="button" disabled={busy === `notification-${intent.id}`} onClick={() => void retryNotification(intent)}>Retry</button>}</li>)}</ul>}
        <details className="advanced-settings"><summary>Technical delivery details</summary><p className="support-note">{attempts.length} delivery {attempts.length === 1 ? "attempt is" : "attempts are"} available to your account. Destinations are redacted by the server.</p></details>
      </section>
    </main>
  );
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
