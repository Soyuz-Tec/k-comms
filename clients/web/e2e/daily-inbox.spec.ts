import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { conversationId, expectNoDocumentOverflow, installWorkspace, messageId, tenantId, userId } from "./mobile-ui-support";

const roadmapId = "11111111-1111-4111-8111-111111111111";
const planningId = "22222222-2222-4222-8222-222222222222";

// Synthetic HTTP contracts exercise the rendered inbox and persistence flow;
// server authorization and preview retention are qualified by backend tests.
async function triageWorkspace(page: Page, failFavorite = false) {
  const workspace = await installWorkspace(page);
  const state = { favorite: false, writes: [] as boolean[], reads: 0 };
  const row = (id: string, title: string, excerpt: string) => ({
    id, tenant_id: tenantId, kind: "channel", title, visibility: "tenant",
    latest_sequence: 1, last_read_sequence: 0, unread_count: 1, version: 1,
    inserted_at: "2026-10-06T09:00:00Z", updated_at: "2026-10-06T12:00:00Z",
    favorite: id === roadmapId && state.favorite,
    inbox: { message: { id: messageId, sequence: 1, sender_user_id: id === conversationId ? userId : "grace",
      sender_display_name: id === conversationId ? "Ada Lovelace" : "Grace Hopper",
      status: "active", excerpt, inserted_at: "2026-10-06T12:00:00Z" },
    draft: id === roadmapId ? { excerpt: "Review the launch plan", expires_at: "2099-01-01T00:00:00Z" }
      : id === planningId ? { excerpt: "Expired draft must not return", expires_at: "2020-01-01T00:00:00Z" } : null }
  });
  await page.route(/\/api\/v1\/conversations(?:\?.*)?$/, route => {
    expect(route.request().method()).toBe("GET");
    expect(new URL(route.request().url()).searchParams.get("include")).toBe("inbox");
    state.reads += 1;
    return route.fulfill({ json: { data: [
      row(conversationId, "General", "Mobile-ready message body"),
      row(roadmapId, "Roadmap", "The release checklist is ready."),
      row(planningId, "Planning", "Please review the proposed dates.")
    ] } });
  });
  await page.route(`**/api/v1/conversations/${roadmapId}/favorite`, route => {
    expect(route.request().method()).toBe("PUT");
    const input = route.request().postDataJSON() as { favorite: boolean };
    expect(Object.keys(input)).toEqual(["favorite"]);
    expect(typeof input.favorite).toBe("boolean");
    state.writes.push(input.favorite);
    if (failFavorite) return route.fulfill({ status: 503, json: { error: { code: "temporarily_unavailable", detail: "Synthetic favorite write failure" } } });
    state.favorite = input.favorite;
    return route.fulfill({ json: { data: { conversation_id: roadmapId, favorite: state.favorite } } });
  });
  await page.route(new RegExp(`/api/v1/conversations/(${roadmapId}|${planningId})/(members|messages|draft|delivery-cursors|delivery-cursor|read-cursor|call)(?:\\?.*)?$`), route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/members") || path.endsWith("/delivery-cursors")) return route.fulfill({ json: { data: [] } });
    if (path.endsWith("/messages")) return route.fulfill({ json: { data: [], page: { has_more: false, next_after_sequence: null, reset_required: false } } });
    if (path.endsWith("/draft")) return route.fulfill({ json: { data: { conversation_id: path.split("/")[4], thread_key: "main", body: path.includes(roadmapId) ? "Review the launch plan" : "", version: 0, expires_at: "2099-01-01T00:00:00Z" } } });
    if (path.endsWith("/call")) return route.fulfill({ json: { data: null } });
    if (path.endsWith("/read-cursor")) return route.fulfill({ status: 204 });
    return route.fallback();
  });
  return { workspace, state };
}

