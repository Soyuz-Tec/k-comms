import { expect, mockServiceStatus } from "./fixtures";
import type { Locator, Page, Route } from "@playwright/test";

export const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
export const messageId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

export const viewportCases = [
  { width: 320, height: 640 },
  { width: 390, height: 844 },
  { width: 513, height: 734 },
  { width: 700, height: 900 }
] as const;

/**
 * A joined video call in static markup, carrying the real class names so the
 * application's own stylesheets can be injected over it.
 *
 * `experienceMode` stamps the document root the way ExperienceModeProvider
 * does at runtime, which is what selects the Immersive stage rules. Omitting
 * it exercises the legacy presentation -- the fallback the contract requires
 * to stay intact.
 */
export function activeVideoFixtureMarkup(
  options: { experienceMode?: "workspace" | "immersive" } = {}
) {
  const mode = options.experienceMode
    ? ` data-experience-mode="${options.experienceMode}"`
    : "";
  return `<!doctype html>
    <html lang="en"${mode}>
      <head>
        <title>Call fixture</title>
      </head>
      <body>
        <main class="app-shell">Workspace beneath the call</main>
        <section class="call-dock audio-call-dock active-call-screen video-call-dock video-call-screen" data-call-control-labels="visible">
          <div class="audio-call-dock-heading">
            <div class="call-heading-summary">
              <h2 class="call-room-title">Instant room</h2>
              <div class="call-progress-meta">
                <span class="call-progress-duration">04:18</span>
                <span class="call-progress-separator">·</span>
                <span class="call-participant-count">1 participant</span>
              </div>
            </div>
            <div class="call-dock-heading-actions app-surface-control-cluster">
              <div class="call-placement-controls" role="group" aria-label="Call panel position">
                <button class="button ghost compact call-placement-handle" type="button" aria-label="Move call panel">${callFixtureIcon("grip")}</button>
                ${["top-left", "top-right", "bottom-left", "bottom-right"].map((corner) => `
                  <button class="button ghost compact call-placement-preset" type="button" data-corner="${corner}" aria-label="Move call panel to ${corner.replace("-", " ")}" aria-pressed="${corner === "bottom-right"}">${callFixtureIcon("arrowUpRight")}</button>
                `).join("")}
              </div>
              <button class="button ghost compact app-surface-control" type="button" aria-label="Minimize">${callFixtureIcon("minimize")}</button>
              <button class="button ghost compact app-menu-trigger app-menu-trigger-overlay" type="button" aria-label="Open call menu">${callFixtureIcon("menu")}</button>
            </div>
          </div>
          <div class="active-call-details">
            <section class="call-stage">
              <div class="video-participant-grid participant-count-1">
                <article class="video-participant-tile" data-participant-id="participant-1">
                  <div class="video-track-stack">
                    <div class="video-placeholder">
                      <span>AL</span>
                      <small>Camera off</small>
                    </div>
                  </div>
                  <div class="video-participant-caption">
                    <strong>Ada Lovelace (you)</strong>
                  </div>
                </article>
              </div>
            </section>
            <div class="audio-call-actions">
              ${["Mic", "Camera", "Screen", "People", "Leave"].map((label) => `
                <button class="button compact ${label === "Leave" ? "danger call-action-leave" : "ghost"}" type="button">
                  <span class="call-action-glyph" aria-hidden="true">${callFixtureIcon(label.toLowerCase())}</span>
                  <span class="call-action-label">${label}</span>
                </button>
              `).join("")}
            </div>
          </div>
        </section>
      </body>
    </html>`;
}

export function callFixtureIcon(name: string) {
  const paths: Record<string, string> = {
    minimize: `
      <polyline points="4 14 10 14 10 20"></polyline>
      <polyline points="20 10 14 10 14 4"></polyline>
      <line x1="14" x2="21" y1="10" y2="3"></line>
      <line x1="3" x2="10" y1="21" y2="14"></line>`,
    grip: `
      <circle cx="9" cy="6" r="1"></circle><circle cx="15" cy="6" r="1"></circle>
      <circle cx="9" cy="12" r="1"></circle><circle cx="15" cy="12" r="1"></circle>
      <circle cx="9" cy="18" r="1"></circle><circle cx="15" cy="18" r="1"></circle>`,
    arrowUpRight: `
      <path d="M7 17 17 7"></path><path d="M7 7h10v10"></path>`,
    menu: `
      <line x1="4" x2="20" y1="6" y2="6"></line>
      <line x1="4" x2="20" y1="12" y2="12"></line>
      <line x1="4" x2="20" y1="18" y2="18"></line>`,
    mic: `
      <rect x="9" y="2" width="6" height="12" rx="3"></rect>
      <path d="M5 10a7 7 0 0 0 14 0M12 17v5M8 22h8"></path>`,
    camera: `
      <rect x="3" y="6" width="13" height="12" rx="2"></rect>
      <path d="m16 10 5-3v10l-5-3z"></path>`,
    screen: `
      <rect x="2" y="3" width="20" height="14" rx="2"></rect>
      <path d="M8 21h8M12 17v4"></path>`,
    people: `
      <circle cx="9" cy="8" r="3"></circle>
      <circle cx="17" cy="9" r="2"></circle>
      <path d="M3 20a6 6 0 0 1 12 0M15 15a5 5 0 0 1 6 5"></path>`,
    leave: `
      <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 2 .7 2.8a2 2 0 0 1-.4 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z"></path>
      <path d="m2 2 20 20"></path>`
  };
  return `<svg class="app-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${paths[name] ?? ""}</svg>`;
}

