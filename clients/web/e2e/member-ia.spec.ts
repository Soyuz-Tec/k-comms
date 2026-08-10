import { expect as baseExpect, mockServiceStatus, test } from "./fixtures";
import type { Locator, Page, Route } from "@playwright/test";

const expect = baseExpect.configure({ timeout: 12_000 });
const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const directConversationId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const directoryPersonId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const publicRoomId = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const sourceMessageId = "11111111-1111-4111-8111-111111111111";

test.describe("low-click member information architecture", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name === "mobile-chromium",
      "explicit phone-width journeys run once per desktop browser engine"
    );
    await installDeterministicMediaDevices(page);
  });

  for (const width of [320, 390]) {
    test(`${width}px reflows every primary member route without horizontal overflow`, async ({ page }, testInfo) => {
      await page.setViewportSize({ width, height: 844 });
      const fixture = await installWorkspace(page);

      for (const route of [
        { path: "/app/", heading: "Inbox" },
        { path: "/app/calls", heading: "Calls" },
        { path: "/app/directory", heading: "Directory" },
        { path: "/app/files", heading: "Files" },
        { path: "/app/you", heading: "You" }
      ]) {
        await page.goto(route.path);
        await expect(page.getByRole("heading", { name: route.heading, exact: true })).toBeVisible();
        await expectNoDocumentOverflow(page);
        await expectMinimumTargets(
          page.getByRole("button", { name: "Open more menu" }),
          `${route.heading} more menu control`
        );
        await expect(page.getByRole("navigation", { name: "Primary navigation" }).locator("a"))
          .toHaveCount(5);
        if (
          process.env.K_COMMS_VISUAL_CAPTURE === "1"
          && width === 390
          && ["/app/calls", "/app/directory", "/app/files", "/app/you"].includes(route.path)
        ) {
          const routeName = route.path.split("/").filter(Boolean).at(-1) || "inbox";
          await page.screenshot({
            path: testInfo.outputPath(`${routeName}-390.png`),
            fullPage: true
          });
        }
      }

      expect(fixture.unexpectedRequests).toEqual([]);
    });
  }

  test("a direct message starts from Inbox in no more than two actions", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page);
    await page.goto("/app/");

    let actions = 0;
    await countedClick(
      page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "Directory" }),
      () => actions += 1
    );
    await expect(page.getByRole("heading", { name: "Directory" })).toBeVisible();
    await countedClick(
      page.getByRole("button", { name: "Message Grace Hopper" }),
      () => actions += 1
    );

    await expect(page).toHaveURL(new RegExp(`conversation=${directConversationId}`));
    await expect(page.getByRole("heading", { name: "Grace Hopper" })).toBeVisible();
    expect(actions).toBe(2);
    expect(actions).toBeLessThanOrEqual(2);
    expect(fixture.directConversationRequests).toBe(1);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("a public room joins and opens from Inbox in no more than three actions", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page);
    await page.goto("/app/");

    let actions = 0;
    await countedClick(
      page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "Directory" }),
      () => actions += 1
    );
    await expect(page.getByRole("button", { name: "People" })).toHaveAttribute("aria-pressed", "true");
    const roomsButton = page.getByRole("button", { name: "Rooms" });
    await countedClick(roomsButton, () => actions += 1);
    await expect(roomsButton).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("button", { name: "Join & open Execution room" })).toBeVisible();
    await countedClick(
      page.getByRole("button", { name: "Join & open Execution room" }),
      () => actions += 1
    );

    await expect(page).toHaveURL(new RegExp(`conversation=${publicRoomId}`));
    await expect(page.getByRole("heading", { name: "Execution room" })).toBeVisible();
    expect(actions).toBe(3);
    expect(actions).toBeLessThanOrEqual(3);
    expect(fixture.joinRoomRequests).toBe(1);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("a shared file returns to its exact source message in two actions", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page);
    await page.goto("/app/");

    let actions = 0;
    await countedClick(
      page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "Files" }),
      () => actions += 1
    );
    await expect(page.getByRole("button", { name: "All" })).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("button", { name: "Documents" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Images" })).toBeVisible();
    await expect(page.getByText("Quarterly-plan.pdf", { exact: true })).toBeVisible();
    await countedClick(
      page.getByRole("link", { name: "View source message for Quarterly-plan.pdf" }),
      () => actions += 1
    );

    await expect(page).toHaveURL(new RegExp(`search_message=${sourceMessageId}`));
    await expect(page.getByText("The source message for the shared plan.", { exact: true })).toBeVisible();
    expect(actions).toBe(2);
    expect(actions).toBeLessThanOrEqual(2);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("a video call starts in three actions with an explicit default-off join", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page);
    await page.goto("/app/");

    let actions = 0;
    await countedClick(
      page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "Calls" }),
      () => actions += 1
    );
    await expect(page.getByRole("heading", { name: "Start from a conversation" })).toBeVisible();
    await countedClick(page.getByRole("button", { name: "Video" }), () => actions += 1);

    const dialog = page.getByRole("dialog", { name: "Start a video call" });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("checkbox", { name: "Use microphone when I join" })).not.toBeChecked();
    await expect(dialog.getByRole("checkbox", { name: "Use camera when I join" })).not.toBeChecked();
    await countedClick(
      dialog.getByRole("button", { name: "Join video call" }),
      () => actions += 1
    );
    await expect(page.getByRole("alert")).toContainText("Unable to join the video call");
    expect(actions).toBe(3);
    expect(actions).toBeLessThanOrEqual(3);
    expect(fixture.startCallRequests).toBe(1);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("You and role tools are each no more than two actions from Inbox", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page);
    await page.goto("/app/");

    let actions = 0;
    await countedClick(
      page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "You" }),
      () => actions += 1
    );
    await expect(page.getByRole("heading", { name: "You" })).toBeVisible();
    expect(actions).toBe(1);
    expect(actions).toBeLessThanOrEqual(1);

    await page.goto("/app/");
    actions = 0;
    let menu = await openMoreMenu(page, () => actions += 1);
    await countedClick(menu.getByRole("link", { name: "Workspace administration" }), () => actions += 1);
    await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
    expect(actions).toBe(2);
    expect(actions).toBeLessThanOrEqual(2);

    await page.goto("/app/");
    actions = 0;
    menu = await openMoreMenu(page, () => actions += 1);
    await countedClick(menu.getByRole("link", { name: "Service operations" }), () => actions += 1);
    await expect(page.getByRole("heading", { name: "Operations triage" })).toBeVisible();
    expect(actions).toBe(2);
    expect(actions).toBeLessThanOrEqual(2);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("a first-run owner reaches the invitation form in one action", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page, { firstRun: true });
    await page.goto("/app/");

    let actions = 0;
    const invitationLink = page.getByRole("link", { name: "Invite your first teammate" });
    await expect(invitationLink).toBeVisible();
    await countedClick(invitationLink, () => actions += 1);

    await expect(page).toHaveURL(/\/admin\?section=people#admin-invitations$/);
    const invitationHeading = page.getByRole("heading", { name: "Invitations" });
    await expect(invitationHeading).toBeVisible();
    await expect(invitationHeading).toBeFocused();
    await expectInViewport(invitationHeading);
    expect(actions).toBe(1);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("onboarding starts a known-teammate message in one action", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page, {
      showOnboarding: true,
      emptyConversations: true
    });
    await page.goto("/app/");

    let actions = 0;
    const messageButton = page.getByRole("button", { name: "Message Grace Hopper" });
    await expect(messageButton).toBeVisible();
    await countedClick(messageButton, () => actions += 1);

    await expect(page).toHaveURL(new RegExp(`conversation=${directConversationId}`));
    expect(fixture.directConversationRequests).toBe(1);
    expect(actions).toBe(1);
    expect(fixture.unexpectedRequests).toEqual([]);
  });
});

