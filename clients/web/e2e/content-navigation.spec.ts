import type { Page, TestInfo } from "@playwright/test";
import type { Session } from "../src/types";
import type { UnifiedResult, UnifiedSearchPage } from "../src/types/rich-content";
import { expect, test } from "./fixtures";
import {
  conversationId,
  expectNoDocumentOverflow,
  expectMinimumTargets,
  installWorkspace,
  messageId,
  tenantId,
  userId
} from "./mobile-ui-support";

const documentId = "11111111-1111-4111-8111-111111111111";
const categories = [
  { label: "Files", path: "/app/files", heading: "Files" },
  { label: "Shared documents", path: "/app/documents", heading: "Shared documents" },
  { label: "Whiteboard", path: "/app/whiteboard", heading: "Whiteboard" },
  { label: "Recordings", path: "/app/artifacts", heading: "Meeting recordings and transcripts" },
  { label: "Saved items", path: "/app/saved", heading: "Saved items" }
] as const;

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Explicit desktop and phone viewports run once per engine");
  await page.setViewportSize({ width: 1440, height: 900 });
});

async function contentWorkspace(page: Page) {
  const state = await installWorkspace(page);
  await page.route(/\/api\/v1\/files(?:\?.*)?$/, route => route.fulfill({ json: {
    data: [], page: { limit: 25, has_more: false, next_cursor: null }
  } }));
  await page.route("**/api/v1/telephony/calls?**", route => route.fulfill({ json: {
    data: [], page: { limit: 30, has_more: false, next_cursor: null }
  } }));
  await page.route("**/api/v1/telephony/voicemails?**", route => route.fulfill({ json: {
    configured: false, data: [], page: { has_more: false, next_cursor: null }
  } }));
  await page.route("**/api/v1/telephony/agent-state", route => route.fulfill({ status: 404, json: {
    error: { code: "telephony_agent_not_assigned", detail: "No queue assignment in this fixture." }
  } }));
  await page.route(`**/api/v1/conversations/${conversationId}/documents*`, route => route.fulfill({ json: { data: [{
    id: documentId, conversation_id: conversationId, title: "Project notes", excerpt: "Shared project plan",
    generation: 1, version: 1, readonly: false, updated_at: "2026-10-05T12:00:00Z"
  }] } }));
  await page.route(`**/api/v1/documents/${documentId}`, route => route.fulfill({ json: { data: {
    id: documentId, conversation_id: conversationId, title: "Project notes", content: "", atoms: [],
    generation: 1, version: 1, readonly: false, updated_at: "2026-10-05T12:00:00Z"
  } } }));
  await page.route(`**/api/v1/documents/${documentId}/operations?**`, route => route.fulfill({ json: {
    data: [], page: { generation: 1, through_version: 1, has_more: false, next_after_version: 1 }
  } }));
  await page.route("**/api/v1/socket-tickets", route => route.fulfill({ json: { ticket: "synthetic-document-ticket", expires_in: 60 } }));
  await page.routeWebSocket(/\/socket\/websocket(?:\?|$)/, socket => socket.onMessage(message => {
    const [joinRef, reference, topic, event] = JSON.parse(String(message)) as [string | null, string, string, string, unknown];
    if (["phx_join", "phx_leave", "heartbeat"].includes(event)) {
      socket.send(JSON.stringify([joinRef, reference, topic, "phx_reply", { status: "ok", response: {} }]));
    }
  }));
  await page.route(`**/api/v1/conversations/${conversationId}/messages/${messageId}/thread**`, route => route.fulfill({ json: {
    data: { root: {
      id: messageId, tenant_id: tenantId, conversation_id: conversationId,
      sender_user_id: userId, sender_device_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      client_message_id: "mobile-message-1", conversation_sequence: 1, body: "Mobile-ready message body",
      metadata: {}, status: "active", thread_root_message_id: null, thread_reply_count: 0,
      mentioned_user_ids: [], inserted_at: "2026-07-15T12:00:00Z", attachments: [], reactions: []
    }, replies: [], reply_count: 0 }, page: { has_more: false, next_before_sequence: null }
  } }));
  await page.route(`**/api/v1/conversations/${conversationId}/whiteboard/operations*`, route => route.fulfill({ json: {
    data: [], page: { has_more: false, next_after_sequence: 0 }
  } }));
  return state;
}

function searchPage(data: UnifiedResult[], nextCursor: string | null = null): UnifiedSearchPage {
  return {
    data, facets: { file: 1, whiteboard: 1 },
    page: {
      has_more: nextCursor !== null, next_cursor: nextCursor,
      source_limits: { messages: false, files: false, whiteboards: false, meetings: false, artifacts: false },
      ranking_scope: "authorized_source_candidates", meeting_window_days: 732
    }
  };
}

