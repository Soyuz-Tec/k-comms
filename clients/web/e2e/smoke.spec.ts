import { expect, test } from "@playwright/test";

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
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/status", (route) => route.fulfill({ json: { service: "k-comms", version: "0.3.0", status: "operational", node: "test@node" } }));
  await page.route("**/health/ready", (route) => route.fulfill({ json: { status: "ready" } }));
  await page.route("**/api/v1/admin/tenant", (route) => route.fulfill({ json: { data: tenantAdministration() } }));
  await page.route("**/api/v1/admin/invitations", (route) => route.fulfill({ json: { data: [] } }));
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
  await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();
  await page.getByRole("link", { name: "Admin" }).first().click();
  await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
  await page.getByRole("button", { name: "People" }).click();
  await expect(page.getByRole("heading", { name: "People, roles and sessions" })).toBeVisible();
  await expect(page.getByRole("cell", { name: /Ada Lovelace/ })).toBeVisible();
});
