import { expect, test } from "@playwright/test";
import type { Locator, Page, Route } from "@playwright/test";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const messageId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

const viewportCases = [
  { width: 320, height: 640 },
  { width: 390, height: 844 },
  { width: 700, height: 900 }
] as const;

test.describe("authenticated mobile web acceptance", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== "chromium", "explicit mobile viewport matrix runs once");
    await installDeterministicMediaDevices(page);
  });

  for (const viewport of viewportCases) {
    test(`${viewport.width}px supports list, messaging, account and product navigation`, async ({ page }) => {
      await page.setViewportSize(viewport);
      const fixture = await installWorkspace(page);

      await page.goto("/app/");
      await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(page.locator("nav.mobile-product-nav")).toBeVisible();
      await expect(page.locator("nav.product-nav")).toBeHidden();
      await expectNoDocumentOverflow(page);

      const conversation = page.getByRole("button", { name: /General/ });
      await expectMinimumTarget(conversation, "conversation row");
      await expectMinimumTargets(page.locator("nav.mobile-product-nav a"), "mobile product navigation");
      await expectMinimumTarget(page.getByRole("button", { name: "Notifications" }), "notification control");

      await page.waitForTimeout(650);
      expect(fixture.readCursorRequests).toBe(0);

      const accountControl = page.locator('summary[aria-label="Account menu"]');
      await expectMinimumTarget(accountControl, "mobile account control");
      await accountControl.click();
      await expect(page.getByRole("button", { name: "Sign out" })).toBeVisible();

      await page.goto(`/app/?conversation=${conversationId}`);
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-messages/);
      await expect(page.getByText("Mobile-ready message body", { exact: true })).toBeVisible();

      const back = page.getByRole("button", { name: "Back to conversations" });
      const startAudio = page.getByRole("button", { name: "Start audio call" });
      const startVideo = page.getByRole("button", { name: "Start video call" });
      const details = page.getByRole("button", { name: "Details" });
      const attachment = page.locator(".composer .attachment-button");
      const send = page.locator(".composer .send-button");

      await expectMinimumTarget(back, "conversation back control");
      await expectMinimumTarget(startAudio, "audio-call control");
      await expectMinimumTarget(startVideo, "video-call control");
      await expectMinimumTarget(details, "conversation details control");
      await expectMinimumTarget(attachment, "attachment control");
      await expectMinimumTarget(send, "send control");
      await expectNoDocumentOverflow(page);
      await expect.poll(() => fixture.readCursorRequests).toBeGreaterThan(0);

      await back.click();
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(conversation).toBeVisible();
      await expect(conversation).toBeFocused();

      const mobileNavigation = page.getByRole("navigation", { name: "Mobile product areas" });
      await mobileNavigation.getByRole("link", { name: "Settings" }).click();
      await expect(page.getByRole("heading", { name: "Profile and settings" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
      await expectNoDocumentOverflow(page);

      await mobileNavigation.getByRole("link", { name: "Admin" }).click();
      await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Tenant settings" })).toBeVisible();
      await expectNoDocumentOverflow(page);

      await mobileNavigation.getByRole("link", { name: "Ops" }).click();
      await expect(page.getByRole("heading", { name: "Service operations" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Operations triage" })).toBeVisible();
      await expectNoDocumentOverflow(page);
      expect(fixture.unexpectedRequests).toEqual([]);
    });
  }

  test("phone sign-in keeps the form above the fold", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.route("**/api/v1/status", (route) => json(route, {
      service: "k-comms",
      version: "0.3.0",
      status: "operational",
      node: "mobile-test@node",
      capabilities: { bootstrap: false }
    }));

    await page.goto("/app/");
    const heading = page.getByRole("heading", { name: "Sign in to your workspace" });
    const workspace = page.getByRole("textbox", { name: "Workspace slug" });
    await expect(heading).toBeVisible();
    await expect(workspace).toBeVisible();

    const headingBox = await heading.boundingBox();
    const workspaceBox = await workspace.boundingBox();
    expect(headingBox).not.toBeNull();
    expect(workspaceBox).not.toBeNull();
    expect(headingBox!.y).toBeLessThan(320);
    expect(workspaceBox!.y + workspaceBox!.height).toBeLessThanOrEqual(844);
    await expectNoDocumentOverflow(page);
  });

  test("video prejoin remains contained or independently scrollable on a short phone", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 640 });
    const fixture = await installWorkspace(page);
    await page.goto(`/app/?conversation=${conversationId}`);

    await page.getByRole("button", { name: "Start video call" }).click();
    const dialog = page.getByRole("dialog", { name: "Start a video call" });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("checkbox", { name: "Use microphone when I join" })).toBeVisible();
    await expect(dialog.getByRole("checkbox", { name: "Use camera when I join" })).toBeVisible();
    await expect(dialog.getByRole("combobox", { name: /^Microphone/ })).toBeAttached();
    await expect(dialog.getByRole("combobox", { name: /^Camera/ })).toBeAttached();

    const containment = await dialog.evaluate((element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      const fits = rect.top >= -1 && rect.bottom <= window.innerHeight + 1;
      const scrollable = ["auto", "scroll"].includes(style.overflowY)
        && element.scrollHeight > element.clientHeight;
      return {
        fits,
        horizontallyContained: rect.left >= -1 && rect.right <= window.innerWidth + 1,
        scrollable
      };
    });

    expect(containment.horizontallyContained).toBe(true);
    expect(containment.fits || containment.scrollable).toBe(true);
    await expectNoDocumentOverflow(page);

    await dialog.getByRole("button", { name: "Cancel" }).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Start video call" })).toBeFocused();
    expect(fixture.unexpectedRequests).toEqual([]);
  });
});