const fileResult: UnifiedResult = {
  id: "file-result", kind: "file", title: "Project plan.pdf", excerpt: "Shared in General",
  conversation_id: conversationId, occurred_at: "2026-10-05T12:00:00Z", score: 100,
  path: `/app/?conversation=${conversationId}&message=${messageId}`
};

async function capture(page: Page, info: TestInfo, name: string) {
  if (process.env.K_COMMS_VISUAL_CAPTURE !== "1") return;
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: info.outputPath(`${name}.png`), animations: "disabled" });
}

test("desktop Content discovers all existing tools and keeps rail destinations available", async ({ page }, info) => {
  const state = await contentWorkspace(page);
  await page.goto("/app/");
  const rail = page.getByRole("navigation", { name: "Workspace shortcuts", exact: true });
  const memberLinks = rail.locator(":scope > .desktop-activity-shortcuts").getByRole("link");
  await expect(memberLinks).toHaveCount(6);
  await rail.getByRole("link", { name: "Open Content", exact: true }).click();
  const heading = page.getByRole("heading", { name: "Content", exact: true });
  await expect(heading).toBeVisible();
  await expect(rail.getByRole("link", { name: "Open Content", exact: true })).toHaveAttribute("aria-current", "page");
  const browse = page.getByRole("navigation", { name: "Browse content", exact: true });
  const tools = page.getByRole("navigation", { name: "Workspace tools", exact: true });
  await expect(tools.getByRole("region", { name: "Content library", exact: true }).getByRole("link")).toHaveText(categories.map(category => category.label));
  await expectMinimumTargets(browse.getByRole("link"), "Content categories");
  const search = page.locator(".content-search");
  await expectMinimumTargets(search.getByRole("searchbox").or(search.getByRole("combobox")).or(search.getByRole("button")), "Content search controls");
  await expectNoDocumentOverflow(page);
  await capture(page, info, "desktop-content");
  for (const category of categories) {
    const categoryLink = browse.getByRole("link", { name: new RegExp(`^${category.label}\\b`) });
    await expect(categoryLink).toHaveAttribute("href", category.path);
    await categoryLink.click();
    await expect(page).toHaveURL(category.path);
    await expect(page.getByRole("heading", { name: category.heading, exact: true })).toBeVisible();
    await expect(page.locator("#main-content").getByRole("link", { name: "Content", exact: true })).toHaveAttribute("href", "/app/content");
    await expect(tools.getByRole("link", { name: category.label, exact: true })).toHaveAttribute("aria-current", "page");
    const currentRail = category.label === "Files" ? "Open Files" : "Open Content";
    await expect(rail.getByRole("link", { name: currentRail, exact: true })).toHaveAttribute("aria-current", "page");
    await page.goBack();
    await expect(heading).toBeVisible();
  }
  expect(state.unexpectedRequests).toEqual([]);
});

test("Content search uses authorized filters and pagination, then opens the exact source", async ({ page }, info) => {
  const state = await contentWorkspace(page);
  const searches: URL[] = [];
  await page.route("**/api/v1/search/unified?**", route => {
    const url = new URL(route.request().url());
    searches.push(url);
    const more = url.searchParams.get("cursor") === "next-authorized-page";
    return route.fulfill({ json: searchPage(more ? [{
      ...fileResult, id: "second-file", title: "Project appendix.pdf", score: 90
    }] : [fileResult], more ? null : "next-authorized-page") });
  });
  await page.goto("/app/content");
  await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeVisible();
  expect(searches).toHaveLength(0);
  await expect(page.getByRole("dialog", { name: "Search workspace", exact: true })).toHaveCount(0);
  await page.getByRole("searchbox", { name: "Search messages, files, boards and meetings", exact: true }).fill("Project plan");
  await page.getByRole("combobox", { name: "Content type", exact: true }).selectOption("file");
  await page.getByRole("combobox", { name: "Conversation", exact: true }).selectOption(conversationId);
  await page.getByRole("button", { name: "Search", exact: true }).click();
  const results = page.getByRole("list", { name: "Ranked search results", exact: true });
  await expect(results.getByRole("link")).toHaveCount(1);
  await expect(page.getByText(/Only content you can access is shown/)).toBeVisible();
  await page.getByRole("button", { name: "More results", exact: true }).click();
  await expect(results.getByRole("link")).toHaveCount(2);
  await expectMinimumTargets(results.getByRole("link"), "Content search result links");
  expect(searches.map(url => Object.fromEntries(url.searchParams))).toEqual([
    { q: "Project plan", kind: "file", conversation_id: conversationId, limit: "25" },
    { q: "Project plan", kind: "file", conversation_id: conversationId, cursor: "next-authorized-page", limit: "25" }
  ]);
  await capture(page, info, "desktop-content-search");
  await results.getByRole("link", { name: /Project plan.pdf/ }).click();
  await expect(page).toHaveURL(fileResult.path);
  await expect(page.getByRole("list", { name: "Thread root", exact: true }).getByText("Mobile-ready message body", { exact: true })).toBeVisible();
  expect(state.unexpectedRequests).toEqual([]);
});

