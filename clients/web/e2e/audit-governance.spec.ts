import { expect, test } from "@playwright/test";

test("admin exports filtered audit evidence and selects governance targets by name", async ({ page }) => {
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3600,
    received_at: Date.now(),
    tenant: { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" },
    user: { id: "owner-1", tenant_id: "tenant-1", display_name: "Ada Owner", email: "ada@example.test", role: "owner", status: "active", version: 1 },
    device: { id: "device-1", user_id: "owner-1", name: "Browser", platform: "web" }
  };
  const activeUser = { id: "user-active", tenant_id: "tenant-1", display_name: "Alex Active", email: "alex@example.test", role: "member", status: "active", version: 1 };
  const deletedUser = { ...activeUser, id: "user-deleted", display_name: "Dana Deleted", status: "deleted" };
  const activeConversation = { id: "conversation-active", tenant_id: "tenant-1", kind: "channel", title: "Release planning", visibility: "private", latest_sequence: 7, inserted_at: "2026-07-12T09:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
  const archivedConversation = { ...activeConversation, id: "conversation-archived", title: "Archived project", archived_at: "2026-07-12T10:00:00Z" };
  const activeMessage = { id: "message-active", tenant_id: "tenant-1", conversation_id: activeConversation.id, sender_user_id: activeUser.id, sender_device_id: "device-1", client_message_id: "client-1", conversation_sequence: 7, body: "Release note evidence", metadata: {}, status: "active", inserted_at: "2026-07-12T10:00:00Z", attachments: [], reactions: [] };
  let auditExportBody: unknown;
  let holdBody: unknown;
  let deletionBody: unknown;

  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device, capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({ json: { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user, activeUser, deletedUser] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [activeConversation, archivedConversation] } }));
  await page.route("**/api/v1/admin/tenant", (route) => {
    const limits = { max_active_users: 500, max_active_conversations: 2000, max_conversation_members: 250 };
    const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
    return route.fulfill({ json: { data: {
      tenant: session.tenant,
      settings: { tenant_id: "tenant-1", allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000, default_retention_days: 365, ...limits, version: 1 },
      usage: { active_users: 2, active_conversations: 1, largest_conversation_members: 2, limits, at_capacity: flags, over_limit: flags }
    } } });
  });
  await page.route("**/api/v1/admin/audit-events?limit=100", (route) => route.fulfill({ json: { data: [{ id: "audit-1", actor_user_id: session.user.id, action: "user.created", resource_type: "user", resource_id: activeUser.id, metadata: {}, request_id: "request-1", inserted_at: "2026-07-12T10:00:00Z" }] } }));
  await page.route("**/api/v1/admin/audit-events/export", async (route) => {
    auditExportBody = route.request().postDataJSON();
    await route.fulfill({
      status: 200,
      contentType: "text/csv; charset=utf-8",
      headers: {
        "Content-Disposition": "attachment; filename=\"k-comms-audit-20260712T100000Z.csv\"",
        "X-Export-Row-Count": "1",
        "X-Export-Truncated": "false"
      },
      body: "\"action\"\r\n\"user.created\"\r\n"
    });
  });
  await page.route("**/api/v1/admin/retention-policies", (route) => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/admin/legal-holds", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: { data: [] } });
    holdBody = route.request().postDataJSON();
    return route.fulfill({ status: 201, json: { data: { id: "hold-1", created_by_user_id: session.user.id, conversation_id: activeConversation.id, name: "Channel evidence", reason: "Regulatory request", scope_type: "conversation", status: "active", starts_at: "2026-07-12T10:00:00Z", version: 1, inserted_at: "2026-07-12T10:00:00Z" } } });
  });
  await page.route("**/api/v1/admin/deletion-requests", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: { data: [] } });
    deletionBody = route.request().postDataJSON();
    return route.fulfill({ status: 201, json: { data: { id: "deletion-1", requested_by_user_id: session.user.id, message_id: activeMessage.id, target_type: "message", reason: "Requested erasure", status: "pending", version: 1, inserted_at: "2026-07-12T10:00:00Z" } } });
  });
  await page.route(`**/api/v1/conversations/${activeConversation.id}/messages?**`, (route) => route.fulfill({ json: { data: [activeMessage, { ...activeMessage, id: "message-deleted", status: "deleted" }], page: { has_more: false, next_after_sequence: 7, reset_required: false } } }));

  await page.goto("/app/");
  await page.evaluate(() => { window.history.pushState({}, "", "/admin"); window.dispatchEvent(new PopStateEvent("popstate")); });

  await page.getByRole("button", { name: "Audit" }).click();
  await page.getByLabel("Filter loaded events").fill("user.created");
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export audit CSV" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("k-comms-audit-20260712T100000Z.csv");
  expect(auditExportBody).toEqual({ q: "user.created", limit: 5_000 });
  await expect(page.getByRole("status")).toContainText("Downloaded 1 audit events");

  await page.getByRole("button", { name: "Governance" }).click();
  const holdCard = page.getByRole("heading", { name: "Legal holds" }).locator("xpath=ancestor::section[1]");
  await holdCard.getByLabel("Hold scope").selectOption("conversation");
  await expect(holdCard.getByLabel("Hold conversation").getByRole("option", { name: "Release planning" })).toHaveCount(1);
  await expect(holdCard.getByLabel("Hold conversation").getByRole("option", { name: "Archived project" })).toHaveCount(0);
  await holdCard.getByLabel("Hold name").fill("Channel evidence");
  await holdCard.getByLabel("Hold conversation").selectOption(activeConversation.id);
  await holdCard.getByLabel("Reason").fill("Regulatory request");
  await holdCard.getByRole("button", { name: "Create legal hold" }).click();
  expect(holdBody).toEqual({ name: "Channel evidence", reason: "Regulatory request", scope_type: "conversation", conversation_id: activeConversation.id });

  const deletionCard = page.getByRole("heading", { name: "Deletion requests" }).locator("xpath=ancestor::section[1]");
  await expect(deletionCard.getByLabel("Deletion user").getByRole("option", { name: "Dana Deleted" })).toHaveCount(0);
  await deletionCard.getByLabel("Target type").selectOption("message");
  await deletionCard.getByLabel("Message conversation").selectOption(activeConversation.id);
  await deletionCard.getByLabel("Deletion message").selectOption(activeMessage.id);
  await deletionCard.getByLabel("Reason").fill("Requested erasure");
  await deletionCard.getByRole("button", { name: "Request deletion" }).click();
  expect(deletionBody).toEqual({ target_type: "message", message_id: activeMessage.id, reason: "Requested erasure" });
});