async function installWorkspace(
  page: Page,
  options: {
    firstRun?: boolean;
    showOnboarding?: boolean;
    emptyConversations?: boolean;
  } = {}
) {
  const firstRun = options.firstRun === true;
  const emptyConversations = options.emptyConversations === true;
  const dismissOnboarding = !firstRun && options.showOnboarding !== true;
  const state = {
    directConversationRequests: 0,
    joinRoomRequests: 0,
    startCallRequests: 0,
    unexpectedRequests: [] as string[]
  };
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
      id: "22222222-2222-4222-8222-222222222222",
      user_id: userId,
      name: "Mobile browser",
      platform: "web",
      last_seen_at: "2026-07-24T12:00:00Z"
    }
  };
  const general = conversation(conversationId, "channel", "General", "tenant");
  const direct = conversation(directConversationId, "direct", "Grace Hopper", "private");
  const publicRoom = {
    ...conversation(publicRoomId, "channel", "Execution room", "tenant"),
    joined: false,
    member_count: 12,
    membership: null
  };
  const sourceMessage = {
    id: sourceMessageId,
    tenant_id: tenantId,
    conversation_id: conversationId,
    sender_user_id: userId,
    sender_device_id: session.device.id,
    client_message_id: "source-message-1",
    conversation_sequence: 7,
    body: "The source message for the shared plan.",
    metadata: {},
    status: "active",
    thread_root_message_id: null,
    thread_reply_count: 0,
    mentioned_user_ids: [],
    inserted_at: "2026-07-24T12:00:00Z",
    attachments: [],
    reactions: []
  };
  const membership = {
    id: "33333333-3333-4333-8333-333333333333",
    role: "member",
    joined_at: "2026-07-24T12:00:00Z",
    left_at: null,
    last_read_sequence: 0,
    version: 1
  };
  const capabilities = {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_public_channels: true,
    message_edit_window_seconds: 900,
    max_attachment_bytes: 25_000_000
  };

  await page.addInitScript(({ storedSession, onboardingKey, shouldDismissOnboarding }) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(storedSession));
    if (shouldDismissOnboarding) localStorage.setItem(onboardingKey, "dismissed");
    else localStorage.removeItem(onboardingKey);
  }, {
    storedSession: session,
    onboardingKey: `k-comms:onboarding:${tenantId}:${userId}`,
    shouldDismissOnboarding: dismissOnboarding
  });

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (method === "GET" && path === "/api/v1/me") {
      return json(route, {
        tenant: session.tenant,
        user: session.user,
        device: session.device,
        capabilities
      });
    }
    if (method === "GET" && path === "/api/v1/status") {
      return json(route, mockServiceStatus({
        push_notifications: false,
        realtime: false
      }));
    }
    if (method === "GET" && path === "/api/v1/users") {
      return json(route, {
        data: firstRun ? [session.user] : [
          session.user,
          {
            id: directoryPersonId,
            tenant_id: tenantId,
            display_name: "Grace Hopper",
            email: "grace@example.test",
            role: "member",
            status: "active"
          }
        ]
      });
    }
    if (method === "GET" && path === "/api/v1/directory/users") {
      return json(route, {
        data: firstRun ? [] : [{ id: directoryPersonId, display_name: "Grace Hopper" }],
        page: { next_cursor: null }
      });
    }
    if (method === "POST" && path === "/api/v1/direct-conversations") {
      state.directConversationRequests += 1;
      return json(route, { data: direct, created: false });
    }
    if (method === "GET" && path === "/api/v1/channels/discover") {
      return json(route, {
        data: [publicRoom],
        page: { limit: 25, has_more: false, next_cursor: null }
      });
    }
    if (method === "POST" && path === `/api/v1/channels/${publicRoomId}/join`) {
      state.joinRoomRequests += 1;
      return json(route, {
        data: {
          conversation: publicRoom,
          membership
        },
        replayed: false
      });
    }
    if (method === "GET" && path === "/api/v1/conversations") {
      return json(route, { data: emptyConversations ? [] : [general] });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/members$/.test(path)) {
      return json(route, { data: [] });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/messages$/.test(path)) {
      return json(route, {
        data: path.includes(conversationId) ? [sourceMessage] : [],
        page: { has_more: false, next_after_sequence: null, reset_required: false }
      });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/delivery-cursors$/.test(path)) {
      return json(route, { data: [] });
    }
    if (method === "PUT" && /^\/api\/v1\/conversations\/[^/]+\/delivery-cursor$/.test(path)) {
      return json(route, { data: deliveryCursor(userId) });
    }
    if (method === "PUT" && /^\/api\/v1\/conversations\/[^/]+\/read-cursor$/.test(path)) {
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/call$/.test(path)) {
      return json(route, { data: null });
    }
    if (method === "POST" && path === `/api/v1/conversations/${conversationId}/calls`) {
      state.startCallRequests += 1;
      return json(route, {
        error: {
          code: "media_test_boundary",
          detail: "The mocked IA receipt stops after proving the explicit join action."
        }
      }, 503);
    }
    if (method === "GET" && path === "/api/v1/calls") {
      return json(route, {
        data: [],
        page: { limit: 25, has_more: false, next_cursor: null }
      });
    }
    if (method === "GET" && path === "/api/v1/files") {
      return json(route, {
        data: [{
          id: "44444444-4444-4444-8444-444444444444",
          conversation_id: conversationId,
          message_id: sourceMessageId,
          conversation_sequence: 7,
          owner_user_id: userId,
          file_name: "Quarterly-plan.pdf",
          content_type: "application/pdf",
          byte_size: 2_048,
          status: "ready",
          scan_status: "clean",
          safety_state: "available",
          downloadable: true,
          uploaded_at: "2026-07-24T12:00:00Z",
          shared_at: "2026-07-24T12:00:00Z",
          inserted_at: "2026-07-24T12:00:00Z",
          updated_at: "2026-07-24T12:00:00Z"
        }],
        page: { limit: 25, has_more: false, next_cursor: null }
      });
    }
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, {
        data: [],
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: 0 }
      });
    }
    if (method === "GET" && path === "/api/v1/socket-ticket") {
      return json(route, { ticket: "test-ticket", expires_in: 60 });
    }
    if (method === "GET" && path === "/api/v1/me/devices") {
      return json(route, { data: [session.device] });
    }
    if (method === "GET" && path === "/api/v1/me/sessions") {
      return json(route, { data: [] });
    }
    if (method === "GET" && path === "/api/v1/notification-preferences") {
      return json(route, {
        data: {
          email_enabled: true,
          push_enabled: false,
          in_app_enabled: true,
          muted_event_types: [],
          updated_at: "2026-07-24T12:00:00Z"
        }
      });
    }
    if (method === "GET" && path === "/api/v1/notifications") {
      return json(route, { data: [] });
    }
    if (method === "GET" && path === "/api/v1/notification-attempts") {
      return json(route, { data: [] });
    }
    if (method === "GET" && path === "/api/v1/me/push-subscriptions/config") {
      return json(route, { data: { available: false } });
    }
    if (method === "GET" && path === "/api/v1/me/push-subscriptions") {
      return json(route, { data: [] });
    }
    if (method === "GET" && path === "/api/v1/admin/tenant") {
      return json(route, { data: tenantAdministration(session.tenant) });
    }
    if (method === "GET" && path === "/api/v1/admin/invitations") {
      return json(route, { data: [] });
    }
    if (method === "GET" && path === "/api/v1/platform/ops") {
      return json(route, { data: operationsSnapshot() });
    }

    state.unexpectedRequests.push(`${method} ${path}`);
    return json(
      route,
      {
        error: {
          code: "unexpected_member_ia_test_request",
          detail: `${method} ${path}`
        }
      },
      501
    );
  });

  return state;
}

