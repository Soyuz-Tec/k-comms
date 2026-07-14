import { expect, test } from "@playwright/test";

test("admin creates, rotates, and revokes a scoped bot with one-time credential guards", async ({ page }) => {
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3600,
    received_at: Date.now(),
    tenant: { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" },
    user: { id: "owner-1", tenant_id: "tenant-1", display_name: "Ada Owner", email: "ada@example.test", account_type: "human", role: "owner", status: "active", version: 1 },
    device: { id: "device-1", user_id: "owner-1", name: "Browser", platform: "web" }
  };
  const account = {
    id: "11111111-1111-4111-8111-111111111111",
    tenant_id: "tenant-1",
    user_id: "bot-user-1",
    device_id: "bot-device-1",
    name: "Release Bot",
    credential_prefix: "kcsa_11111111-1111-4111-8111-111111111111",
    secret_hint: "xYz1",
    scopes: ["conversations:read", "messages:read", "messages:write"],
    status: "active",
    expires_at: "2027-01-01T10:00:00Z",
    last_used_at: null,
    last_rotated_at: "2026-07-12T10:00:00Z",
    revoked_at: null,
    version: 1,
    inserted_at: "2026-07-12T10:00:00Z",
    updated_at: "2026-07-12T10:00:00Z"
  };
  let current = account;

  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device, capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({ json: { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/tenant", (route) => {
    const limits = { max_active_users: 500, max_active_conversations: 2000, max_conversation_members: 250 };
    const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
    return route.fulfill({ json: { data: {
      tenant: session.tenant,
      settings: { tenant_id: "tenant-1", allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000, default_retention_days: 365, ...limits, version: 1 },
      usage: { active_users: 1, active_conversations: 0, largest_conversation_members: 0, limits, at_capacity: flags, over_limit: flags }
    } } });
  });
  await page.route("**/api/v1/admin/webhooks", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/webhook-deliveries", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/service-accounts", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: { data: [] } });
    const body = route.request().postDataJSON() as { name: string; scopes: string[]; reason: string; expires_at: string };
    expect(body).toMatchObject({ name: "Release Bot", scopes: ["conversations:read", "messages:read", "messages:write"], reason: "Automate releases" });
    expect(new Date(body.expires_at).toString()).not.toBe("Invalid Date");
    return route.fulfill({ status: 201, json: { data: account, credential: "kcsa_account.one-time-create" } });
  });
  await page.route(`**/api/v1/admin/service-accounts/${account.id}/rotate`, async (route) => {
    expect(route.request().postDataJSON()).toEqual({ version: 1, reason: "Routine rotation" });
    current = { ...account, version: 2, secret_hint: "nEw2" };
    return route.fulfill({ json: { data: current, credential: "kcsa_account.one-time-rotate" } });
  });
  await page.route(`**/api/v1/admin/service-accounts/${account.id}/revoke`, async (route) => {
    expect(route.request().postDataJSON()).toEqual({ version: 2, reason: "Automation retired" });
    current = { ...current, version: 3, status: "revoked", revoked_at: "2026-07-12T11:00:00Z" };
    return route.fulfill({ json: { data: current } });
  });

  await page.goto("/app/");
  await page.evaluate(() => { window.history.pushState({}, "", "/admin"); window.dispatchEvent(new PopStateEvent("popstate")); });
  await page.getByRole("button", { name: "Integrations" }).click();
  await expect(page.getByRole("heading", { name: "Service accounts" })).toBeVisible();
  await page.getByRole("textbox", { name: "Bot name" }).fill("Release Bot");
  await page.getByRole("textbox", { name: "Creation reason" }).fill("Automate releases");
  await page.getByRole("button", { name: "Create service account" }).click();

  await expect(page.getByText("kcsa_account.one-time-create")).toBeVisible();
  await expect(page.getByRole("button", { name: "Create service account" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Rotate credential" })).toBeDisabled();
  await page.getByRole("button", { name: "I stored it" }).click();

  await page.getByRole("button", { name: "Rotate credential" }).click();
  const rotateDialog = page.getByRole("alertdialog", { name: "Rotate service credential?" });
  await rotateDialog.getByRole("textbox", { name: "Reason for this change" }).fill("Routine rotation");
  await rotateDialog.getByRole("button", { name: "Rotate credential" }).click();
  await expect(page.getByText("kcsa_account.one-time-rotate")).toBeVisible();
  await page.getByRole("button", { name: "I stored it" }).click();

  await page.getByRole("button", { name: "Revoke" }).click();
  const revokeDialog = page.getByRole("alertdialog", { name: "Revoke service account?" });
  await revokeDialog.getByRole("textbox", { name: "Reason for this change" }).fill("Automation retired");
  await revokeDialog.getByRole("button", { name: "Revoke account" }).click();
  await expect(page.getByText("revoked")).toBeVisible();
  await expect(page.getByRole("button", { name: "Rotate credential" })).toHaveCount(0);
});
