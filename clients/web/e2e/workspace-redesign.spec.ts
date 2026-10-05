import AxeBuilder from "@axe-core/playwright";
import type { Page, TestInfo } from "@playwright/test";
import type { Session } from "../src/types";
import { expect, test } from "./fixtures";
import {
  conversationId,
  messageId,
  tenantId,
  userId,
  expectNoDocumentOverflow,
  installWorkspace
} from "./mobile-ui-support";
import type { Message } from "../src/types";

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Explicit desktop and phone viewports run once per engine");
  await page.setViewportSize({ width: 1440, height: 900 });
});

async function revealNavigation(page: Page) {
  const reveal = page.getByRole("button", { name: "Show workspace navigation" });
  if (await reveal.isVisible()) await reveal.click();
  await expect(page.getByRole("button", { name: "Switch conversation or screen" })).toBeVisible();
}

async function capture(page: Page, info: TestInfo, name: string) {
  if (process.env.K_COMMS_VISUAL_CAPTURE !== "1") return;
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: info.outputPath(`${name}.png`), animations: "disabled" });
}

test("workspace switcher remains reachable after navigation hides and restores button focus", async ({ page }, info) => {
  await page.addInitScript(() => {
    localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "false");
  });
  const state = await installWorkspace(page);
  await page.clock.install();
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  await page.mouse.move(700, 250);
  await page.clock.fastForward(8_300);
  await expect(page.locator("#workspace-navigation")).toBeHidden();
  await revealNavigation(page);
  const trigger = page.getByRole("button", { name: "Switch conversation or screen" });
  await trigger.click();
  await page.clock.runFor(30);

  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  const search = dialog.getByRole("combobox", { name: "Find a conversation or screen" });
  await expect(dialog).toBeVisible();
  await expect(search).toBeFocused();
  await expect(dialog.getByRole("option", { name: /Workspace administration/ })).toBeVisible();
  await expect(dialog.getByRole("option", { name: /Service operations/ })).toBeVisible();
  await capture(page, info, "workspace-switcher");
  const accessibility = await new AxeBuilder({ page }).include(".workspace-switcher").analyze();
  expect(accessibility.violations).toEqual([]);

  await search.fill("no-such-destination-987654");
  await expect(dialog.getByRole("option")).toHaveCount(0);
  await expect(dialog.getByRole("status")).toContainText("No matching destination");
  await search.press("Enter");
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await page.clock.runFor(30);
  await expect(dialog).toHaveCount(0);
  await expect(trigger).toBeFocused();
  expect(state.unexpectedRequests).toEqual([]);
});

test("Ctrl K filters an existing conversation and opens it without a search API", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await page.getByRole("heading", { name: "Inbox", exact: true }).click();
  await page.keyboard.press("Control+k");
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  const search = dialog.getByRole("combobox", { name: "Find a conversation or screen" });
  await expect(search).toBeFocused();
  await search.fill("gEnErAl");
  await expect(dialog.getByRole("option")).toHaveCount(1);
  await expect(dialog.getByRole("option", { name: /General Channel/ })).toHaveAttribute("aria-selected", "true");
  await search.press("Enter");
  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL(`/app/?conversation=${conversationId}`);
  await expect(page.getByText("Mobile-ready message body", { exact: true })).toBeVisible();
  expect(state.unexpectedRequests).toEqual([]);
});

