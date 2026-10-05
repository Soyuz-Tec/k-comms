import type { Locator, Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Desktop contextual navigation runs in both engines");
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(() => localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "false"));
  await page.clock.install();
});

async function expectCompactTargets(navigation: Locator) {
  for (const target of await navigation.getByRole("button").or(navigation.getByRole("link")).all()) {
    await expect(target).toBeVisible();
    await expect(target).toHaveAttribute("title", /\S/);
    const box = await target.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThanOrEqual(44);
    expect(box!.height).toBeGreaterThanOrEqual(44);
  }
}

async function expectKeyboardDockRecovery(page: Page, action: Locator) {
  const dock = page.locator("#workspace-navigation");
  await action.press("Escape");
  await expect(dock).toBeHidden();
  await expect(dock).toHaveAttribute("inert", "");
  const reveal = page.getByRole("button", { name: "Show workspace navigation", exact: true });
  await expect(reveal).toBeVisible();
  await reveal.focus();
  await page.keyboard.press("Enter");
  await page.clock.runFor(20);
  await expect(dock.getByRole("button", { name: "Switch conversation or screen", exact: true })).toBeFocused();
  await expect(dock).toHaveClass(/is-expanded/);
}

test("compact administration retains section targets, keyboard focus and query state", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/admin?section=workspace&review=kept");
  await expect(page.getByRole("heading", { name: "Workspace", level: 1, exact: true })).toBeVisible();
  const dock = page.locator("#workspace-navigation");
  const navigation = page.getByRole("navigation", { name: "Administration sections", exact: true });
  await expect(navigation).toHaveCount(1);
  await expect(dock).toHaveClass(/is-collapsed/);
  expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 48 });
  await expectCompactTargets(navigation);
  await expect(dock.getByRole("navigation", { name: "Administration sections", exact: true })).toBeVisible();
  const returnLink = await dock.getByRole("link", { name: "Return to workspace", exact: true }).boundingBox();
  const firstSection = await navigation.getByRole("button").first().boundingBox();
  expect(firstSection!.y - (returnLink!.y + returnLink!.height)).toBeLessThanOrEqual(40);
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1_000));

  const people = navigation.getByRole("button", { name: "People", exact: true });
  await people.focus();
  await expect(people).toBeFocused();
  await expect(dock).toHaveClass(/is-expanded/);
  expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 240 });
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await expect(people).toBeFocused();
  await people.press("Enter");
  await expect(page).toHaveURL(/\/admin\?section=people&review=kept$/);
  // Route orientation uses a browser frame to focus the selected surface.
  // Settle that frame before exercising the separate dock recovery action.
  await page.clock.runFor(100);
  await expect(people).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("heading", { name: "People", level: 1, exact: true })).toBeFocused();
  await expect(page.getByRole("heading", { name: "People, roles and sessions", exact: true })).toBeVisible();
  await expectKeyboardDockRecovery(page, people);
  await expectNoDocumentOverflow(page);
  expect(state.unexpectedRequests).toEqual([]);
});

test("compact operations retains section targets, keyboard focus and queue disclosure", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/ops");
  await expect(page.getByRole("heading", { name: "Operations triage", exact: true })).toBeVisible();
  const dock = page.locator("#workspace-navigation");
  const navigation = page.getByRole("navigation", { name: "Operations sections", exact: true });
  await expect(navigation).toHaveCount(1);
  await expect(dock).toHaveClass(/is-collapsed/);
  expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 48 });
  await expectCompactTargets(navigation);
  await expect(dock.getByRole("navigation", { name: "Operations sections", exact: true })).toBeVisible();
  const queueDetails = page.locator("details#ops-queues");
  // The retained fixture is stale and opens evidence by default. A member
  // can close it; the contextual shortcut must open that disclosure again.
  await expect(queueDetails).toHaveAttribute("open", "");
  await queueDetails.locator(":scope > summary").press("Enter");
  await expect(queueDetails).not.toHaveAttribute("open");
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1_000));

  const queues = navigation.getByRole("link", { name: "Queues", exact: true });
  await queues.focus();
  await expect(queues).toBeFocused();
  await expect(dock).toHaveClass(/is-expanded/);
  expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 240 });
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await expect(queues).toBeFocused();
  await queues.press("Enter");
  await expect(page).toHaveURL(/\/ops#ops-queues$/);
  await page.clock.runFor(100);
  await expect(queueDetails).toHaveAttribute("open", "");
  await expect(queueDetails.getByRole("heading", { name: "Queues", exact: true })).toBeFocused();
  await expect(queueDetails.getByText("No platform queue jobs.", { exact: true })).toBeVisible();
  await expectKeyboardDockRecovery(page, queues);
  await expectNoDocumentOverflow(page);
  expect(state.unexpectedRequests).toEqual([]);
});
