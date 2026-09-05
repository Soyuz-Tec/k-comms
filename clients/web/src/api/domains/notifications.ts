import type { DataResponse, InAppNotification, InAppNotificationPage, ListResponse, NotificationAttempt, NotificationIntent, NotificationPreference, PushSubscriptionConfig, PushSubscriptionInput, PushSubscriptionRecord } from "../../types";
import type { ApiRequest } from "../contracts";

export function createNotificationsApi(request: ApiRequest) {
  const api = {
    notificationPreference(): Promise<NotificationPreference> {
        return request<DataResponse<NotificationPreference>>("/api/v1/notification-preferences").then(
          (response) => response.data
        );
      },

    updateNotificationPreference(input: Pick<NotificationPreference, "email_enabled" | "push_enabled" | "in_app_enabled" | "muted_event_types">): Promise<NotificationPreference> {
        return request<DataResponse<NotificationPreference>>("/api/v1/notification-preferences", {
          method: "PUT",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    notifications(): Promise<NotificationIntent[]> {
        return request<ListResponse<NotificationIntent>>("/api/v1/notifications").then(
          (response) => response.data
        );
      },

    notificationAttempts(): Promise<NotificationAttempt[]> {
        return request<ListResponse<NotificationAttempt>>("/api/v1/notification-attempts").then(
          (response) => response.data
        );
      },

    retryNotification(id: string): Promise<NotificationIntent> {
        return request<DataResponse<NotificationIntent>>(`/api/v1/notification-intents/${encodeURIComponent(id)}/retry`, { method: "POST" }).then(
          (response) => response.data
        );
      },

    pushSubscriptionConfig(): Promise<PushSubscriptionConfig> {
        return request<DataResponse<PushSubscriptionConfig>>(
          "/api/v1/me/push-subscriptions/config"
        ).then((response) => response.data);
      },

    pushSubscriptions(): Promise<PushSubscriptionRecord[]> {
        return request<ListResponse<PushSubscriptionRecord>>(
          "/api/v1/me/push-subscriptions"
        ).then((response) => response.data);
      },

    registerPushSubscription(input: PushSubscriptionInput): Promise<{ data: PushSubscriptionRecord; replayed: boolean }> {
        return request("/api/v1/me/push-subscriptions", {
          method: "POST",
          body: JSON.stringify(input)
        });
      },

    revokePushSubscription(id: string): Promise<PushSubscriptionRecord> {
        return request<DataResponse<PushSubscriptionRecord>>(
          `/api/v1/me/push-subscriptions/${encodeURIComponent(id)}`,
          { method: "DELETE" }
        ).then((response) => response.data);
      },

    inAppNotifications(limit = 50, options: { filter?: "all" | "unread"; cursor?: string | null } = {}): Promise<InAppNotificationPage> {
        const params = new URLSearchParams({ limit: String(Math.max(1, Math.min(limit, 100))) });
        if (options.filter === "unread") params.set("filter", "unread");
        if (options.cursor) params.set("cursor", options.cursor);
        return request(`/api/v1/in-app-notifications?${params.toString()}`);
      },

    inAppUnreadCount(): Promise<number> {
        return request<DataResponse<{ unread_count: number }>>(
          "/api/v1/in-app-notifications/unread-count"
        ).then((response) => response.data.unread_count);
      },

    markInAppNotificationRead(id: string): Promise<InAppNotification> {
        return request<DataResponse<InAppNotification>>(
          `/api/v1/in-app-notifications/${encodeURIComponent(id)}/read`,
          { method: "PATCH" }
        ).then((response) => response.data);
      },

    dismissInAppNotification(id: string): Promise<InAppNotification> {
        return request<DataResponse<InAppNotification>>(
          `/api/v1/in-app-notifications/${encodeURIComponent(id)}`,
          { method: "DELETE" }
        ).then((response) => response.data);
      },

    markAllInAppNotificationsRead(): Promise<{ updated_count: number; unread_count: number }> {
        return request<DataResponse<{ updated_count: number; unread_count: number }>>(
          "/api/v1/in-app-notifications/read-all",
          { method: "POST" }
        ).then((response) => response.data);
      }
  };
  return api;
}

export type NotificationsApi = ReturnType<typeof createNotificationsApi>;