test("workspace switcher opens a screen with pointer selection", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  await revealNavigation(page);
  await page.getByRole("button", { name: "Switch conversation or screen" }).click();
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  await dialog.getByRole("combobox", { name: "Find a conversation or screen" }).fill("Calls");
  await dialog.getByRole("option", { name: "Calls Workspace", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL("/app/calls");
  await expect(page.getByRole("heading", { name: "Calls", exact: true })).toBeVisible();
  await expectNoDocumentOverflow(page);
  expect(state.unexpectedRequests).toEqual([]);
});

test("browser history dismisses the switcher instead of leaving a modal over the previous screen", async ({ page }) => {
  await installWorkspace(page);
  await page.goto(`/app/?conversation=${conversationId}`);
  await page.getByRole("link", { name: "Calls", exact: true }).click();
  await expect(page).toHaveURL("/app/calls");
  await revealNavigation(page);
  await page.getByRole("button", { name: "Switch conversation or screen" }).click();
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toBeVisible();
  await page.goBack();
  // Desktop selects the first conversation in the URL; assert the actual
  // prior location instead of assuming the inbox keeps an empty query.
  await expect(page).toHaveURL(`/app/?conversation=${conversationId}`);
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
});

test("password controls remain aligned when field text grows", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/sign-in");
  const password = page.getByLabel("Password", { exact: true });
  const toggle = page.getByRole("button", { name: "Show password", exact: true });
  await expect(password).toBeVisible();
  // The status response enables the form and removes its transport warning.
  // Measure the usable form after that reflow and the self-hosted font swap.
  await expect(password).toBeEnabled();
  await page.evaluate(() => document.fonts.ready);
  for (const enlarged of [false, true]) {
    if (enlarged) await page.addStyleTag({ content: "html { font-size: 20px !important; } .field label { line-height: 1.5 !important; letter-spacing: .12em !important; word-spacing: .16em !important; }" });
    // Both rectangles must describe the same layout; separate browser calls
    // can straddle a reflow and report a false alignment difference.
    const { inputBox, toggleBox } = await password.evaluate((input) => {
      const button = input.parentElement?.querySelector("button");
      if (!button) throw new Error("Password visibility control is missing");
      const inputRect = input.getBoundingClientRect();
      const toggleRect = button.getBoundingClientRect();
      return {
        inputBox: { y: inputRect.y, height: inputRect.height },
        toggleBox: { y: toggleRect.y, height: toggleRect.height }
      };
    });
    expect(Math.abs(inputBox.y - toggleBox.y)).toBeLessThanOrEqual(1);
    expect(Math.abs(inputBox.height - toggleBox.height)).toBeLessThanOrEqual(1);
    expect(toggleBox.height).toBeGreaterThanOrEqual(44);
    await expectNoDocumentOverflow(page);
  }
  await password.fill("synthetic-password-only");
  await toggle.click();
  await expect(password).toHaveAttribute("type", "text");
  await page.getByRole("button", { name: "Hide password", exact: true }).click();
  await expect(password).toHaveAttribute("type", "password");
  await capture(page, info, "password-control-large-text");
});

test("Ctrl K preserves text inputs and an existing modal", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  const inboxSearch = page.getByPlaceholder("Filter conversation titles", { exact: true });
  await inboxSearch.fill("General");
  await inboxSearch.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(inboxSearch).toBeFocused();
  await expect(inboxSearch).toHaveValue("General");

  await revealNavigation(page);
  await page.getByRole("button", { name: /^Notifications/ }).click();
  const notifications = page.getByRole("dialog", { name: "Notifications", exact: true });
  await expect(notifications).toBeVisible();
  const close = notifications.getByRole("button", { name: /Close/ }).first();
  await close.focus();
  await close.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(notifications).toBeVisible();
  await expect(close).toBeFocused();
  expect(state.unexpectedRequests).toEqual([]);
});

test("a member's switcher omits privileged tools after the authorized session refreshes", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  const session = await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!) as Session);
  const member = { ...session.user, role: "member", platform_role: null, platform_role_expires_at: null };
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: {
    tenant: session.tenant, user: member, device: session.device,
    capabilities: { allow_audio_calls: true, allow_video_calls: true, allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 }
  } }));
  await page.reload();
  await expect.poll(() => page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!).user.role)).toBe("member");
  await page.getByRole("heading", { name: "Inbox", exact: true }).click();
  await page.keyboard.press("Control+k");
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("option", { name: /General Channel/ })).toBeVisible();
  await expect(dialog.getByRole("option", { name: /Workspace administration|Service operations/ })).toHaveCount(0);
  expect(state.unexpectedRequests).toEqual([]);
});

for (const width of [320, 390]) {
  test(`${width}px administration exposes working content without a tall introduction`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 844 });
    const state = await installWorkspace(page, { tenantName: "InternationalWorkspace".repeat(8) });
    await page.goto("/admin?section=people");
    const people = page.getByRole("region", { name: "People, roles and sessions", exact: true });
    await expect(people).toBeVisible();
    const content = await people.boundingBox();
    expect(content).not.toBeNull();
    expect(content!.y, "The first administration task must begin within 320px of the viewport top").toBeLessThanOrEqual(320);
    const sections = page.getByRole("navigation", { name: "Administration sections" }).getByRole("button");
    await expect(sections).toHaveCount(9);
    await expect(sections).toHaveText([
      "Workspace", "Domains", "People", "Integrations", "Phone", "Safety", "Governance", "Audit", "Usage"
    ]);
    for (const section of await sections.all()) {
      await expect(section).toBeVisible();
      const target = await section.boundingBox();
      expect(target).not.toBeNull();
      expect(target!.width).toBeGreaterThanOrEqual(44);
      expect(target!.height).toBeGreaterThanOrEqual(44);
    }
    await expectNoDocumentOverflow(page);
    await capture(page, info, `administration-content-${width}`);
    expect(state.unexpectedRequests).toEqual([]);
  });
}

