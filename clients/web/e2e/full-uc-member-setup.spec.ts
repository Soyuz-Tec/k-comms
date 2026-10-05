import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { conversationId, installWorkspace, tenantId, userId, expectNoDocumentOverflow } from "./mobile-ui-support";
import type { Conversation, MemberWorkspace, MemberWorkspaceInput } from "../src/types";

const grace = { id: "11111111-1111-4111-8111-111111111111", display_name: "Grace Hopper" };
const alan = { id: "22222222-2222-4222-8222-222222222222", display_name: "Alan Turing" };
const actualConversationId = "ffffffff-ffff-4fff-8fff-ffffffffffff";

function store() {
  return {
    data: {
      version: 0, contacts: [], groups: [],
      onboarding: { dismissed_at: null, profile_reviewed_at: null, active_devices: 2, has_teammates: true },
      limits: { contacts: 500, groups: 20, members_per_group: 50 }, observed_at: "2026-10-05T00:00:00Z"
    } as MemberWorkspace,
    conversation: null as Conversation | null,
    conversationInputs: [] as unknown[],
    updates: [] as MemberWorkspaceInput[],
    rejectWrite: false
  };
}

async function installMember(page: Page, state: ReturnType<typeof store>) {
  const base = await installWorkspace(page);
  await page.addInitScript(() => {
    const target = window as Window & { memberMediaRequests?: number };
    target.memberMediaRequests = 0;
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => { target.memberMediaRequests = (target.memberMediaRequests || 0) + 1; throw new Error("Fixture requires explicit media testing"); }
    } });
  });
  await page.route("**/api/v1/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    if (method === "GET" && path === "/api/v1/me/workspace") return route.fulfill({ json: { data: state.data } });
    if ((method === "PUT" && path === "/api/v1/me/workspace") || (method === "PATCH" && path === "/api/v1/me/onboarding")) {
      if (state.rejectWrite) return route.fulfill({ status: 403, json: { error: { code: "forbidden", detail: "Synthetic access revoked" } } });
      const input = route.request().postDataJSON();
      if (input.version !== state.data.version) return route.fulfill({ status: 409, json: { error: { code: "stale_version", detail: "Changed in another browser" } } });
      if (method === "PUT") {
        state.updates.push(input);
        state.data.contacts = [grace, alan].filter(({ id }) => input.contact_ids.includes(id));
        state.data.groups = input.groups;
      } else {
        state.data.onboarding.dismissed_at = input.action === "dismiss" ? "2026-10-05T01:00:00Z" : null;
        if (input.action === "reset") state.data.onboarding.profile_reviewed_at = null;
      }
      state.data.version += 1;
      return route.fulfill({ json: { data: state.data } });
    }
    if (method === "GET" && path === "/api/v1/directory/users") return route.fulfill({ json: { data: [grace, alan], page: { next_cursor: null } } });
    if (method === "POST" && (path === "/api/v1/conversations" || path === "/api/v1/direct-conversations")) {
      const input = route.request().postDataJSON();
      state.conversationInputs.push(input);
      state.conversation = {
        id: actualConversationId, tenant_id: tenantId, kind: path.endsWith("direct-conversations") ? "direct" : "group",
        title: input.title || null, visibility: "private", latest_sequence: 0,
        counterpart_user_id: input.user_id || null, counterpart_display_name: input.user_id ? "Grace Hopper" : null,
        inserted_at: "2026-10-05T00:00:00Z", updated_at: "2026-10-05T00:00:00Z"
      };
      return route.fulfill({ json: { data: state.conversation, created: true } });
    }
    if (path.startsWith(`/api/v1/conversations/${actualConversationId}/`)) {
      if (path.endsWith("/read-cursor")) return route.fulfill({ status: 204 });
      if (path.endsWith("/call")) return route.fulfill({ json: { data: null } });
      if (path.endsWith("/draft")) return route.fulfill({ json: { data: { conversation_id: actualConversationId, thread_key: "main", body: "", version: 0, expires_at: null } } });
      if (path.endsWith("/messages")) return route.fulfill({ json: { data: [], page: { has_more: false, next_after_sequence: null, reset_required: false } } });
      if (path.endsWith("/delivery-cursor")) return route.fulfill({ json: { data: { recipient_user_id: userId, device_ref: "synthetic", delivered_sequence: 0, read_sequence: 0, delivered_at: null, read_at: null } } });
      if (path.endsWith("/members") || path.endsWith("/delivery-cursors")) return route.fulfill({ json: { data: [] } });
    }
    if (method === "GET" && path === "/api/v1/conversations" && state.conversation) return route.fulfill({ json: { data: [state.conversation, {
      id: conversationId, tenant_id: tenantId, kind: "channel", title: "General", visibility: "tenant", latest_sequence: 1,
      inserted_at: "2026-07-15T12:00:00Z", updated_at: "2026-07-15T12:00:00Z"
    }] } });
    return route.fallback();
  });
  return base;
}

