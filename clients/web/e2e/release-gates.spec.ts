import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

type Role = "member" | "moderator" | "compliance_admin" | "security_admin" | "owner";
type PlatformRole = "platform_operator" | "support_operator" | "security_operator";

async function mockWorkspace(page: Page, role: Role, conversations: unknown[] = [], platformRole?: PlatformRole) {
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3600,
    received_at: Date.now(),
    tenant: { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" },
    user: {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Ada Lovelace",
      email: "ada@example.test",
      role,
      platform_role: platformRole || null,
      platform_role_expires_at: platformRole ? "2099-01-01T00:00:00Z" : null,
      status: "active",
      version: 1
    },
    device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
  };
  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device, capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({ json: { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: conversations } }));
  await page.route("**/api/v1/conversations/*/members", (route) => route.fulfill({ json: { data: [] } }));
  return session;
}

async function openClientRoute(page: Page, path: string) {
  await page.goto("/app/");
  await page.evaluate((nextPath) => {
    window.history.pushState({}, "", nextPath);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }, path);
}

test("protected product routes enforce the client role matrix", async ({ page }) => {
  await mockWorkspace(page, "member");
  await openClientRoute(page, "/admin");
  await expect(page).toHaveURL(/\/app/);
  await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();
});

test("moderators can load moderation without owner-only attachment administration", async ({ page }) => {
  await mockWorkspace(page, "moderator");
  let attachmentRequests = 0;
  await page.route("**/api/v1/moderation/cases", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/attachment-safety", (route) => { attachmentRequests += 1; return route.fulfill({ status: 403, json: { error: { detail: "forbidden" } } }); });
  await openClientRoute(page, "/admin");
  await expect(page.getByRole("heading", { name: "Moderation cases" })).toBeVisible();
  expect(attachmentRequests).toBe(0);
});

test("compliance administrators receive only their scoped admin areas", async ({ page }) => {
  await mockWorkspace(page, "compliance_admin");
  await page.route("**/api/v1/moderation/cases", (route) => route.fulfill({ json: { data: [] } }));
  await openClientRoute(page, "/admin");
  await expect(page.getByRole("button", { name: "Governance" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Audit" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Workspace" })).toHaveCount(0);
});

test("security administrators receive session and audit controls without governance", async ({ page }) => {
  await mockWorkspace(page, "security_admin");
  await openClientRoute(page, "/admin");
  await expect(page.getByRole("heading", { name: "People, roles and sessions" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Governance" })).toHaveCount(0);
});

for (const platformRole of ["platform_operator", "support_operator", "security_operator"] satisfies PlatformRole[]) {
  test(`${platformRole} can open content-blind platform operations`, async ({ page }) => {
    await mockWorkspace(page, "member", [], platformRole);
    let tenantOpsRequests = 0;
    await page.route("**/api/v1/ops", (route) => { tenantOpsRequests += 1; return route.fulfill({ status: 403 }); });
    await page.route("**/api/v1/platform/ops", (route) => route.fulfill({ json: { data: { generated_at: "2026-07-12T10:00:00Z", database: { status: "ready" }, outbox: { pending: 0, published: 0 }, notifications: {}, webhooks: {}, attachments: {}, queues: [], providers: {} } } }));
    await openClientRoute(page, "/ops");
    await expect(page.getByRole("heading", { name: "Service operations" })).toBeVisible();
    await expect(page.getByText("Platform-wide")).toBeVisible();
    await expect(page.getByText("No platform queue jobs.")).toBeVisible();
    expect(tenantOpsRequests).toBe(0);
  });
}

test("mobile conversation list does not clear unread state until the message pane opens", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== "mobile-chromium", "mobile viewport release gate");
  const conversation = { id: "conversation-1", tenant_id: "tenant-1", kind: "channel", title: "General", visibility: "tenant", latest_sequence: 5, last_read_sequence: 0, unread_count: 5, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
  await mockWorkspace(page, "member", [conversation]);
  const messages = Array.from({ length: 5 }, (_, index) => ({ id: `message-${index + 1}`, tenant_id: "tenant-1", conversation_id: "conversation-1", sender_user_id: "user-1", sender_device_id: "device-1", client_message_id: `client-${index + 1}`, conversation_sequence: index + 1, body: `Message ${index + 1}`, metadata: {}, status: "active", inserted_at: "2026-07-12T10:00:00Z", attachments: [], reactions: [] }));
  await page.route("**/api/v1/conversations/conversation-1/messages**", (route) => route.fulfill({ json: { data: messages, page: { has_more: false, next_after_sequence: null, reset_required: false } } }));
  let reads = 0;
  await page.route("**/api/v1/conversations/conversation-1/read-cursor", (route) => { reads += 1; return route.fulfill({ status: 204 }); });

  await page.goto("/app/");
  await expect(page.getByRole("button", { name: /General/ })).toBeVisible();
  await page.waitForTimeout(750);
  expect(reads).toBe(0);

  await page.getByRole("button", { name: /General/ }).click();
  await expect.poll(() => reads).toBeGreaterThan(0);
});

test("desktop and mobile settings expose browser push without automatic registration", async ({ page }) => {
  const session = await mockWorkspace(page, "member");
  await page.route("**/api/v1/me/devices", (route) => route.fulfill({ json: { data: [session.device] } }));
  await page.route("**/api/v1/me/sessions", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-preferences", (route) => route.fulfill({ json: { data: { email_enabled: true, push_enabled: false, in_app_enabled: true, muted_event_types: [], updated_at: "2026-07-12T10:00:00Z" } } }));
  await page.route("**/api/v1/notifications", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-attempts", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/push-subscriptions/config", (route) => route.fulfill({ json: { data: { available: true, vapid_public_key: "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo" } } }));
  let registrations = 0;
  await page.route("**/api/v1/me/push-subscriptions", (route) => {
    if (route.request().method() === "POST") registrations += 1;
    return route.fulfill({ json: { data: [] } });
  });

  await openClientRoute(page, "/app/settings");
  await expect(page.getByRole("heading", { name: "Browser push" })).toBeVisible();
  await expect(page.getByText(/Permission is requested only after|does not support service-worker push|server-side Web Push configuration is incomplete|Notifications are blocked by this browser/i)).toBeVisible();
  expect(registrations).toBe(0);
});