async function installWorkspace(page: Page) {
  const state = { readCursorRequests: 0, unexpectedRequests: [] as string[] };
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3_600,
    received_at: Date.now(),
    tenant: { id: tenantId, name: "Acme Workspace", slug: "acme", status: "active" },
    user: {
      id: userId,
      tenant_id: tenantId,
      display_name: "Ada Lovelace",
      email: "ada@example.test",
      account_type: "human",
      role: "owner",
      platform_role: "platform_operator",
      platform_role_expires_at: "2099-01-01T00:00:00Z",
      status: "active",
      version: 1
    },
    device: {
      id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      user_id: userId,
      name: "Mobile browser",
      platform: "web",
      last_seen_at: "2026-07-15T12:00:00Z"
    }
  };
  const conversation = {
    id: conversationId,
    tenant_id: tenantId,
    kind: "channel",
    title: "General",
    visibility: "tenant",
    latest_sequence: 1,
    last_read_sequence: 0,
    unread_count: 1,
    version: 1,
    inserted_at: "2026-07-15T12:00:00Z",
    updated_at: "2026-07-15T12:00:00Z"
  };
  const message = {
    id: messageId,
    tenant_id: tenantId,
    conversation_id: conversationId,
    sender_user_id: userId,
    sender_device_id: session.device.id,
    client_message_id: "mobile-message-1",
    conversation_sequence: 1,
    body: "Mobile-ready message body",
    metadata: {},
    status: "active",
    thread_root_message_id: null,
    thread_reply_count: 0,
    mentioned_user_ids: [],
    inserted_at: "2026-07-15T12:00:00Z",
    attachments: [],
    reactions: []
  };
  const capabilities = {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_public_channels: true,
    message_edit_window_seconds: 900,
    max_attachment_bytes: 25_000_000
  };

  await page.addInitScript(({ storedSession, onboardingKey }) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(storedSession));
    localStorage.setItem(onboardingKey, "dismissed");
  }, {
    storedSession: session,
    onboardingKey: `k-comms:onboarding:${tenantId}:${userId}`
  });

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (method === "GET" && path === "/api/v1/me") {
      return json(route, { tenant: session.tenant, user: session.user, device: session.device, capabilities });
    }
    if (method === "GET" && path === "/api/v1/status") {
      return json(route, {
        service: "k-comms",
        version: "0.3.0",
        status: "operational",
        node: "mobile-test@node",
        capabilities: {
          administration: true,
          audio_calls: true,
          video_calls: true,
          attachment_scanning: true,
          bootstrap: false,
          notifications: true,
          push_notifications: false,
          realtime: false,
          webhooks: true
        }
      });
    }
    if (method === "GET" && path === "/api/v1/users") return json(route, { data: [session.user] });
    if (method === "GET" && path === "/api/v1/conversations") return json(route, { data: [conversation] });
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/members`) {
      return json(route, { data: [{ id: "membership-1", role: "owner", joined_at: "2026-07-15T12:00:00Z", last_read_sequence: 0, user: session.user }] });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/messages`) {
      return json(route, { data: [message], page: { has_more: false, next_after_sequence: null, reset_required: false } });
    }
    if (method === "PUT" && path === `/api/v1/conversations/${conversationId}/read-cursor`) {
      state.readCursorRequests += 1;
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/call`) return json(route, { data: null });
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } });
    }
    if (method === "GET" && path === "/api/v1/me/devices") return json(route, { data: [session.device] });
    if (method === "GET" && path === "/api/v1/me/sessions") {
      return json(route, { data: [{ id: "session-1", user_id: userId, device_id: session.device.id, expires_at: "2099-01-01T00:00:00Z", last_used_at: "2026-07-15T12:00:00Z", revoked_at: null, inserted_at: "2026-07-15T12:00:00Z" }] });
    }
    if (method === "GET" && path === "/api/v1/notification-preferences") {
      return json(route, { data: { email_enabled: true, push_enabled: false, in_app_enabled: true, muted_event_types: [], updated_at: "2026-07-15T12:00:00Z" } });
    }
    if (method === "GET" && path === "/api/v1/notifications") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/notification-attempts") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/me/push-subscriptions/config") return json(route, { data: { available: false } });
    if (method === "GET" && path === "/api/v1/me/push-subscriptions") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/admin/tenant") return json(route, { data: tenantAdministration(session.tenant) });
    if (method === "GET" && path === "/api/v1/admin/invitations") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/platform/ops") return json(route, { data: operationsSnapshot() });
    if (method === "DELETE" && path === "/api/v1/sessions/current") return route.fulfill({ status: 204 });

    state.unexpectedRequests.push(`${method} ${path}`);
    return json(route, { error: { code: "unexpected_mobile_test_request", detail: `${method} ${path}` } }, 501);
  });

  return state;
}

async function installDeterministicMediaDevices(page: Page) {
  await page.addInitScript(() => {
    if (!navigator.mediaDevices) return;
    const devices = [
      { deviceId: "microphone-1", groupId: "mobile-test", kind: "audioinput", label: "Test microphone", toJSON() { return this; } },
      { deviceId: "camera-1", groupId: "mobile-test", kind: "videoinput", label: "Test camera", toJSON() { return this; } }
    ];
    Object.defineProperty(navigator.mediaDevices, "enumerateDevices", {
      configurable: true,
      value: async () => devices
    });
  });
}

async function expectNoDocumentOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => Math.max(
    document.documentElement.scrollWidth,
    document.body.scrollWidth
  ) - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
}

async function expectMinimumTarget(locator: Locator, label: string) {
  await expect(locator, `${label} should be visible`).toBeVisible();
  const box = await locator.boundingBox();
  expect(box, `${label} should have a rendered box`).not.toBeNull();
  expect(box!.width, `${label} width`).toBeGreaterThanOrEqual(44);
  expect(box!.height, `${label} height`).toBeGreaterThanOrEqual(44);
}

async function expectMinimumTargets(locator: Locator, label: string) {
  const boxes = await locator.evaluateAll((elements) => elements
    .filter((element) => element.getClientRects().length > 0)
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return { width: rect.width, height: rect.height, text: element.textContent?.trim() || element.getAttribute("aria-label") || "control" };
    }));
  expect(boxes.length, `${label} should expose visible controls`).toBeGreaterThan(0);
  for (const box of boxes) {
    expect(box.width, `${label} ${box.text} width`).toBeGreaterThanOrEqual(44);
    expect(box.height, `${label} ${box.text} height`).toBeGreaterThanOrEqual(44);
  }
}

function tenantAdministration(tenant: Record<string, unknown>) {
  const limits = { max_active_users: 500, max_active_conversations: 2_000, max_conversation_members: 250 };
  const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
  return {
    tenant,
    settings: {
      tenant_id: tenantId,
      allow_audio_calls: true,
      allow_video_calls: true,
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

function operationsSnapshot() {
  return {
    generated_at: "2026-07-15T12:00:00Z",
    release_revision: "a".repeat(40),
    database: { status: "ready" },
    outbox: { pending: 0, published: 12 },
    notifications: {},
    webhooks: {},
    attachments: {},
    queues: [],
    providers: { notifications: { status: "ready" }, webhooks: { status: "ready" }, attachment_scanner: { status: "ready" } }
  };
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, json: body });
}
