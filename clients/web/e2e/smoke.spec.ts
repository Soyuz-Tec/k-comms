import { expect, mockServiceStatus, test } from "./fixtures";

const session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 3600,
  received_at: Date.now(),
  tenant: { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" },
  user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada Lovelace", email: "ada@example.test", role: "owner", status: "active" },
  device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
};

test.beforeEach(async ({ page }) => {
  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({ json: { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/status", (route) => route.fulfill({ json: mockServiceStatus() }));
  await page.route("**/health/ready", (route) => route.fulfill({ json: { status: "ready" } }));
  await page.route("**/api/v1/admin/tenant", (route) => route.fulfill({ json: { data: tenantAdministration() } }));
  await page.route("**/api/v1/admin/invitations", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/devices", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/sessions", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-preferences", (route) => route.fulfill({ json: {
    data: {
      email_enabled: true,
      push_enabled: false,
      in_app_enabled: true,
      muted_event_types: [],
      updated_at: "2026-07-24T00:00:00Z"
    }
  } }));
  await page.route("**/api/v1/notifications", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/notification-attempts", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/push-subscriptions/config", (route) => route.fulfill({ json: {
    data: { available: false, vapid_public_key: null }
  } }));
  await page.route("**/api/v1/me/push-subscriptions", (route) => route.fulfill({ json: { data: [] } }));
});

function tenantAdministration() {
  const limits = { max_active_users: 500, max_active_conversations: 2000, max_conversation_members: 250 };
  const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
  return {
    tenant: session.tenant,
    settings: { tenant_id: "tenant-1", allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000, default_retention_days: 365, ...limits, version: 1 },
    usage: { active_users: 1, active_conversations: 0, largest_conversation_members: 0, limits, at_capacity: flags, over_limit: flags }
  };
}

test("user and tenant-admin routes are independently navigable", async ({ page }) => {
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
  const primaryYou = page.getByRole("navigation", { name: "Primary navigation" })
    .getByRole("link", { name: "You", exact: true });
  if (await primaryYou.isVisible()) await primaryYou.click();
  else await page.getByRole("link", { name: "You", exact: true }).click();
  await expect(page.getByRole("heading", { name: "You" })).toBeVisible();
  /*
   * Role tools reach the phone from the You screen this test already opened —
   * the overflow drawer that used to carry them was duplicating it. Desktop
   * still reaches them from the account menu in the rail.
   */
  const onPhone = await page.getByRole("navigation", { name: "Primary navigation" }).isVisible();
  if (onPhone) {
    const workspaceTools = page.getByRole("navigation", { name: "Workspace", exact: true });
    await expect(workspaceTools).toBeVisible();
    await workspaceTools
      .getByRole("link", { name: "Workspace administration", exact: true })
      .click();
  } else {
    await page.locator("summary.workspace-account-trigger").click();
    await page.locator(".desktop-account-panel")
      .getByRole("link", { name: "Workspace administration", exact: true })
      .click();
  }
  await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
  await page.getByRole("button", { name: "People" }).click();
  await expect(page.getByRole("heading", { name: "People, roles and sessions" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Ada Lovelace ada@example.test" })).toBeVisible();
});

test("legacy member navigation canonicalizes inside the service-worker scope", async ({ page }) => {
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();

  await page.evaluate(() => {
    window.history.pushState({}, "", "/app");
    window.dispatchEvent(new PopStateEvent("popstate"));
  });

  await expect(page).toHaveURL(/\/app\/$/);
  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
});
