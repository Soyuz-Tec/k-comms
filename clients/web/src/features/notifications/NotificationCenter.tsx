import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { AppIcon } from "../../components/AppIcon";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText, formatTime } from "../../lib/format";
import type { InAppNotification } from "../../types";

export function NotificationCenter() {
  const { api, session } = useSession();
  const [open, setOpen] = useState(false);
  const [notifications, setNotifications] = useState<InAppNotification[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const navigate = useNavigate();

  const load = useCallback(async () => {
    if (!session) return;
    setLoading(true);
    try {
      const page = await api.inAppNotifications();
      setNotifications(page.data);
      setUnreadCount(page.meta.unread_count);
      setError(null);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setLoading(false);
    }
  }, [api, session?.user.id]);

  useEffect(() => {
    void load();
    const refresh = () => void load();
    const timer = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    window.addEventListener("k-comms:notification-available", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      window.removeEventListener("k-comms:notification-available", refresh);
    };
  }, [load]);

  if (!session) return null;

  return (
    <div className="notification-center">
      <button
        className="notification-trigger"
        type="button"
        aria-label={`Notifications${unreadCount > 0 ? `, ${unreadCount} unread` : ""}`}
        aria-expanded={open}
        onClick={() => setOpen((visible) => !visible)}
      >
        <AppIcon name="bell" />
        {unreadCount > 0 && <span className="notification-badge">{unreadCount > 99 ? "99+" : unreadCount}</span>}
      </button>
      {open && createPortal(
        <NotificationPanel
          notifications={notifications}
          unreadCount={unreadCount}
          loading={loading}
          error={error}
          onClose={() => setOpen(false)}
          onRead={async (notification) => {
            if (!notification.read_at) {
              const updated = await api.markInAppNotificationRead(notification.id);
              setNotifications((current) => current.map((item) => item.id === updated.id ? updated : item));
              setUnreadCount((current) => Math.max(0, current - 1));
            }
            setOpen(false);
            navigate(notificationDestination(notification));
          }}
          onDismiss={async (notification) => {
            await api.dismissInAppNotification(notification.id);
            setNotifications((current) => current.filter((item) => item.id !== notification.id));
            if (!notification.read_at) setUnreadCount((current) => Math.max(0, current - 1));
          }}
          onReadAll={async () => {
            const result = await api.markAllInAppNotificationsRead();
            const timestamp = new Date().toISOString();
            setNotifications((current) => current.map((item) => ({ ...item, read_at: item.read_at || timestamp })));
            setUnreadCount(result.unread_count);
          }}
        />,
        document.body
      )}
    </div>
  );
}

function NotificationPanel({
  notifications,
  unreadCount,
  loading,
  error,
  onClose,
  onRead,
  onDismiss,
  onReadAll
}: {
  notifications: InAppNotification[];
  unreadCount: number;
  loading: boolean;
  error: string | null;
  onClose: () => void;
  onRead: (notification: InAppNotification) => Promise<void>;
  onDismiss: (notification: InAppNotification) => Promise<void>;
  onReadAll: () => Promise<void>;
}) {
  const dialogRef = useModalDialog(onClose);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [filter, setFilter] = useState<"all" | "unread">("all");
  const visibleNotifications = useMemo(
    () => filter === "unread"
      ? notifications.filter((notification) => !notification.read_at)
      : notifications,
    [filter, notifications]
  );

  async function action(id: string, operation: () => Promise<void>) {
    setBusyId(id);
    setActionError(null);
    try {
      await operation();
    } catch (reason: unknown) {
      setActionError(errorText(reason));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <aside ref={dialogRef} className="notification-panel" role="dialog" aria-modal="true" aria-labelledby="notification-title">
      <div className="notification-panel-header">
        <header>
          <div><span className="eyebrow">Inbox</span><h2 id="notification-title">Notifications</h2></div>
          <AppSurfaceControlButton
            accessibleLabel="Close notifications"
            kind="close"
            onClick={onClose}
          />
        </header>
        <div className="notification-panel-actions">
          <div className="notification-filter-tabs" role="group" aria-label="Notification view">
            <button type="button" aria-pressed={filter === "all"} onClick={() => setFilter("all")}>All</button>
            <button type="button" aria-pressed={filter === "unread"} onClick={() => setFilter("unread")}>Unread</button>
          </div>
          <div className="notification-bulk-actions">
            <span>{unreadCount} unread</span>
            <button className="text-button" type="button" disabled={unreadCount === 0 || busyId !== null} onClick={() => void action("all", onReadAll)}>Mark all read</button>
          </div>
        </div>
      </div>
      {error && <div className="form-error" role="alert">{error}</div>}
      {actionError && <div className="form-error" role="alert">{actionError}</div>}
      {loading && notifications.length === 0 ? <div className="inline-loading" aria-busy="true"><span className="spinner" aria-hidden="true" />Loading notifications…</div> : notifications.length === 0 ? <p className="empty-copy">No notifications yet.</p> : (
        visibleNotifications.length === 0
          ? <p className="empty-copy">No unread notifications.</p>
          : <ol className="notification-list">
          {visibleNotifications.map((notification) => (
            <li key={notification.id} className={notification.read_at ? "" : "unread"}>
              <button className="notification-open" type="button" disabled={busyId === notification.id} onClick={() => void action(notification.id, () => onRead(notification))}>
                <span><strong>{notification.title}</strong><time dateTime={notification.inserted_at}>{formatTime(notification.inserted_at)}</time></span>
                <p>{notification.body}</p>
              </button>
              <button className="notification-dismiss" type="button" aria-label={`Dismiss ${notification.title}`} disabled={busyId === notification.id} onClick={() => void action(notification.id, () => onDismiss(notification))}><AppIcon name="x" /></button>
            </li>
          ))}
        </ol>
      )}
    </aside>
  );
}

export function notificationDestination(notification: InAppNotification): string {
  const actionPath = canonicalInternalPath(notification.action_url);
  if (actionPath) return actionPath;
  if (!safeUuid(notification.conversation_id)) return "/app/";
  const query = new URLSearchParams({ conversation: notification.conversation_id as string });
  if (safeUuid(notification.message_id)) query.set("message", notification.message_id as string);
  return `/app/?${query.toString()}`;
}

function canonicalInternalPath(value?: string | null): string | null {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return null;
  try {
    const origin = "https://k-comms.invalid";
    const url = new URL(value, origin);
    const decodedPath = decodeURIComponent(url.pathname);
    const pathSegments = decodedPath.split("/");
    if (
      url.origin !== origin ||
      pathSegments.some((segment) => segment === "." || segment === "..") ||
      decodedPath.includes("\\") ||
      (decodedPath !== "/app" && !decodedPath.startsWith("/app/"))
    ) {
      return null;
    }
    const path = url.pathname === "/app" ? "/app/" : url.pathname;
    return `${path}${url.search}${url.hash}`;
  } catch {
    return null;
  }
}

function safeUuid(value?: string | null): boolean {
  return Boolean(value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value));
}