export async function installWorkspace(
  page: Page,
  options: { tenantName?: string; callRunning?: boolean } = {}
) {
  const state = { readCursorRequests: 0, unexpectedRequests: [] as string[] };
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3_600,
    received_at: Date.now(),
    tenant: {
      id: tenantId,
      name: options.tenantName || "Acme Workspace",
      slug: "acme",
      status: "active"
    },
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
  const notifications = Array.from({ length: 18 }, (_, index) => ({
    id: `mobile-notification-${index + 1}`,
    event_type: "message.created.v1",
    title: `Mobile notification ${index + 1}`,
    body: `Notification body ${index + 1} verifies the scrollable phone drawer.`,
    conversation_id: conversationId,
    message_id: messageId,
    action_url: null,
    read_at: null,
    inserted_at: `2026-07-15T12:${String(index).padStart(2, "0")}:00Z`
  }));

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
      return json(route, mockServiceStatus({
        push_notifications: false,
        realtime: false
      }));
    }
    if (method === "GET" && path === "/api/v1/users") return json(route, { data: [session.user] });
    if (method === "GET" && path === "/api/v1/conversations") return json(route, { data: [conversation] });
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/members`) {
      return json(route, { data: [{ id: "membership-1", role: "owner", joined_at: "2026-07-15T12:00:00Z", last_read_sequence: 0, user: session.user }] });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/messages`) {
      return json(route, { data: [message], page: { has_more: false, next_after_sequence: null, reset_required: false } });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/delivery-cursors`) {
      return json(route, { data: [] });
    }
    if (method === "PUT" && path === `/api/v1/conversations/${conversationId}/delivery-cursor`) {
      return json(route, { data: deliveryCursor(userId) });
    }
    if (method === "PUT" && path === `/api/v1/conversations/${conversationId}/read-cursor`) {
      state.readCursorRequests += 1;
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/call`) return json(route, { data: null });
    if (method === "GET" && path === "/api/v1/calls") {
      return json(route, {
        data: options.callRunning ? [activeCall()] : [],
        page: { limit: 100, has_more: false, next_cursor: null }
      });
    }
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, {
        data: notifications,
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: notifications.length }
      });
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

function deliveryCursor(recipientUserId: string) {
  return { recipient_user_id: recipientUserId, device_ref: "test-device", delivered_sequence: 1, read_sequence: 0, delivered_at: "2026-07-15T12:00:00Z", read_at: null };
}

function activeCall() {
  return {
    id: "99999999-9999-4999-8999-999999999999",
    conversation_id: conversationId,
    started_by_user_id: userId,
    ended_by_user_id: null,
    media_kind: "video",
    status: "active",
    started_at: "2026-07-15T12:00:00Z",
    expires_at: "2026-07-15T16:00:00Z",
    ended_at: null,
    end_reason: null,
    duration_seconds: 90,
    can_end: true
  };
}

export async function installDeterministicMediaDevices(page: Page) {
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

export async function exposeInstallPrompt(page: Page) {
  // Route-mocked specs block workers; the PWA spec separately proves the real
  // worker while this event keeps the install-menu acceptance deterministic.
  await page.evaluate(() => {
    const installPrompt = new Event("beforeinstallprompt", {
      cancelable: true
    });
    Object.assign(installPrompt, {
      prompt: () => Promise.resolve(),
      userChoice: Promise.resolve({
        outcome: "dismissed",
        platform: "web"
      })
    });
    window.dispatchEvent(installPrompt);
  });
}

export async function expectNoDocumentOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => Math.max(
    document.documentElement.scrollWidth,
    document.body.scrollWidth
  ) - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
}

export async function expectNoDocumentVerticalOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => Math.max(
    document.documentElement.scrollHeight,
    document.body.scrollHeight
  ) - document.documentElement.clientHeight)).toBeLessThanOrEqual(1);
}

export async function expectNoHorizontalOverflow(locator: Locator, label: string) {
  await expect(locator, `${label} should be visible`).toBeVisible();
  const overflow = await locator.evaluate((element) => element.scrollWidth - element.clientWidth);
  expect(overflow, `${label} should not scroll horizontally`).toBeLessThanOrEqual(1);
}

export async function expectMinimumTarget(locator: Locator, label: string) {
  await expect(locator, `${label} should be visible`).toBeVisible();
  const box = await locator.boundingBox();
  expect(box, `${label} should have a rendered box`).not.toBeNull();
  expect(box!.width, `${label} width`).toBeGreaterThanOrEqual(44);
  expect(box!.height, `${label} height`).toBeGreaterThanOrEqual(44);
}

export async function expectMinimumTargets(
  locator: Locator,
  label: string,
  minimumSize = 44
) {
  const boxes = await locator.evaluateAll((elements) => elements
    .filter((element) => element.getClientRects().length > 0)
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return { width: rect.width, height: rect.height, text: element.textContent?.trim() || element.getAttribute("aria-label") || "control" };
    }));
  expect(boxes.length, `${label} should expose visible controls`).toBeGreaterThan(0);
  for (const box of boxes) {
    expect(box.width, `${label} ${box.text} width`).toBeGreaterThanOrEqual(minimumSize);
    expect(box.height, `${label} ${box.text} height`).toBeGreaterThanOrEqual(minimumSize);
  }
}

export function tenantAdministration(tenant: Record<string, unknown>) {
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

export function operationsSnapshot() {
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

export function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, json: body });
}
