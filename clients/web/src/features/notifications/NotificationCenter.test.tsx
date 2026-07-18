import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { InAppNotification } from "../../types";
import { NotificationCenter, notificationDestination } from "./NotificationCenter";

const conversationId = "11111111-1111-4111-8111-111111111111";
const messageId = "22222222-2222-4222-8222-222222222222";

const harness = vi.hoisted(() => ({
  api: {
    inAppNotifications: vi.fn(),
    markInAppNotificationRead: vi.fn(),
    dismissInAppNotification: vi.fn(),
    markAllInAppNotificationsRead: vi.fn()
  }
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: { user: { id: "current-user" } }
  })
}));

function notification(overrides: Partial<InAppNotification> = {}): InAppNotification {
  return {
    id: "notification-1",
    event_type: "mention.created.v1",
    title: "New mention",
    body: "You were mentioned in a conversation.",
    conversation_id: conversationId,
    message_id: messageId,
    action_url: null,
    read_at: null,
    inserted_at: "2026-07-12T12:00:00Z",
    ...overrides
  };
}

function LocationProbe() {
  const location = useLocation();
  return <output aria-label="location">{location.pathname}{location.search}</output>;
}

describe("NotificationCenter", () => {
  beforeEach(() => {
    harness.api.inAppNotifications.mockReset().mockResolvedValue({
      data: [notification()],
      meta: { unread_count: 1 }
    });
    harness.api.markInAppNotificationRead.mockReset().mockResolvedValue({
      ...notification(),
      read_at: "2026-07-12T12:01:00Z"
    });
    harness.api.dismissInAppNotification.mockReset().mockResolvedValue(notification());
    harness.api.markAllInAppNotificationsRead.mockReset().mockResolvedValue({
      updated_count: 1,
      unread_count: 0
    });
  });

  it("marks the item read and navigates to the exact conversation thread", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app"]}><NotificationCenter /><LocationProbe /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: /Notifications, 1 unread/i }));
    await user.click(screen.getByRole("button", { name: /^New mention/i }));

    await waitFor(() => expect(harness.api.markInAppNotificationRead).toHaveBeenCalledWith("notification-1"));
    await waitFor(() =>
      expect(screen.getByLabelText("location")).toHaveTextContent(
        `/app?conversation=${conversationId}&message=${messageId}`
      )
    );
  });

  it("keeps the panel open and reports failed actions without navigating", async () => {
    const user = userEvent.setup();
    harness.api.markInAppNotificationRead.mockRejectedValueOnce(new Error("read failed"));
    render(<MemoryRouter initialEntries={["/app"]}><NotificationCenter /><LocationProbe /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: /Notifications, 1 unread/i }));
    await user.click(screen.getByRole("button", { name: /^New mention/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent("read failed");
    expect(screen.getByRole("dialog", { name: "Notifications" })).toBeInTheDocument();
    expect(screen.getByLabelText("location")).toHaveTextContent("/app");
  });

  it("rejects external, admin, and path-confusion action URLs", () => {
    expect(notificationDestination(notification({ action_url: "https://evil.example/app", conversation_id: null, message_id: null }))).toBe("/app");
    expect(notificationDestination(notification({ action_url: "/admin", conversation_id: null, message_id: null }))).toBe("/app");
    expect(notificationDestination(notification({ action_url: "/application", conversation_id: null, message_id: null }))).toBe("/app");
    expect(notificationDestination(notification({ action_url: "//evil.example/app", conversation_id: null, message_id: null }))).toBe("/app");
    expect(notificationDestination(notification({ action_url: "/app?conversation=safe" }))).toBe("/app?conversation=safe");
  });
});
