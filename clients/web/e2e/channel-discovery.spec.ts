import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const tenant = { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" };
const user = { id: "user-1", tenant_id: "tenant-1", display_name: "Ada Lovelace", email: "ada@example.test", role: "member", platform_role: null, status: "active", version: 1 };
const device = { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" };
const conversation = { id: "channel-1", tenant_id: "tenant-1", kind: "channel", title: "Projects", visibility: "tenant", latest_sequence: 0, last_read_sequence: 0, unread_count: 0, archived_at: null, version: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
const membership = { id: "membership-1", role: "member", joined_at: "2026-07-12T10:00:00Z", left_at: null, last_read_sequence: 0, version: 3 };

async function mockChannelWorkspace(page: Page, allowPublicChannels: boolean, conversations: () => unknown[]) {
  const session = { access_token: "access-token", refresh_token: "refresh-token", token_type: "Bearer", expires_in: 3600, received_at: Date.now(), tenant, user, device };
  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant, user, device, capabilities: { allow_public_channels: allowPublicChannels, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: conversations() } }));
  await page.route("**/api/v1/conversations/channel-1/messages**", (route) => route.fulfill({ json: { data: [], page: { has_more: false, next_after_sequence: null, reset_required: false } } }));
}

test("user discovers, joins, and opens a public channel", async ({ page }) => {
  let joined = false;
  await mockChannelWorkspace(page, true, () => joined ? [conversation] : []);
  await page.route("**/api/v1/channels/discover**", (route) => route.fulfill({ json: { data: [{ ...conversation, joined, member_count: joined ? 3 : 2, membership: joined ? membership : null }], page: { limit: 25, has_more: false, next_cursor: null } } }));
  await page.route("**/api/v1/channels/channel-1/join", (route) => { joined = true; return route.fulfill({ status: 201, json: { data: { conversation, membership }, replayed: false } }); });

  await page.goto("/app/");
  await page.getByRole("button", { name: "Browse channels" }).click();
  await expect(page.getByRole("dialog", { name: "Browse channels" })).toBeVisible();
  await page.getByRole("button", { name: "Join" }).click();
  await expect(page.getByRole("button", { name: "Open" })).toBeVisible();
  await page.getByRole("button", { name: "Open" }).click();
  await expect(page.getByRole("heading", { name: "Projects" })).toBeVisible();
});

test("workspace policy disables channel discovery without an API request", async ({ page }) => {
  await mockChannelWorkspace(page, false, () => []);
  let discoveryRequests = 0;
  await page.route("**/api/v1/channels/discover**", (route) => { discoveryRequests += 1; return route.fulfill({ json: { data: [], page: { limit: 25, has_more: false, next_cursor: null } } }); });
  await page.goto("/app/");
  await page.getByRole("button", { name: "Browse channels" }).click();
  await expect(page.getByRole("heading", { name: "Channel discovery is disabled" })).toBeVisible();
  expect(discoveryRequests).toBe(0);
});

test("private or empty discovery results are not exposed", async ({ page }) => {
  await mockChannelWorkspace(page, true, () => []);
  await page.route("**/api/v1/channels/discover**", (route) => route.fulfill({ json: { data: [{ ...conversation, id: "private-1", title: "Secret", visibility: "private", joined: false, member_count: 1, membership: null }], page: { limit: 25, has_more: false, next_cursor: null } } }));
  await page.goto("/app/");
  await page.getByRole("button", { name: "Browse channels" }).click();
  await expect(page.getByRole("heading", { name: "No public channels found" })).toBeVisible();
  await expect(page.getByText("#Secret")).toHaveCount(0);
});

test("joined user leaves a public channel with the membership version", async ({ page }) => {
  let joined = true;
  let leaveBody: unknown;
  await mockChannelWorkspace(page, true, () => joined ? [conversation] : []);
  await page.route("**/api/v1/conversations/channel-1/members", (route) => route.fulfill({ json: { data: [{ ...membership, user }] } }));
  await page.route("**/api/v1/channels/channel-1/membership", (route) => {
    leaveBody = route.request().postDataJSON();
    joined = false;
    return route.fulfill({ json: { data: { conversation, membership: { ...membership, version: 4, left_at: "2026-07-12T10:10:00Z" } }, replayed: false } });
  });
  await page.goto("/app/");
  await page.getByRole("button", { name: /Projects/ }).click();
  await page.getByRole("button", { name: "Details" }).click();
  await expect(page.getByRole("button", { name: "Leave channel" })).toBeVisible();
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Leave channel" }).click();
  await expect(page.getByRole("button", { name: /Projects/ })).toHaveCount(0);
  expect(leaveBody).toEqual({ version: 3 });
});
