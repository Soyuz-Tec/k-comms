import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

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
    role: "owner",
    platform_role: "platform_operator",
    platform_role_expires_at: "2099-01-01T00:00:00Z",
    status: "active",
    version: 1
  },
  device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
};

const conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "General",
  visibility: "tenant",
  latest_sequence: 1,
  last_read_sequence: 0,
  unread_count: 1,
  version: 1,
  inserted_at: "2026-07-14T10:00:00Z",
  updated_at: "2026-07-14T10:00:00Z"
};

const message = {
  id: "message-1",
  tenant_id: "tenant-1",
  conversation_id: "conversation-1",
  sender_user_id: "user-1",
  sender_device_id: "device-1",
  client_message_id: "client-message-1",
  conversation_sequence: 1,
  body: "Welcome to the accessible project workspace.",
  metadata: {},
  status: "active",
  inserted_at: "2026-07-14T10:00:00Z",
  attachments: [],
  reactions: [],
  thread_reply_count: 0
};

const representativeStateIds = [
  "sign-in",
  "invitation",
  "recovery-request",
  "recovery-invalid-link",
  "empty-workspace",
  "populated-workspace",
  "workspace-error",
  "offline-reconnect",
  "search",
  "thread",
  "notifications",
  "settings",
  "admin",
  "operations"
] as const;

test("accessibility matrix names every representative release state", () => {
  expect(new Set(representativeStateIds).size).toBe(14);
});