// Route-mocked presentation/interaction evidence. Actual API privacy, database
// concurrency and independently authenticated runtime journeys remain separate.
test("two isolated browsers share setup dismissal/resume without starting media", async ({ page, browser }) => {
  const state = store();
  const first = await installMember(page, state);
  await page.goto("/app/you?section=profile");
  const context = await browser.newContext({ baseURL: new URL(page.url()).origin, serviceWorkers: "block" });
  try {
    const secondPage = await context.newPage();
    const second = await installMember(secondPage, state);
    await secondPage.goto("/app/you?section=profile");
    await page.getByRole("button", { name: "Hide for now" }).click();
    await expect(page.getByRole("button", { name: "Resume setup" })).toBeVisible();
    await secondPage.reload();
    await expect(secondPage.getByRole("button", { name: "Resume setup" })).toBeVisible();
    await secondPage.getByRole("button", { name: "Resume setup" }).click();
    await expect(secondPage.getByRole("button", { name: "Hide for now" })).toBeVisible();
    await page.reload();
    await expect(page.getByRole("button", { name: "Hide for now" })).toBeVisible();
    expect(await page.evaluate(() => (window as Window & { memberMediaRequests?: number }).memberMediaRequests)).toBe(0);
    expect(await secondPage.evaluate(() => (window as Window & { memberMediaRequests?: number }).memberMediaRequests)).toBe(0);
    expect(first.unexpectedRequests).toEqual([]);
    expect(second.unexpectedRequests).toEqual([]);
  } finally { await context.close(); }
});

for (const width of [320, 390, 768, 1024]) {
  for (const colorScheme of ["light", "dark"] as const) {
    test(`private contacts/group complete flow stays accessible at ${width}px ${colorScheme}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.emulateMedia({ colorScheme });
      const state = store();
      const fixture = await installMember(page, state);
      await page.goto("/app/directory");
      await page.getByRole("button", { name: "Add Grace Hopper to contacts" }).click();
      await expect(page.getByRole("button", { name: "Remove Grace Hopper from contacts" })).toBeEnabled();
      await page.getByRole("button", { name: "Add Alan Turing to contacts" }).click();
      await page.getByRole("button", { name: "Groups", exact: true }).click();
      await page.getByRole("button", { name: "Create contact group" }).click();
      const editor = page.getByRole("form", { name: "Edit private contact group" });
      await editor.getByLabel("Group name").fill("Planning");
      await editor.getByRole("checkbox", { name: "Grace Hopper" }).check();
      await editor.getByRole("checkbox", { name: "Alan Turing" }).check();
      await editor.getByRole("button", { name: "Save contact group" }).click();
      await expect(page.getByRole("heading", { name: "Planning" })).toBeVisible();
      await expectNoDocumentOverflow(page);
      const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"]).analyze();
      expect(results.violations.map(({ id, nodes }) => ({ id, targets: nodes.map(({ target }) => target) }))).toEqual([]);
      await page.getByRole("button", { name: "Message selected contacts in Planning" }).click();
      await expect(page).toHaveURL(new RegExp(`conversation=${actualConversationId}`));
      expect(state.conversationInputs).toEqual([{ title: "Planning", kind: "group", visibility: "private", member_ids: [grace.id, alan.id] }]);
      expect(fixture.unexpectedRequests).toEqual([]);
    });
  }
}

test("CAS retains a group draft and write denial clears loaded private state", async ({ page }) => {
  const state = store();
  state.data.contacts = [grace, alan];
  const fixture = await installMember(page, state);
  await page.goto("/app/directory?section=groups");
  await page.getByRole("button", { name: "Create contact group" }).click();
  const editor = page.getByRole("form", { name: "Edit private contact group" });
  await editor.getByLabel("Group name").fill("Retained pending group");
  await editor.getByRole("checkbox", { name: "Grace Hopper" }).check();
  state.data.version += 1;
  await editor.getByRole("button", { name: "Save contact group" }).click();
  await expect(page.getByRole("alert")).toContainText("Your pending changes are kept");
  await expect(editor.getByLabel("Group name")).toHaveValue("Retained pending group");
  await expect(editor.getByRole("checkbox", { name: "Grace Hopper" })).toBeChecked();
  state.rejectWrite = true;
  await editor.getByRole("button", { name: "Save contact group" }).click();
  await expect(page.getByRole("alert")).toContainText("Private contacts are unavailable");
  await expect(page.getByLabel("Group name")).toHaveCount(0);
  await expect(page.getByText("Grace Hopper", { exact: true })).toHaveCount(0);
  expect(state.updates).toEqual([]);
  expect(fixture.unexpectedRequests).toEqual([]);
});
