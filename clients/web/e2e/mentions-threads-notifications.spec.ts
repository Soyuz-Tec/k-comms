import { expect, test } from "@playwright/test";
import type { Page, Route } from "@playwright/test";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const memberId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const serviceId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const conversationId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const messageId = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const notificationId = "11111111-1111-4111-8111-111111111111";

test.beforeEach(async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== "chromium", "focused desktop product flow");
  await mockWorkspace(page);
});

test("notification click-through marks read and opens the intended canonical thread", async ({ page }) => {
  let markedRead = false;
  await page.route("**/api/v1/in-app-notifications**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "PATCH" && path.endsWith(`/${notificationId}/read`)) {
      markedRead = true;
      return route.fulfill({ json: { data: { ...notification(), read_at: "2026-07-12T12:01:00Z" } } });
    }
    if (path.endsWith("/unread-count")) return route.fulfill({ json: { data: { unread_count: 1 } } });
    return route.fulfill({ json: { data: [notification()], meta: { unread_count: 1 } } });
  });
  await page.route(`**/api/v1/conversations/${conversationId}/messages/${messageId}/thread**`, (route) =>
    route.fulfill({
      json: {
        data: { root: message(), replies: [], reply_count: 0 },
        page: { has_more: false, next_before_sequence: null }
      }
    })
  );

  await page.goto("/app/");
  await page.getByRole("button", { name: /Notifications, 1 unread/ }).click();
  await page.getByRole("button", { name: /^New mention/ }).click();

  await expect.poll(() => markedRead).toBe(true);
  await expect(page).toHaveURL(new RegExp(`conversation=${conversationId}.*message=${messageId}`));
  await expect(page.getByRole("dialog", { name: "Thread" })).toBeVisible();
  await expect(page.getByRole("dialog", { name: "Thread" }).getByText("Message body", { exact: true })).toBeVisible();
});

test("mention picker excludes sender and service identities and sends explicit recipient IDs", async ({ page }) => {
  let requestBody: Record<string, unknown> | null = null;
  await page.route("**/api/v1/in-app-notifications**", (route) =>
    route.fulfill({ json: { data: [], meta: { unread_count: 0 } } })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/messages`, async (route) => {
    if (route.request().method() === "POST") {
      requestBody = route.request().postDataJSON() as Record<string, unknown>;
      return route.fulfill({ json: { data: { ...message(), body: "Explicit mention", mentioned_user_ids: [memberId] } } });
    }
    return messages(route);
  });

  await page.goto(`/app/?conversation=${conversationId}`);
  await page.getByRole("button", { name: "Mention" }).click();
  const picker = page.getByRole("group", { name: "Mention conversation members" });
  await expect(picker.getByText("Grace Hopper")).toBeVisible();
  await expect(picker.getByText("Build bot")).toHaveCount(0);
  await expect(picker.getByText("Ada Lovelace")).toHaveCount(0);
  await picker.getByRole("checkbox", { name: "Grace Hopper" }).check();
  await page.getByRole("textbox", { name: "Message", exact: true }).fill("Explicit mention");
  await page.getByRole("button", { name: /^Send/ }).click();

  await expect.poll(() => requestBody).not.toBeNull();
  expect(requestBody).toMatchObject({ mentioned_user_ids: [memberId], body: "Explicit mention" });
});

async function mockWorkspace(page: Page) {
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3600,
    received_at: Date.now(),
    tenant: { id: tenantId, name: "Acme Workspace", slug: "acme", status: "active" },
    user: human(userId, "Ada Lovelace"),
    device: { id: "99999999-9999-4999-8999-999999999999", user_id: userId, name: "Browser", platform: "web" }
  };
  const users = [session.user, human(memberId, "Grace Hopper"), { ...human(serviceId, "Build bot"), account_type: "service" }];
  const conversation = {
    id: conversationId,
    tenant_id: tenantId,
    kind: "channel",
    title: "General",
    visibility: "tenant",
    latest_sequence: 1,
    last_read_sequence: 0,
    unread_count: 1,
    inserted_at: "2026-07-12T12:00:00Z",
    updated_at: "2026-07-12T12:00:00Z"
  };

  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device, capabilities: { allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: users } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [conversation] } }));
  await page.route(`**/api/v1/conversations/${conversationId}/members`, (route) => route.fulfill({ json: { data: users.map((user, index) => ({ id: `membership-${index}`, role: "member", joined_at: "2026-07-12T12:00:00Z", last_read_sequence: 0, user })) } }));
  await page.route(`**/api/v1/conversations/${conversationId}/messages**`, messages);
  await page.route(`**/api/v1/conversations/${conversationId}/read-cursor`, (route) => route.fulfill({ json: { data: { sequence: 1 } } }));
}

function messages(route: Route) {
  return route.fulfill({
    json: {
      data: [message()],
      page: { has_more: false, next_after_sequence: null, reset_required: false }
    }
  });
}

function human(id: string, displayName: string) {
  return { id, tenant_id: tenantId, display_name: displayName, account_type: "human", role: "member", status: "active" };
}

function message() {
  return {
    id: messageId,
    tenant_id: tenantId,
    conversation_id: conversationId,
    sender_user_id: userId,
    sender_device_id: "99999999-9999-4999-8999-999999999999",
    client_message_id: "browser-message-0001",
    conversation_sequence: 1,
    body: "Message body",
    metadata: {},
    status: "active",
    thread_root_message_id: null,
    thread_reply_count: 0,
    mentioned_user_ids: [],
    inserted_at: "2026-07-12T12:00:00Z",
    attachments: [],
    reactions: []
  };
}

function notification() {
  return {
    id: notificationId,
    event_type: "mention.created.v1",
    title: "New mention",
    body: "You were mentioned in a conversation.",
    conversation_id: conversationId,
    message_id: messageId,
    action_url: null,
    read_at: null,
    inserted_at: "2026-07-12T12:00:00Z"
  };
}