test("sign-in satisfies automated WCAG A and AA checks", async ({ page }) => {
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("invitation acceptance satisfies automated WCAG A and AA checks", async ({ page }) => {
  await page.goto("/app/#invitation_token=synthetic-token&tenant_slug=acme");
  await expect(page.getByRole("heading", { name: "Accept your invitation" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("password recovery request satisfies automated WCAG A and AA checks", async ({ page }) => {
  await openClientRoute(page, "/forgot-password");
  await expect(page.getByRole("heading", { name: "Reset your password" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("invalid reset-link state satisfies automated WCAG A and AA checks", async ({ page }) => {
  await openClientRoute(page, "/reset-password");
  await expect(page.getByRole("heading", { name: "Reset link unavailable" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("empty authenticated workspace satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page);
  await page.goto("/app/");
  await expect(page.getByText("No conversations yet.")).toBeVisible();
  await expectNoWcagFailures(page);
});

test("populated and offline messaging states satisfy automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page, { populated: true });
  await page.goto("/app/?conversation=conversation-1");
  await page.getByRole("button", { name: /General channel/ }).click();
  await expect(page.getByText(message.body)).toBeVisible();
  await expect(page.getByText("Offline", { exact: true })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("workspace refresh error satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page, { workspaceError: true });
  await page.goto("/app/");
  await expect(page.getByRole("alert")).toContainText("Workspace could not refresh");
  await expectNoWcagFailures(page);
});

test("message search satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page, { populated: true });
  await page.goto("/app/?conversation=conversation-1");
  await page.getByRole("button", { name: "Search messages" }).click();
  await expect(page.getByRole("heading", { name: "Search messages" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("thread drawer satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page, { populated: true });
  await page.goto("/app/?conversation=conversation-1");
  await page.getByRole("button", { name: /General channel/ }).click();
  await expect(page.getByText(message.body)).toBeVisible();
  await page.getByRole("button", { name: "Start thread" }).click();
  await expect(page.getByRole("heading", { name: "Thread" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("notification drawer satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page, { populated: true });
  await page.goto("/app/?conversation=conversation-1");
  await page.getByRole("button", { name: /Notifications/ }).click();
  await expect(page.getByRole("heading", { name: "Notifications" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("settings satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page);
  await page.goto("/app/settings");
  await expect(page.getByRole("heading", { name: "Profile and settings" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("tenant administration satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page);
  await openClientRoute(page, "/admin");
  await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("platform operations satisfies automated WCAG A and AA checks", async ({ page }) => {
  await installAuthenticatedMocks(page);
  await openClientRoute(page, "/ops");
  await expect(page.getByRole("heading", { name: "Operations triage" })).toBeVisible();
  await expectNoWcagFailures(page);
});

test("keyboard focus remains visible in forced-colors and reduced-motion modes", async ({ page }) => {
  await page.emulateMedia({ forcedColors: "active", reducedMotion: "reduce" });
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();

  await page.keyboard.press("Tab");
  const focused = page.locator(":focus");
  await expect(focused).toBeVisible();
  await expect(focused).not.toHaveCSS("outline-style", "none");
  await expectNoWcagFailures(page);
});

test("320 CSS-pixel reflow and WCAG text spacing remain usable", async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 640 });
  await installAuthenticatedMocks(page, { populated: true });
  await page.goto("/app/?conversation=conversation-1");
  await page.getByRole("button", { name: /General channel/ }).click();
  await page.addStyleTag({
    content: "p, li, dd, dt, label, button, input, textarea { line-height: 1.5 !important; letter-spacing: .12em !important; word-spacing: .16em !important; } p { margin-bottom: 2em !important; }"
  });

  await expect(page.getByText(message.body)).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await expectNoWcagFailures(page);
});

async function expectNoWcagFailures(page: Page) {
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(results.violations.map(({ id, impact, tags, nodes }) => ({
    id,
    impact,
    tags,
    targets: nodes.map((node) => node.target)
  }))).toEqual([]);
}

async function openClientRoute(page: Page, path: string) {
  await page.goto("/app/");
  await page.evaluate((nextPath) => {
    window.history.pushState({}, "", nextPath);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }, path);
}

async function installAuthenticatedMocks(
  page: Page,
  options: { populated?: boolean; workspaceError?: boolean } = {}
) {
  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({
    json: {
      tenant: session.tenant,
      user: session.user,
      device: session.device,
      capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 }
    }
  }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => {
    if (options.workspaceError) return route.fulfill({ status: 503, json: { error: { code: "unavailable", detail: "Synthetic workspace refresh failure" } } });
    return route.fulfill({ json: { data: options.populated ? [conversation] : [] } });
  });
  await page.route("**/api/v1/conversations/conversation-1/messages/message-1/thread**", (route) => route.fulfill({
    json: { data: { root: message, replies: [], reply_count: 0 }, page: { has_more: false, next_before_sequence: null } }
  }));
  await page.route("**/api/v1/conversations/conversation-1/messages**", (route) => route.fulfill({
    json: { data: options.populated ? [message] : [], page: { has_more: false, next_after_sequence: null, reset_required: false } }
  }));
  await page.route("**/api/v1/conversations/conversation-1/members", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/conversations/conversation-1/read-cursor", (route) => route.fulfill({ status: 204 }));
  await page.route("**/api/v1/search**", (route) => route.fulfill({ json: { data: options.populated ? [message] : [] } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({
    json: {
      data: [{ id: "notification-1", event_type: "message", title: "New activity", body: "A conversation has new activity.", conversation_id: "conversation-1", message_id: "message-1", inserted_at: "2026-07-14T10:00:00Z" }],
      page: { limit: 50, has_more: false, next_cursor: null },
      meta: { unread_count: 1 }
    }
  }));
  await page.route("**/api/v1/me/devices", (route) => route.fulfill({ json: { data: [session.device] } }));
  await page.route("**/api/v1/me/sessions", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-preferences", (route) => route.fulfill({
    json: { data: { email_enabled: true, push_enabled: false, in_app_enabled: true, muted_event_types: [], updated_at: "2026-07-14T10:00:00Z" } }
  }));
  await page.route("**/api/v1/notifications", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-attempts", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/push-subscriptions/config", (route) => route.fulfill({ json: { data: { available: false } } }));
  await page.route("**/api/v1/me/push-subscriptions", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/tenant", (route) => route.fulfill({ json: { data: tenantAdministration() } }));
  await page.route("**/api/v1/admin/invitations", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/platform/ops", (route) => route.fulfill({
    json: {
      data: {
        generated_at: new Date().toISOString(),
        release_revision: "a".repeat(40),
        database: { status: "ready" },
        outbox: { pending: 0, published: 12 },
        notifications: {},
        webhooks: {},
        attachments: {},
        queues: [],
        providers: { notifications: { status: "ready" }, webhooks: { status: "ready" }, attachment_scanner: { status: "ready" } }
      }
    }
  }));
}

function tenantAdministration() {
  const limits = { max_active_users: 500, max_active_conversations: 2_000, max_conversation_members: 250 };
  const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
  return {
    tenant: session.tenant,
    settings: {
      tenant_id: "tenant-1",
      allow_public_channels: true,
      message_edit_window_seconds: 900,
      max_attachment_bytes: 25_000_000,
      default_retention_days: 365,
      ...limits,
      version: 1
    },
    usage: { active_users: 1, active_conversations: 1, largest_conversation_members: 1, limits, at_capacity: flags, over_limit: flags }
  };
}
