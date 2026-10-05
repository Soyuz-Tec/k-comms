import type { Page } from "@playwright/test";
import { expect, mockServiceStatus, test } from "./fixtures";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const deviceId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const conversationId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const messageId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

async function workspace(page: Page) {
  const session = { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600, received_at: Date.now(),
    tenant: { id: tenantId, name: "Content workspace", slug: "content", status: "active" },
    user: { id: userId, tenant_id: tenantId, display_name: "Content Owner", email: "owner@example.test", account_type: "human", access_scope: "workspace", role: "owner", platform_role: null, status: "active", version: 1 },
    device: { id: deviceId, user_id: userId, name: "Browser", platform: "web" } };
  const conversation = { id: conversationId, tenant_id: tenantId, kind: "group", title: "Planning", membership_role: "owner", visibility: "private", latest_sequence: 1, unread_count: 0, archived_at: null, version: 1, inserted_at: "2026-10-04T12:00:00Z", updated_at: "2026-10-04T12:00:00Z" };
  const message = { id: messageId, tenant_id: tenantId, conversation_id: conversationId, sender_user_id: userId, sender_device_id: deviceId, client_message_id: "content-e2e-source", conversation_sequence: 1, body: "**Planning** notes", metadata: {}, status: "active", inserted_at: "2026-10-04T12:00:00Z", attachments: [], reactions: [], thread_reply_count: 0, mentioned_user_ids: [] };
  let saved = false; let version = 0; let draftBody = "";
  const checkpoints: Array<{ id: string; label: string; through_sequence: number; actor_user_id: string; inserted_at: string }> = [];
  await page.addInitScript(value => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value));
    localStorage.setItem(`k-comms:onboarding:${value.tenant.id}:${value.user.id}`, "dismissed");
  }, session);
  await page.route("**/api/v1/**", async route => {
    const url = new URL(route.request().url()); const path = url.pathname; const method = route.request().method();
    if (method === "GET" && path === "/api/v1/me/workspace") return route.fallback();
    if (path === "/api/v1/status") return route.fulfill({ json: mockServiceStatus() });
    if (path === "/api/v1/me") return route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device, capabilities: { allow_audio_calls: true, allow_video_calls: true, allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 } } });
    if (path === "/api/v1/users") return route.fulfill({ json: { data: [session.user] } });
    if (path === "/api/v1/conversations") return route.fulfill({ json: { data: [conversation] } });
    if (path.endsWith("/members")) return route.fulfill({ json: { data: [] } });
    if (path.endsWith("/messages")) return route.fulfill({ json: { data: [message], page: { has_more: false, next_after_sequence: 1, reset_required: false } } });
    if (path.includes("/saved-items/")) { saved = method === "PUT"; return route.fulfill({ json: { data: { message_id: messageId, saved } } }); }
    if (path === "/api/v1/saved-items") return route.fulfill({ json: { data: saved ? [message] : [], page: { truncated: false } } });
    if (path.endsWith("/draft")) {
      if (method === "PUT") { const input = route.request().postDataJSON(); expect(input.expected_version).toBe(version); draftBody = input.body; version += 1; }
      return route.fulfill({ json: { data: { conversation_id: conversationId, thread_key: "main", body: draftBody, version, expires_at: "2026-11-04T12:00:00Z" } } });
    }
    if (path === "/api/v1/search/unified") return route.fulfill({ json: { data: [{ id: "board", kind: "whiteboard", title: "Planning board", excerpt: "Quarterly plan", conversation_id: conversationId, occurred_at: "2026-10-04T12:00:00Z", score: 100, path: `/app/whiteboard?conversation=${conversationId}` }], facets: { whiteboard: 1 }, page: { has_more: false, next_cursor: null, source_limits: { messages: true, files: false, whiteboards: false, meetings: false, artifacts: false }, ranking_scope: "authorized_source_candidates", meeting_window_days: 732 } } });
    if (path === "/api/v1/whiteboards") return route.fulfill({ json: { data: [{ id: "board", conversation_id: conversationId, title: "Planning board", sequence: 1, library_version: 1, updated_at: "2026-10-04T12:00:00Z" }], page: { truncated: false } } });
    if (path.endsWith("/whiteboard/operations")) return route.fulfill({ json: { data: [], snapshot: { elements: [], through_sequence: 1 }, page: { has_more: false, next_after_sequence: 1 } } });
    if (path.endsWith("/whiteboard/versions")) {
      if (method === "POST") { const input = route.request().postDataJSON(); expect(input.expected_sequence).toBe(1); checkpoints.push({ id: "version-1", label: input.label, through_sequence: 1, actor_user_id: userId, inserted_at: "2026-10-04T12:00:00Z" }); return route.fulfill({ status: 201, json: { data: checkpoints[0] } }); }
      return route.fulfill({ json: { data: checkpoints } });
    }
    if (path.endsWith("/whiteboard/export")) return route.fulfill({ json: { data: { type: "excalidraw", version: 2, source: "K-Comms", title: "Planning board", library_version: 1, through_sequence: 1, elements: [], assets: [], files: {} } } });
    if (path === "/api/v1/in-app-notifications") return route.fulfill({ json: { data: [], page: { has_more: false, next_cursor: null }, meta: { unread_count: 0 } } });
    if (path === "/api/v1/telephony/config") return route.fulfill({ json: { data: { enabled: false, configured: false, provider: "livekit_sip", number: null, can_manage: false } } });
    return route.fulfill({ json: { data: [], page: { has_more: false, next_cursor: null } } });
  });
  return { draft: () => draftBody };
}

test("saved messages follow actual save and remove actions", async ({ page }) => {
  await workspace(page); await page.goto(`/app/?conversation=${conversationId}`);
  const message = page.locator(`#message-${messageId}`);
  await expect(message).toBeVisible();
  if (await message.getByRole("button", { name: "Save message", exact: true }).isHidden()) await message.getByRole("button", { name: "More message actions" }).click();
  await message.getByRole("button", { name: "Save message", exact: true }).click();
  await page.goto("/app/saved"); await expect(page.getByRole("heading", { name: "Saved items" })).toBeVisible();
  await expect(page.getByRole("link", { name: /Planning.*notes/ })).toBeVisible();
  await page.getByRole("button", { name: "Remove saved message 1" }).click();
  await expect(page.getByText(/No saved messages yet/)).toBeVisible();
});

test("unified search discloses bounded candidates and opens the actual board", async ({ page }) => {
  await workspace(page); await page.goto("/app/?search=content");
  const search = page.getByRole("dialog", { name: "Search workspace", exact: true });
  await search.getByRole("searchbox").fill("plan"); await search.getByRole("button", { name: "Search", exact: true }).click();
  await expect(search.getByText(/Some sources reached their result limit/)).toBeVisible();
  await search.getByRole("link", { name: /Planning board/ }).click();
  await expect(page).toHaveURL(new RegExp(`/app/whiteboard\\?conversation=${conversationId}`));
});

test("board gallery opens owned context and saves a durable checkpoint", async ({ page }) => {
  await workspace(page); await page.goto(`/app/whiteboard?conversation=${conversationId}`);
  await page.getByRole("button", { name: "Board gallery" }).click();
  await page.getByRole("button", { name: /Planning board/ }).click();
  await page.getByRole("button", { name: "Board history & assets" }).click();
  await page.getByLabel("Checkpoint name").fill("Before review");
  await page.getByRole("button", { name: "Save checkpoint" }).click();
  await expect(page.getByText("Board checkpoint saved.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Restore Before review" })).toBeVisible();
});
