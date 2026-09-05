import { useCallback, useEffect, useRef, useState } from "react";
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
  const [filter, setFilter] = useState<"all" | "unread">("all");
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [failedCursor, setFailedCursor] = useState<string | null>(null);
  const [refreshAvailable, setRefreshAvailable] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const requestVersion = useRef(0);
  const openRef = useRef(open);
  const busyRef = useRef(false);
  openRef.current = open;
  const navigate = useNavigate();

  const userId = session?.user.id;
  const load = useCallback(async (cursor: string | null = null) => {
    if (!userId || busyRef.current) return;
    const version = ++requestVersion.current;
    setLoading(true);
    setError(null);
    try {
      const page = await api.inAppNotifications(50, { filter, cursor });
      if (version !== requestVersion.current) return;
      setNotifications((current) => cursor
        ? [...current, ...page.data.filter((item) => !current.some((existing) => existing.id === item.id))]
        : page.data);
      setUnreadCount(page.meta.unread_count);
      setNextCursor(page.page?.has_more ? page.page.next_cursor : null);
      setRefreshAvailable(false);
    } catch (reason: unknown) {
      if (version !== requestVersion.current) return;
      setFailedCursor(cursor);
      setError(errorText(reason));
    } finally {
      if (version === requestVersion.current) setLoading(false);
    }
  }, [api, filter, userId]);

  useEffect(() => {
    setNotifications([]);
    setNextCursor(null);
    void load();
    // Keep loaded pages and scroll position stable while the user reads the inbox.
    const refresh = () => {
      if (openRef.current) setRefreshAvailable(true);
      else void load();
    };
    const timer = window.setInterval(() => { if (!openRef.current) void load(); }, 30_000);
    window.addEventListener("focus", refresh);
    window.addEventListener("k-comms:notification-available", refresh);
    return () => {
      requestVersion.current += 1;
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      window.removeEventListener("k-comms:notification-available", refresh);
    };
  }, [load]);

  if (!session) return null;

  async function action(id: string, operation: (isCurrent: () => boolean) => Promise<void>) {
    if (busyRef.current) return;
    busyRef.current = true;
    const version = ++requestVersion.current;
    setLoading(false);
    setBusyId(id);
    setActionError(null);
    try {
      await operation(() => version === requestVersion.current);
    } catch (reason: unknown) {
      if (version === requestVersion.current) setActionError(errorText(reason));
    } finally {
      busyRef.current = false;
      setBusyId(null);
    }
  }

  function close() {
    if (!busyRef.current) setOpen(false);
  }

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
          actionError={actionError}
          busyId={busyId}
          filter={filter}
          onFilter={setFilter}
          nextCursor={nextCursor}
          refreshAvailable={refreshAvailable}
          onRefresh={() => void load()}
          onRetry={() => void load(failedCursor)}
          onLoadMore={() => void load(nextCursor)}
          onClose={close}
          onRead={(notification) => action(notification.id, async (isCurrent) => {
            if (!notification.read_at) {
              const updated = await api.markInAppNotificationRead(notification.id);
              if (!isCurrent()) return;
              setNotifications((current) => current.map((item) => item.id === updated.id ? updated : item));
              setUnreadCount((current) => Math.max(0, current - 1));
            }
            if (!isCurrent()) return;
            setOpen(false);
            navigate(notificationDestination(notification));
          })}
          onDismiss={(notification) => action(notification.id, async (isCurrent) => {
            await api.dismissInAppNotification(notification.id);
            if (!isCurrent()) return;
            setNotifications((current) => current.filter((item) => item.id !== notification.id));
            if (!notification.read_at) setUnreadCount((current) => Math.max(0, current - 1));
          })}
          onReadAll={() => action("all", async (isCurrent) => {
            const result = await api.markAllInAppNotificationsRead();
            if (!isCurrent()) return;
            const timestamp = new Date().toISOString();
            setNotifications((current) => filter === "unread" ? [] : current.map((item) => ({ ...item, read_at: item.read_at || timestamp })));
            if (filter === "unread") setNextCursor(null);
            setUnreadCount(result.unread_count);
          })}
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
  actionError,
  busyId,
  filter,
  onFilter,
  nextCursor,
  refreshAvailable,
  onRefresh,
  onRetry,
  onLoadMore,
  onClose,
  onRead,
  onDismiss,
  onReadAll
}: {
  notifications: InAppNotification[];
  unreadCount: number;
  loading: boolean;
  error: string | null;
  actionError: string | null;
  busyId: string | null;
  filter: "all" | "unread";
  onFilter: (filter: "all" | "unread") => void;
  nextCursor: string | null;
  refreshAvailable: boolean;
  onRefresh: () => void;
  onRetry: () => void;
  onLoadMore: () => void;
  onClose: () => void;
  onRead: (notification: InAppNotification) => Promise<void>;
  onDismiss: (notification: InAppNotification) => Promise<void>;
  onReadAll: () => Promise<void>;
}) {
  const dialogRef = useModalDialog(onClose);
  const visibleNotifications = filter === "unread" ? notifications.filter((notification) => !notification.read_at) : notifications;

  return (
    <>
    <div className="notification-backdrop" aria-hidden="true" />
    <aside ref={dialogRef} className="notification-panel notification-inbox" role="dialog" aria-modal="true" aria-labelledby="notification-title">
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
            <button type="button" disabled={busyId !== null} aria-pressed={filter === "all"} onClick={() => onFilter("all")}>All</button>
            <button type="button" disabled={busyId !== null} aria-pressed={filter === "unread"} onClick={() => onFilter("unread")}>Unread</button>
          </div>
          <div className="notification-bulk-actions">
            <span>{unreadCount} unread</span>
            <button className="text-button" type="button" disabled={unreadCount === 0 || busyId !== null || loading} onClick={() => void onReadAll()}>Mark all read</button>
          </div>
        </div>
      </div>
      {refreshAvailable && <div className="notification-refresh" role="status">Updates may be available. <button type="button" className="text-button" disabled={loading || busyId !== null} onClick={onRefresh}>Refresh notifications</button></div>}
      {error && <div className="form-error" role="alert">{error} <button type="button" className="text-button" disabled={loading || busyId !== null} onClick={onRetry}>Retry notifications</button></div>}
      {actionError && <div className="form-error" role="alert">{actionError}</div>}
      {loading && notifications.length === 0 ? <div className="inline-loading" role="status"><span className="spinner" aria-hidden="true" />Loading notifications…</div> : (
        visibleNotifications.length === 0 && !error
          ? <p className="empty-copy">{nextCursor ? "More notifications are available below." : filter === "unread" ? "No unread notifications." : "No notifications yet."}</p>
          : <ol className="notification-list">
          {visibleNotifications.map((notification) => (
            <li key={notification.id} className={notification.read_at ? "" : "unread"}>
              <button className="notification-open" type="button" disabled={busyId !== null || loading} onClick={() => void onRead(notification)}>
                <span><strong>{notification.title}{!notification.read_at && <span className="notification-unread-dot" aria-label="Unread" />}</strong><time dateTime={notification.inserted_at}>{formatTime(notification.inserted_at)}</time></span>
                <p>{notification.body}</p>
              </button>
              <button className="notification-dismiss" type="button" aria-label={`Dismiss notification: ${notification.title}`} title="Remove from notifications; the message is kept" disabled={busyId !== null || loading} onClick={() => void onDismiss(notification)}>Dismiss</button>
            </li>
          ))}
        </ol>
      )}
      {nextCursor && <button className="button secondary notification-load-more" type="button" disabled={loading || busyId !== null} onClick={onLoadMore}>{loading ? "Loading more notifications…" : "Load more notifications"}</button>}
    </aside>
    </>
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