function deliveryCursor(recipientUserId: string) {
  return { recipient_user_id: recipientUserId, device_ref: "test-device", delivered_sequence: 7, read_sequence: 0, delivered_at: "2026-07-24T12:00:00Z", read_at: null };
}

async function installDeterministicMediaDevices(page: Page) {
  await page.addInitScript(() => {
    if (!navigator.mediaDevices) return;
    const devices = [
      {
        deviceId: "microphone-1",
        groupId: "ia-test",
        kind: "audioinput",
        label: "Test microphone",
        toJSON() { return this; }
      },
      {
        deviceId: "camera-1",
        groupId: "ia-test",
        kind: "videoinput",
        label: "Test camera",
        toJSON() { return this; }
      }
    ];
    Object.defineProperty(navigator.mediaDevices, "enumerateDevices", {
      configurable: true,
      value: async () => devices
    });
  });
}

async function countedClick(locator: Locator, count: () => void) {
  await expect(locator).toBeVisible();
  await locator.click();
  count();
}

async function openMoreMenu(page: Page, count: () => void) {
  await countedClick(page.getByRole("button", { name: "Open more menu" }), count);
  const menu = page.getByRole("dialog", { name: "More" });
  await expect(menu).toBeVisible();
  return menu;
}

async function expectNoDocumentOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => Math.max(
    document.documentElement.scrollWidth,
    document.body.scrollWidth
  ) - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
}