test("Content search clears previously authorized results when access is denied", async ({ page }) => {
  const state = await contentWorkspace(page);
  let denied = false;
  await page.route("**/api/v1/search/unified?**", route => denied
    ? route.fulfill({ status: 403, json: { error: { code: "forbidden", detail: "Your content access changed." } } })
    : route.fulfill({ json: searchPage([fileResult]) }));
  await page.goto("/app/content");
  const query = page.getByRole("searchbox", { name: "Search messages, files, boards and meetings", exact: true });
  await query.fill("Project plan");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await expect(page.getByRole("list", { name: "Ranked search results" })).toContainText(fileResult.title);
  denied = true;
  await query.fill("Changed access");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Your content access changed.");
  await expect(page.getByRole("list", { name: "Ranked search results" }).getByRole("link")).toHaveCount(0);
  denied = false;
  await page.getByRole("button", { name: "Retry search", exact: true }).click();
  await expect(page.getByRole("list", { name: "Ranked search results" })).toContainText(fileResult.title);
  expect(state.unexpectedRequests).toEqual([]);
});

test("document context survives Content navigation, keyboard route focus and history", async ({ page }, info) => {
  const state = await contentWorkspace(page);
  const path = `/app/documents?conversation=${conversationId}&document=${documentId}&review=kept#main-content`;
  await page.goto(path);
  await expect(page.getByRole("region", { name: "Project notes", exact: true })).toBeVisible();
  const documents = page.getByRole("navigation", { name: "Workspace tools", exact: true }).getByRole("link", { name: "Shared documents", exact: true });
  await expect(documents).toHaveAttribute("href", path);
  await documents.focus();
  await documents.press("Enter");
  await expect(page).toHaveURL(path);
  await expect(page.getByRole("region", { name: "Project notes", exact: true })).toBeVisible();
  await capture(page, info, "desktop-document-context");
  const content = page.getByRole("navigation", { name: "Workspace shortcuts", exact: true }).getByRole("link", { name: "Open Content", exact: true });
  await content.focus();
  await content.press("Enter");
  await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeFocused();
  await expect(page).toHaveTitle("Content | K-Comms");
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page).toHaveURL(path);
  await expect(page.getByRole("heading", { name: "Shared documents", exact: true })).toBeFocused();
  await expect(page.getByRole("region", { name: "Project notes", exact: true })).toBeVisible();
  await expect(documents).toHaveAttribute("href", path);
  await page.getByRole("button", { name: "Go forward", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeFocused();
  expect(state.unexpectedRequests).toEqual([]);
});

for (const width of [320, 390]) {
  test(`${width}px You opens Content while retaining the five primary destinations`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 844 });
    const state = await contentWorkspace(page);
    await page.goto("/app/");
    const primary = page.getByRole("navigation", { name: "Primary navigation", exact: true });
    await expect(primary.getByRole("link")).toHaveText(["Inbox", "Calls", "Directory", "Files", "You"]);
    await primary.getByRole("link", { name: "You", exact: true }).click();
    await page.getByRole("navigation", { name: "Workspace", exact: true }).getByRole("link", { name: "Content", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeInViewport();
    const browse = page.getByRole("navigation", { name: "Browse content", exact: true });
    await expect(browse.getByRole("link")).toHaveCount(5);
    await expectMinimumTargets(browse.getByRole("link"), "Phone Content categories");
    const search = page.locator(".content-search");
    await expectMinimumTargets(search.getByRole("searchbox").or(search.getByRole("combobox")).or(search.getByRole("button")), "Phone Content search controls");
    await expectNoDocumentOverflow(page);
    await capture(page, info, `mobile-content-${width}`);
    await browse.getByRole("link", { name: /^Shared documents\b/ }).click();
    await expect(page.getByRole("heading", { name: "Shared documents", exact: true })).toBeVisible();
    await expect(primary.getByRole("link")).toHaveText(["Inbox", "Calls", "Directory", "Files", "You"]);
    await expectNoDocumentOverflow(page);
    expect(state.unexpectedRequests).toEqual([]);
  });
}

