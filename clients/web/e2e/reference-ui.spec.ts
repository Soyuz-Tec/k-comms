import AxeBuilder from "@axe-core/playwright";
import type { Page, TestInfo } from "@playwright/test";
import { expect, test } from "./fixtures";
import {
  conversationId, userId, messageId, installWorkspace,
  installDeterministicMediaDevices, operationsSnapshot
} from "./mobile-ui-support";

// Synthetic release evidence, not a production account or media-quality test.
async function installReferenceWorkspace(page: Page) {
  const state = await installWorkspace(page);
  await installDeterministicMediaDevices(page);
  const files = ["Project-brief.pdf", "Workshop-notes.pdf"].map((name, index) => ({
    id: `file-${index}`, conversation_id: conversationId, message_id: messageId,
    conversation_sequence: 1, owner_user_id: userId, file_name: name,
    content_type: "application/pdf", byte_size: 48_000, status: "ready",
    scan_status: index ? "blocked" : "clean", safety_state: index ? "blocked" : "available",
    downloadable: index === 0, inserted_at: "2026-09-01T12:00:00Z",
    uploaded_at: "2026-09-01T12:00:00Z", shared_at: "2026-09-01T12:00:00Z"
  }));
  const emptyLists = new Set([
    "/api/v1/channels/discover", "/api/v1/moderation/cases", "/api/v1/admin/attachment-safety",
    "/api/v1/admin/webhooks", "/api/v1/admin/webhook-deliveries", "/api/v1/admin/service-accounts",
    "/api/v1/admin/audit-events", "/api/v1/admin/retention-policies",
    "/api/v1/admin/legal-holds", "/api/v1/admin/deletion-requests"
  ]);
  await page.route("**/api/v1/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() !== "GET") return route.fallback();
    if (path === "/api/v1/directory/users") return route.fulfill({ json: {
      data: ["Grace Hopper", "Katherine Johnson", "Alan Turing", "Margaret Hamilton"].map((display_name, i) => ({ id: `person-${i}`, display_name })),
      page: { next_cursor: null }
    } });
    if (path === "/api/v1/files") return route.fulfill({ json: { data: files, page: { has_more: false, next_cursor: null, limit: 25 } } });
    if (path.endsWith("/whiteboard/operations")) return route.fulfill({ json: { data: [], page: { has_more: false, next_after_sequence: 0 } } });
    if (path === "/api/v1/platform/ops") return route.fulfill({ json: { data: { ...operationsSnapshot(), generated_at: new Date().toISOString() } } });
    if (emptyLists.has(path)) return route.fulfill({ json: { data: [], page: { has_more: false, next_cursor: null } } });
    return route.fallback();
  });
  return state;
}

async function verifyScreen(page: Page, info: TestInfo, name: string, axe = true) {
  await expect(page.getByRole("main").or(page.getByRole("dialog")).first()).toBeVisible();
  await expect(page.locator(".spinner").filter({ visible: true })).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
  if (name === "reset-unavailable") {
    await expect(page.getByRole("alert")).toContainText("This reset link is invalid or expired");
  } else {
    await expect(page.locator('[role="alert"]')).toHaveCount(0);
  }
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: info.outputPath(`${name}.png`), fullPage: true, animations: "disabled" });
  }
  if (axe) {
    const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"]).analyze();
    expect(results.violations.map(({ id, nodes }) => ({ id, targets: nodes.map(({ target, failureSummary }) => ({ target, failureSummary })) })), name).toEqual([]);
  }
}