async function expectMinimumTargets(locator: Locator, label: string) {
  const boxes = await locator.evaluateAll((elements) => elements
    .filter((element) => element.getClientRects().length > 0)
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        width: rect.width,
        height: rect.height,
        text: element.textContent?.trim() || element.getAttribute("aria-label") || "control"
      };
    }));
  expect(boxes.length, `${label} should expose visible controls`).toBeGreaterThan(0);
  for (const box of boxes) {
    expect(box.width, `${label} ${box.text} width`).toBeGreaterThanOrEqual(44);
    expect(box.height, `${label} ${box.text} height`).toBeGreaterThanOrEqual(44);
  }
}

async function expectInViewport(locator: Locator) {
  await expect.poll(async () => {
    const box = await locator.boundingBox();
    if (!box) return false;
    return box.y >= -1 && box.y + box.height <= 845;
  }).toBe(true);
}

function conversation(
  id: string,
  kind: "direct" | "group" | "channel",
  title: string,
  visibility: "private" | "tenant"
) {
  return {
    id,
    tenant_id: tenantId,
    kind,
    title,
    counterpart_display_name: kind === "direct" ? title : null,
    visibility,
    latest_sequence: id === conversationId ? 7 : 0,
    last_read_sequence: 0,
    unread_count: id === conversationId ? 1 : 0,
    version: 1,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z"
  };
}

function tenantAdministration(tenant: Record<string, unknown>) {
  const limits = {
    max_active_users: 500,
    max_active_conversations: 2_000,
    max_conversation_members: 250
  };
  const flags = {
    active_users: false,
    active_conversations: false,
    conversation_members: false,
    any: false
  };
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
    usage: {
      active_users: 2,
      active_conversations: 2,
      largest_conversation_members: 12,
      limits,
      at_capacity: flags,
      over_limit: flags
    }
  };
}

function operationsSnapshot() {
  return {
    generated_at: "2026-07-24T12:00:00Z",
    release_revision: "a".repeat(40),
    database: { status: "ready" },
    outbox: { pending: 0, published: 12 },
    notifications: {},
    webhooks: {},
    attachments: {},
    queues: [],
    providers: {
      notifications: { status: "ready" },
      webhooks: { status: "ready" },
      attachment_scanner: { status: "ready" }
    }
  };
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, json: body });
}