for (const width of [390, 1440]) {
  test(`${width}px Calls switches between Internet calls and Phone without changing primary navigation`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    const state = await contentWorkspace(page);
    await page.goto("/app/calls");
    const types = page.getByRole("navigation", { name: "Call types", exact: true });
    await expect(types.getByRole("link", { name: "Internet calls", exact: true })).toHaveAttribute("aria-current", "page");
    await capture(page, info, `${width === 390 ? "mobile" : "desktop"}-internet-calls`);
    await types.getByRole("link", { name: "Phone", exact: true }).click();
    await expect(page).toHaveURL("/app/calls/phone");
    await expect(page.getByRole("heading", { name: "Phone", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Phone service is off", exact: true })).toBeVisible();
    await expect(types.getByRole("link", { name: "Phone", exact: true })).toHaveAttribute("aria-current", "page");
    if (width === 390) {
      const primary = page.getByRole("navigation", { name: "Primary navigation", exact: true });
      await expect(primary.getByRole("link")).toHaveText(["Inbox", "Calls", "Directory", "Files", "You"]);
      await expect(primary.getByRole("link", { name: "Calls", exact: true })).toHaveAttribute("aria-current", "page");
    } else {
      await expect(page.getByRole("navigation", { name: "Workspace shortcuts", exact: true }).getByRole("link", { name: "Open Calls", exact: true })).toHaveAttribute("aria-current", "page");
    }
    await expectNoDocumentOverflow(page);
    await capture(page, info, `${width === 390 ? "mobile" : "desktop"}-phone`);
    await types.getByRole("link", { name: "Internet calls", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Calls", exact: true })).toBeVisible();
    expect(state.unexpectedRequests).toEqual([]);
  });

  test(`${width}px Meetings opens connected calendars in You and preserves settings history`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    const state = await contentWorkspace(page);
    let calendarReads = 0;
    await page.route("**/api/v1/calendar/connections", route => {
      calendarReads += 1;
      return route.fulfill({ json: {
        data: [], meta: { mode: "one_way_hosted_occurrences", policy: { export_allowed: false, version: 1 }, providers: [
          { provider: "google", configured: false, qualified: false, safe_reason: "not_configured" },
          { provider: "microsoft", configured: false, qualified: false, safe_reason: "not_configured" }
        ] }
      } });
    });
    await page.goto("/app/meetings");
    await expect(page.getByRole("heading", { name: "Meetings", exact: true })).toBeVisible();
    expect(calendarReads).toBe(0);
    await page.getByRole("link", { name: "Connected calendars", exact: true }).click();
    await expect(page).toHaveURL("/app/you?section=calendar");
    await expect(page.getByRole("tab", { name: "Connected calendars", exact: true })).toHaveAttribute("aria-selected", "true");
    await expect(page.getByRole("heading", { name: "Connected calendars", exact: true })).toBeVisible();
    await expect(page.getByText("Unavailable in this deployment.", { exact: true })).toHaveCount(2);
    await expect(page.getByText(/Calendar export is disabled by workspace policy/)).toBeVisible();
    await expectNoDocumentOverflow(page);
    await capture(page, info, `${width === 390 ? "mobile" : "desktop"}-connected-calendars`);
    await page.getByRole("tab", { name: "Profile", exact: true }).click();
    await expect(page).toHaveURL("/app/you?section=profile");
    await page.goBack();
    await expect(page.getByRole("heading", { name: "Connected calendars", exact: true })).toBeVisible();
    expect(calendarReads).toBeGreaterThan(0);
    expect(state.unexpectedRequests).toEqual([]);
  });

  test(`${width}px Content remains available after member role refresh removes privileged shortcuts`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await contentWorkspace(page);
    await page.goto("/app/content");
    await expect(page.getByRole("heading", { name: "Content", exact: true })).toBeVisible();
    const session = await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!) as Session);
    await page.route("**/api/v1/me", route => route.fulfill({ json: {
      tenant: session.tenant, user: { ...session.user, role: "member", platform_role: null, platform_role_expires_at: null }, device: session.device,
      capabilities: { allow_audio_calls: true, allow_video_calls: true, allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 }
    } }));
    await page.reload();
    await expect.poll(() => page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!).user.role)).toBe("member");
    await expect(page.getByRole("navigation", { name: "Browse content", exact: true }).getByRole("link")).toHaveCount(5);
    await expect(page.getByRole("link", { name: /^(Open )?(Workspace administration|Service operations)$/ })).toHaveCount(0);
    if (width === 390) {
      await page.getByRole("navigation", { name: "Primary navigation", exact: true }).getByRole("link", { name: "You", exact: true }).click();
      await expect(page.getByRole("navigation", { name: "Workspace", exact: true }).getByRole("link", { name: "Content", exact: true })).toBeVisible();
      await expect(page.getByRole("navigation", { name: /^(Workspace administration|Service operations)$/ })).toHaveCount(0);
    }
    await expectNoDocumentOverflow(page);
    expect(state.unexpectedRequests).toEqual([]);
  });
}