for (const width of [390, 1440]) {
  for (const colorScheme of ["light", "dark"] as const) {
    test(`reference system ${width}px ${colorScheme}: every member and privileged screen`, async ({ page }, info) => {
      test.skip(info.project.name !== "chromium", "Explicit viewport/theme matrix runs once");
      test.setTimeout(180_000);
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      await page.emulateMedia({ colorScheme });
      const state = await installReferenceWorkspace(page);
      for (const [path, selector, name] of [
        ["/app/", ".conversation-row", "inbox"],
        [`/app/?conversation=${conversationId}`, ".message-bubble", "conversation"],
        ["/app/calls", ".calls-launch-list", "calls"],
        ["/app/directory", ".directory-row", "directory"],
        ["/app/files", ".file-row", "files"],
        ["/app/whiteboard", ".k-comms-drawing-surface", "whiteboard"],
        ["/app/you", "#profile-settings", "profile"]
      ]) {
        await page.goto(path);
        await expect(page.locator(selector).first()).toBeVisible();
        await verifyScreen(page, info, name);
        if (name === "files" && width === 390) {
          const firstFile = await page.locator(".file-row").first().boundingBox();
          expect(firstFile?.y).toBeLessThan(200);
        }
        if (name === "whiteboard") {
          await page.getByRole("button", { name: "Open canvas controls" }).click();
          await expect(page.getByRole("dialog", { name: "Canvas controls", exact: true })).toBeVisible();
          await verifyScreen(page, info, "whiteboard-controls");
        }
      }
      for (const section of ["Security", "Notifications", "Accessibility"]) {
        await page.getByRole("tab", { name: section, exact: true }).click();
        await expect(page.getByRole("tabpanel")).toBeVisible();
        await verifyScreen(page, info, `settings-${section.toLowerCase()}`);
      }
      for (const section of ["workspace", "people", "safety", "governance", "integrations", "audit"]) {
        await page.goto(`/admin?section=${section}`);
        await expect(page.locator(`[data-admin-section="${section}"]`)).toBeVisible();
        await verifyScreen(page, info, `admin-${section}`);
      }
      await page.goto("/app/");
      await page.getByRole("button", { name: /Notifications/ }).click();
      await expect(page.getByRole("dialog", { name: "Notifications", exact: true })).toBeVisible();
      await verifyScreen(page, info, "notifications");
      await page.goto(`/app/?conversation=${conversationId}`);
      await page.getByRole("button", { name: "Start video call", exact: true }).click();
      const prejoin = page.getByRole("dialog", { name: "Start a video call" });
      await expect(prejoin).toBeVisible();
      await expect(prejoin.getByRole("checkbox", { name: "Use microphone when I join" })).not.toBeChecked();
      await expect(prejoin.getByRole("checkbox", { name: "Use camera when I join" })).not.toBeChecked();
      await verifyScreen(page, info, "call-prejoin");
      await page.goto("/ops");
      await expect(page.locator(".ops-triage-item")).toHaveCount(5);
      await expect(page.locator(".ops-triage-item details[open]")).toHaveCount(0);
      await verifyScreen(page, info, "operations");
      await page.locator(".ops-triage-item summary").first().click();
      await expect(page.locator(".ops-triage-item details[open]")).toHaveCount(1);
      await verifyScreen(page, info, "operations-guidance");
      expect(state.unexpectedRequests).toEqual([]);
    });

    test(`reference system ${width}px ${colorScheme}: public entry and recovery`, async ({ page }, info) => {
      test.skip(info.project.name !== "chromium", "Explicit viewport/theme matrix runs once");
      test.setTimeout(120_000);
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
      await page.emulateMedia({ colorScheme });
      await page.goto("/");
      await expect(page.getByLabel("Local drawing canvas")).toBeVisible();
      await verifyScreen(page, info, "public-canvas");
      if (width === 390) await page.getByRole("button", { name: "Room", exact: true }).click();
      await expect(page.getByRole("button", { name: "Create room", exact: true })).toBeVisible();
      await verifyScreen(page, info, "public-room");
      for (const [path, title, name] of [
        ["/sign-in", "Sign in to your workspace", "sign-in"],
        ["/forgot-password", "Reset your password", "recovery"],
        ["/reset-password", "Reset link unavailable", "reset-unavailable"],
        ["/join", "Open a K-Comms guest link", "guest-entry"],
        ["/app/#invitation_token=synthetic-token&tenant_slug=acme", "Join your workspace", "invitation"]
      ]) {
        await page.goto(path);
        await expect(page.getByRole("heading", { name: title, exact: true })).toBeVisible();
        await verifyScreen(page, info, name);
      }
    });
  }
}

test("applied file filters stay visible and can be cleared without enabling unsafe downloads", async ({ page }) => {
  const state = await installReferenceWorkspace(page);
  await page.goto("/app/files");
  const filters = page.locator(".files-advanced-filter");
  await filters.locator("summary").click();
  await filters.getByRole("button", { name: "Shared by me" }).click();
  await filters.getByRole("combobox", { name: "Conversation" }).selectOption(conversationId);
  await filters.locator("summary").click();
  await expect(page.locator(".files-filter-summary")).toContainText("Shared by me · General");
  await expect(filters.locator(".filter-count")).toHaveText("2");
  await page.getByRole("button", { name: "Clear filters" }).click();
  await expect(page.locator(".files-filter-summary")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Download Workshop-notes.pdf" })).toBeDisabled();
  expect(state.unexpectedRequests).toEqual([]);
});

test("vertical settings tabs support up/down keys and keep focus on the selected tab", async ({ page }) => {
  await installReferenceWorkspace(page);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto("/app/you");
  const profile = page.getByRole("tab", { name: "Profile", exact: true });
  await profile.focus();
  await profile.press("ArrowDown");
  await expect(page.getByRole("tab", { name: "Security", exact: true })).toBeFocused();
  await expect(page.getByRole("tab", { name: "Security", exact: true })).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("ArrowUp");
  await expect(profile).toBeFocused();
});

for (const width of [320, 1024]) {
  test(`reference system reflows at ${width}px`, async ({ page }, info) => {
    test.skip(info.project.name !== "chromium", "Explicit responsive matrix runs once");
    test.setTimeout(120_000);
    await page.setViewportSize({ width, height: 800 });
    const state = await installReferenceWorkspace(page);
    for (const path of ["/app/calls", "/app/directory", "/app/files", "/app/you", "/app/whiteboard", "/admin?section=people", "/ops"]) {
      await page.goto(path);
      await expect(page.locator("#main-content")).toBeVisible();
      await verifyScreen(page, info, path.replace(/\W/g, "-"));
    }
    expect(state.unexpectedRequests).toEqual([]);
  });
}