for (const width of [390, 1440]) {
  test(`${width}px title filtering stays distinct from global and conversation content search`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await installWorkspace(page);
    const searches: URL[] = [];
    await page.route("**/api/v1/search/unified?**", (route) => {
      searches.push(new URL(route.request().url()));
      return route.fulfill({ json: { data: [], facets: {}, page: { has_more: false, next_cursor: null, source_limits: { messages: false, files: false, whiteboards: false, meetings: false, artifacts: false }, ranking_scope: "authorized_source_candidates", meeting_window_days: 732 } } });
    });
    await page.goto("/app/");
    const sidebar = page.getByRole("complementary", { name: "Conversations", exact: true });
    await sidebar.getByRole("searchbox", { name: "Filter conversation titles" }).fill("General");
    expect(searches).toHaveLength(0);
    await sidebar.getByRole("button", { name: "Search workspace content", exact: true }).click();
    let search = page.getByRole("dialog", { name: "Search workspace", exact: true });
    await expect(search.getByRole("combobox", { name: "Conversation", exact: true })).toHaveValue("");
    await expect(search.getByRole("combobox", { name: "Content type", exact: true })).toHaveValue("all");
    await search.getByRole("searchbox").fill("roadmap");
    await search.getByRole("button", { name: "Search", exact: true }).click();
    await expect.poll(() => searches.length).toBe(1);
    expect(searches[0]?.searchParams.has("conversation_id")).toBe(false);
    await search.getByRole("button", { name: "Close workspace search" }).click();
    await page.goto(`/app/?conversation=${conversationId}`);
    if (width <= 760) {
      await page.getByRole("button", { name: "More conversation actions" }).click();
      await page.getByRole("dialog", { name: "Conversation", exact: true }).getByRole("button", { name: "Search messages", exact: true }).click();
    } else await page.locator(".conversation-pane").getByRole("button", { name: "Search messages", exact: true }).click();
    search = page.getByRole("dialog", { name: "Search workspace", exact: true });
    await expect(search.getByRole("combobox", { name: "Conversation", exact: true })).toHaveValue(conversationId);
    await search.getByRole("searchbox").fill("roadmap");
    await search.getByRole("button", { name: "Search", exact: true }).click();
    await expect.poll(() => searches.length).toBe(2);
    expect(searches[1]?.searchParams.get("conversation_id")).toBe(conversationId);
    await expectNoDocumentOverflow(page);
    expect(state.unexpectedRequests).toEqual([]);
  });

  test(`${width}px new conversation keeps people selected across searches`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await installWorkspace(page);
    const people = [
      { id: "11111111-1111-4111-8111-111111111111", display_name: "Grace Hopper" },
      { id: "22222222-2222-4222-8222-222222222222", display_name: "Alan Turing" }
    ].map((person) => ({ ...person, tenant_id: tenantId, role: "member", status: "active", account_type: "human" }));
    await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [{ id: userId, tenant_id: tenantId, display_name: "Ada Lovelace", role: "owner", account_type: "human", status: "active" }, ...people] } }));
    await page.goto("/app/");
    await page.getByRole("button", { name: "Create conversation", exact: true }).click();
    const form = page.locator(".create-conversation");
    await form.getByRole("combobox", { name: "Type", exact: true }).selectOption("group");
    await form.getByLabel("Title", { exact: true }).fill("Planning");
    const search = form.getByRole("searchbox", { name: "Find a teammate" });
    await search.fill("Grace");
    await form.getByRole("checkbox", { name: "Grace Hopper", exact: true }).check();
    await search.fill("Alan");
    await form.getByRole("checkbox", { name: "Alan Turing", exact: true }).check();
    await expect(form.getByRole("region", { name: "Selected people" })).toContainText("2 people selected");
    await search.fill("Nobody matches");
    await expect(form.getByRole("status")).toContainText("Your selections are kept");
    await form.getByRole("button", { name: "Remove Grace Hopper" }).click();
    await expect(form.getByRole("region", { name: "Selected people" })).toContainText("1 person selected");
    await expectNoDocumentOverflow(page);
    await capture(page, info, `recipient-picker-${width}`);
    const accessibility = await new AxeBuilder({ page }).include(".create-conversation").analyze();
    expect(accessibility.violations).toEqual([]);
    expect(state.unexpectedRequests).toEqual([]);
  });

  test(`${width}px notification category and search show their loaded-results scope`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await installWorkspace(page);
    await page.goto("/app/");
    if (width > 760) await revealNavigation(page);
    await page.getByRole("button", { name: /^Notifications/ }).click();
    const panel = page.getByRole("dialog", { name: "Notifications", exact: true });
    await panel.getByRole("combobox", { name: "Category", exact: true }).selectOption("mention.created.v1");
    await expect(panel).toContainText("No loaded notifications match these filters.");
    await panel.getByRole("combobox", { name: "Category", exact: true }).selectOption("message.created.v1");
    await panel.getByRole("searchbox", { name: "Search loaded notifications" }).fill("Notification body 18");
    await expect(panel.locator(".notification-list > li")).toHaveCount(1);
    await expect(panel).toContainText("Mobile notification 18");
    await expect(panel).toContainText("filters apply to loaded notifications");
    await expect(panel.getByRole("button", { name: "Mark all read" })).toHaveAccessibleDescription(/including updates outside these filters/);
    await expectNoDocumentOverflow(page);
    await capture(page, info, `notification-filters-${width}`);
    const accessibility = await new AxeBuilder({ page }).include(".notification-inbox").analyze();
    expect(accessibility.violations).toEqual([]);
    expect(state.unexpectedRequests).toEqual([]);
  });

  test(`${width}px thread actions preserve author permissions and denied edit drafts`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await installWorkspace(page);
    const root: Message = {
      id: messageId, tenant_id: tenantId, conversation_id: conversationId,
      sender_user_id: userId, sender_device_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      client_message_id: "thread-root", conversation_sequence: 1, body: "Thread root",
      metadata: {}, status: "active", inserted_at: "2026-10-04T12:00:00Z",
      attachments: [], reactions: [], thread_reply_count: 1
    };
    const reply = { ...root, id: "22222222-2222-4222-8222-222222222222", sender_user_id: "11111111-1111-4111-8111-111111111111", body: "Teammate reply", conversation_sequence: 2, thread_root_message_id: root.id };
    await page.route("**/api/v1/conversations/*/messages/*/thread?**", (route) => route.fulfill({ json: { data: { root, replies: [reply] }, page: { has_more: false, next_before_sequence: null } } }));
    await page.route(`**/api/v1/messages/${messageId}`, (route) => route.fulfill({ status: 403, json: { error: { code: "edit_window_expired", detail: "Message edit window expired" } } }));
    let reactions = 0;
    await page.route("**/api/v1/conversations/*/messages/*/reactions", (route) => { reactions += 1; return route.fulfill({ status: 204 }); });
    await page.goto(`/app/?conversation=${conversationId}`);
    if (width <= 760) await page.locator(".conversation-pane").getByRole("button", { name: "More message actions" }).click();
    await page.locator(".conversation-pane .message-actions").getByRole("button", { name: "Start thread" }).click();
    const thread = page.getByRole("dialog", { name: "Thread", exact: true });
    const owner = thread.getByRole("list", { name: "Thread root" });
    await expect(owner.getByRole("button", { name: "Edit", exact: true })).toBeVisible();
    await expect(thread.locator(".thread-replies").getByRole("button", { name: "Edit", exact: true })).toHaveCount(0);
    await owner.getByRole("button", { name: "React with 👍" }).click();
    await expect(owner.getByRole("button", { name: "Remove 👍 reaction; 1 total" })).toHaveAttribute("aria-pressed", "true");
    expect(reactions).toBe(1);
    await owner.getByRole("button", { name: "Edit", exact: true }).click();
    await owner.getByRole("textbox", { name: "Edit message" }).fill("Revised root");
    await owner.getByRole("button", { name: "Save", exact: true }).click();
    await expect(owner.getByRole("alert")).toContainText("Message edit window expired");
    await expect(owner.getByRole("textbox", { name: "Edit message" })).toHaveValue("Revised root");
    await expect.poll(() => thread.locator(".thread-content").evaluate((element) => element.scrollWidth - element.clientWidth)).toBeLessThanOrEqual(1);
    await expectNoDocumentOverflow(page);
    await capture(page, info, `thread-controls-${width}`);
    const accessibility = await new AxeBuilder({ page }).include(".thread-drawer").analyze();
    expect(accessibility.violations).toEqual([]);
    expect(state.unexpectedRequests).toEqual([]);
  });
}