for (const viewport of [{ name: "desktop", width: 1440, height: 900 }, { name: "mobile", width: 390, height: 844 }]) {
  test.describe(`daily inbox (${viewport.name})`, () => {
    test.beforeEach(async ({ page }, info) => {
      test.skip(!["chromium", "webkit"].includes(info.project.name), "Explicit desktop and phone viewports run once per browser engine");
      await page.setViewportSize(viewport);
    });

    test("sender and draft previews support favorites that survive a reload", async ({ page }, info) => {
      const { workspace, state } = await triageWorkspace(page);
      await page.goto("/app/");
      const list = page.getByRole("navigation", { name: "Conversation list", exact: true });
      const rows = list.locator(".conversation-row");
      await expect(list).toBeVisible();
      await expect(rows.filter({ hasText: "General" })).toContainText("You: Mobile-ready message body");
      await expect(rows.filter({ hasText: "Roadmap" })).toContainText("Draft: Review the launch plan");
      await expect(rows.filter({ hasText: "Planning" })).toContainText("Grace Hopper: Please review the proposed dates.");
      await expect(list).not.toContainText("Expired draft must not return");
      await page.getByRole("button", { name: "Add Roadmap to favorites", exact: true }).click();
      await expect(page.getByRole("button", { name: "Remove Roadmap from favorites", exact: true })).toHaveAttribute("aria-pressed", "true");
      expect(state.writes).toEqual([true]);
      await expect(rows.first()).toContainText("Roadmap");
      const initialReads = state.reads;
      await page.reload();
      await expect.poll(() => state.reads).toBeGreaterThan(initialReads);
      await expect(page.getByRole("button", { name: "Remove Roadmap from favorites", exact: true })).toHaveAttribute("aria-pressed", "true");
      await page.getByRole("group", { name: "Inbox view", exact: true }).getByRole("button", { name: "Favorites", exact: true }).click();
      await expect(rows).toHaveCount(1);
      await expect(rows.first()).toContainText("Roadmap");
      await page.getByRole("group", { name: "Inbox view", exact: true }).getByRole("button", { name: "All", exact: true }).click();
      await expect(rows).toHaveCount(3);
      await expectNoDocumentOverflow(page);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
        await page.evaluate(() => document.fonts.ready);
        await page.screenshot({ path: info.outputPath(`inbox-triage-${viewport.width}.png`), animations: "disabled" });
      }
      await page.getByRole("button", { name: "Remove Roadmap from favorites", exact: true }).click();
      await expect(page.getByRole("button", { name: "Add Roadmap to favorites", exact: true })).toHaveAttribute("aria-pressed", "false");
      expect(state.writes).toEqual([true, false]);
      expect(workspace.unexpectedRequests).toEqual([]);
    });

    test("a failed favorite keeps its prior state and a local composer draft takes preview precedence", async ({ page }) => {
      const { workspace, state } = await triageWorkspace(page, true);
      await page.goto("/app/");
      await page.getByRole("button", { name: "Add Roadmap to favorites", exact: true }).click();
      await expect(page.getByRole("alert")).toContainText("Could not update favorites. Try again.");
      await expect(page.getByRole("button", { name: "Add Roadmap to favorites", exact: true })).toHaveAttribute("aria-pressed", "false");
      expect(state.writes).toEqual([true]);
      const list = page.getByRole("navigation", { name: "Conversation list", exact: true });
      await list.locator(".conversation-row").filter({ hasText: "General" }).click();
      await page.getByRole("textbox", { name: "Message", exact: true }).fill("Finish the updated project notes");
      if (viewport.name === "mobile") await page.getByRole("button", { name: "Back to conversations", exact: true }).click();
      await expect(list.locator(".conversation-row").filter({ hasText: "General" })).toContainText("Draft: Finish the updated project notes");
      await expect(list.locator(".conversation-row").filter({ hasText: "General" })).not.toContainText("You: Mobile-ready message body");
      await expectNoDocumentOverflow(page);
      expect(workspace.unexpectedRequests).toEqual([]);
    });
  });
}
