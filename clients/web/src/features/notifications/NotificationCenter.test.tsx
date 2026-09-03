import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
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
    render(<MemoryRouter initialEntries={["/app/"]}><NotificationCenter /><LocationProbe /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: /Notifications, 1 unread/i }));
    await user.click(screen.getByRole("button", { name: /^New mention/i }));

    await waitFor(() => expect(harness.api.markInAppNotificationRead).toHaveBeenCalledWith("notification-1"));
    await waitFor(() =>
      expect(screen.getByLabelText("location")).toHaveTextContent(
        `/app/?conversation=${conversationId}&message=${messageId}`
      )
    );
  });

  it("keeps the panel open and reports failed actions without navigating", async () => {
    const user = userEvent.setup();
    harness.api.markInAppNotificationRead.mockRejectedValueOnce(new Error("read failed"));
    render(<MemoryRouter initialEntries={["/app/"]}><NotificationCenter /><LocationProbe /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: /Notifications, 1 unread/i }));
    await user.click(screen.getByRole("button", { name: /^New mention/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent("read failed");
    expect(screen.getByRole("dialog", { name: "Notifications" })).toBeInTheDocument();
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/");
  });

  it("filters a long notification list without hiding bulk read controls", async () => {
    harness.api.inAppNotifications.mockResolvedValue({
      data: [
        notification(),
        notification({
          id: "notification-2",
          title: "Earlier update",
          read_at: "2026-07-12T11:00:00Z"
        })
      ],
      meta: { unread_count: 1 }
    });
    const user = userEvent.setup();
    render(<MemoryRouter><NotificationCenter /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: /Notifications, 1 unread/i }));
    expect(screen.getByRole("button", { name: /^Earlier update/i })).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Unread" }));
    expect(screen.getByRole("button", { name: /^New mention/i })).toBeVisible();
    expect(screen.queryByRole("button", { name: /^Earlier update/i })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Mark all read" })).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Mark all read" }));
    expect(await screen.findByText("No unread notifications.")).toBeVisible();
  });

  it("portals the modal outside the topbar and restores focus after close or Escape", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <MemoryRouter initialEntries={["/app/"]}>
        <div className="topbar"><NotificationCenter /></div>
      </MemoryRouter>
    );
    const trigger = await screen.findByRole("button", { name: /Notifications, 1 unread/i });

    await user.click(trigger);
    const dialog = screen.getByRole("dialog", { name: "Notifications" });
    const close = screen.getByRole("button", { name: "Close notifications" });
    expect(dialog.parentElement).toBe(document.body);
    expect(container).toHaveAttribute("aria-hidden", "true");
    expect(container.inert).toBe(true);
    await waitFor(() => expect(close).toHaveFocus());

    await user.click(close);
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument());
    expect(container).not.toHaveAttribute("aria-hidden");
    expect(container.inert).toBe(false);
    await waitFor(() => expect(trigger).toHaveFocus());

    await user.click(trigger);
    await waitFor(() => expect(screen.getByRole("button", { name: "Close notifications" })).toHaveFocus());
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument());
    await waitFor(() => expect(trigger).toHaveFocus());
  });

  it("rejects external, admin, and path-confusion action URLs", () => {
    expect(notificationDestination(notification({ action_url: "https://evil.example/app", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/admin", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/application", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "//evil.example/app", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/app/../admin", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/app/%2f../admin", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/app", conversation_id: null, message_id: null }))).toBe("/app/");
    expect(notificationDestination(notification({ action_url: "/app?conversation=legacy" }))).toBe("/app/?conversation=legacy");
    expect(notificationDestination(notification({ action_url: "/app/?conversation=safe" }))).toBe("/app/?conversation=safe");
  });
});
