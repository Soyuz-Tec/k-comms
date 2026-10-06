import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { installWorkspace } from "./mobile-ui-support";

async function movePointer(page: Page, x: number, y: number, buttons = 0) {
  const point = { x, y, buttons };
  await page.evaluate((expected) => {
    const fixtureWindow = window as Window & { navigationPointerReceipt?: typeof expected };
    delete fixtureWindow.navigationPointerReceipt;
    const record = (event: PointerEvent) => {
      if (event.clientX !== expected.x || event.clientY !== expected.y || event.buttons !== expected.buttons) return;
      fixtureWindow.navigationPointerReceipt = { x: event.clientX, y: event.clientY, buttons: event.buttons };
      document.removeEventListener("pointermove", record);
    };
    document.addEventListener("pointermove", record);
  }, point);
  await page.mouse.move(x, y);
  await expect.poll(() => page.evaluate(() =>
    (window as Window & { navigationPointerReceipt?: { x: number; y: number; buttons: number } }).navigationPointerReceipt
  )).toEqual(point);
}

test.beforeEach(async ({ page }, testInfo) => {
  test.skip(!["chromium", "webkit"].includes(testInfo.project.name), "Desktop dock coverage");
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(() => {
    const key = "k-comms.workspace-sidebar-collapsed.v1";
    if (localStorage.getItem(key) === null) localStorage.setItem(key, "false");
  });
  await installWorkspace(page);
  await page.clock.install();
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
});

for (const width of [1024, 1440]) {
  for (const colorScheme of ["light", "dark"] as const) {
    test(`${width}px ${colorScheme}: transparent dock hides and reveals without moving the workspace`, async ({ page }, testInfo) => {
      await page.setViewportSize({ width, height: 900 });
      await page.emulateMedia({ colorScheme });
      const dock = page.locator("#workspace-navigation");
      const workspace = page.locator(".workspace-grid");
      const rail = page.getByRole("navigation", { name: "Workspace shortcuts" });
      const header = page.locator(".desktop-shell-header");
      await expect(header).toBeVisible();
      expect((await header.boundingBox())!.height).toBe(44);
      await expect(rail).toBeVisible();
      expect(await rail.boundingBox()).toMatchObject({ x: 0, y: 44, width: 52 });
      await expect(dock).toBeVisible();
      expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 48 });
      await expect(dock).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
      const original = await workspace.boundingBox();
      expect(original!.x).toBe(52);
      expect(original!.y).toBe(44);
      expect(original!.width).toBe(width - 52);
      // Keep protocol latency outside the 250 ms hover interval, after the lazy route is ready.
      await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1_000));
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
        await page.screenshot({ path: testInfo.outputPath("compact.png") });
      }

      // Ordinary work and mouse movement outside the menu must not renew its timer.
      await movePointer(page, 700, 200);
      await page.clock.fastForward(4_000);
      await movePointer(page, 600, 260);
      await page.clock.fastForward(4_300);
      await expect(dock).toBeHidden();
      await expect(dock).toHaveAttribute("inert", "");
      await expect(rail).toBeVisible();
      await expect(rail.getByRole("link", { name: "Open Calls", exact: true })).toBeVisible();
      expect(await workspace.boundingBox()).toEqual(original);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
        await page.screenshot({ path: testInfo.outputPath("hidden.png") });
      }

      // Crossing the edge briefly, or dragging to it, is not a menu request.
      await movePointer(page, 3, 180);
      await movePointer(page, 100, 180);
      await page.clock.fastForward(300);
      await expect(dock).toBeHidden();
      await page.mouse.down();
      await movePointer(page, 3, 180, 1);
      await page.clock.fastForward(300);
      await expect(dock).toBeHidden();
      await page.mouse.up();
      await movePointer(page, 100, 180);
      await movePointer(page, 3, 180);
      await page.clock.fastForward(300);
      await expect(dock).toBeVisible();
      // Accessibility analysis uses normal timers after the controlled hover assertions.
      await page.clock.resume();
      // Visibility is restored before the dock's opacity/translate reveal settles.
      // Measure steady-state geometry and contrast without changing the motion or axe rules.
      await expect(dock).toHaveCSS("opacity", "1");
      await expect.poll(() => dock.evaluate((element) =>
        element.getAnimations().filter((animation) => animation.playState !== "finished").length
      )).toBe(0);
      expect(await dock.boundingBox()).toMatchObject({ x: 52, width: 48 });
      expect(await workspace.boundingBox()).toEqual(original);
      await expect(dock.getByRole("link", { name: "Shared documents", exact: true })).toHaveAttribute("title", "Shared documents");
      const accessibility = await new AxeBuilder({ page }).include("#workspace-navigation").analyze();
      expect(accessibility.violations).toEqual([]);
    });
  }
}

test("pinning reserves a sidebar after the activity rail and unpinning returns that space", async ({ page }) => {
  const dock = page.locator("#workspace-navigation");
  const workspace = page.locator(".workspace-grid");
  const rail = page.getByRole("navigation", { name: "Workspace shortcuts" });
  const toggle = page.getByRole("button", { name: "Toggle workspace navigation", exact: true });
  await expect(toggle).toHaveCount(1);
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  // Pin state commits before the dock's existing reveal transition finishes.
  await expect(dock).toHaveCSS("opacity", "1");
  await expect.poll(() => dock.evaluate((element) =>
    element.getAnimations().filter((animation) => animation.playState !== "finished").length
  )).toBe(0);
  expect(await dock.boundingBox()).toMatchObject({ x: 52, y: 44, width: 240 });
  expect(await workspace.boundingBox()).toMatchObject({ x: 292, y: 44, width: 1148 });
  expect(await rail.boundingBox()).toMatchObject({ x: 0, y: 44, width: 52 });
  await page.mouse.click(700, 200);
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  expect(await workspace.boundingBox()).toMatchObject({ x: 52, y: 44, width: 1388 });
  await page.mouse.move(700, 200);
  await page.clock.fastForward(8_300);
  await expect(dock).toBeHidden();
  await expect(rail).toBeVisible();
});

test("keyboard recovery, Escape and pinning keep navigation reachable", async ({ page }) => {
  const dock = page.locator("#workspace-navigation");
  await page.clock.fastForward(8_300);
  await expect(dock).toBeHidden();
  const reveal = page.getByRole("button", { name: "Show workspace navigation" });
  await reveal.focus();
  await page.keyboard.press("Enter");
  await page.clock.runFor(20);
  await expect(dock.getByRole("button", { name: "Switch conversation or screen", exact: true })).toBeFocused();
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dock).toBeHidden();
  await expect(dock).toHaveAttribute("aria-hidden", "true");
  await reveal.click();
  await page.clock.runFor(20);
  const toggle = page.getByRole("button", { name: "Toggle workspace navigation", exact: true });
  await toggle.click();
  await page.mouse.click(700, 200);
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await page.reload();
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
});

test("rail account survives dock idle and notification dialogs keep recovered navigation available", async ({ page }, testInfo) => {
  const dock = page.locator("#workspace-navigation");
  const accountTrigger = page.getByRole("button", { name: "Account menu for Ada Lovelace", exact: true });
  await expect(accountTrigger).toHaveCount(1);
  await accountTrigger.click();
  const account = page.getByRole("region", { name: "Signed-in account" });
  await expect(account).toBeVisible();
  await page.clock.fastForward(16_000);
  await expect(account).toBeVisible();
  await expect(dock).toBeHidden();
  const box = await account.boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(52);
  expect(box!.x + box!.width).toBeLessThanOrEqual(1440);
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.screenshot({ path: testInfo.outputPath("account.png") });
  }
  await page.keyboard.press("Escape");
  await expect(account).toBeHidden();
  await expect(accountTrigger).toBeFocused();
  await page.getByRole("button", { name: "Show workspace navigation", exact: true }).click();
  await page.clock.runFor(20);
  await expect(dock).toBeVisible();
  await page.getByRole("button", { name: /^Notifications/ }).click();
  await expect(page.getByRole("dialog", { name: "Notifications", exact: true })).toBeVisible();
  await page.clock.fastForward(16_000);
  await expect(dock).not.toHaveClass(/is-hidden/);
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog", { name: "Notifications", exact: true })).toBeHidden();
});

test("dark-mode controls retain a backplate over the white drawing canvas", async ({ page }, testInfo) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.route("**/whiteboard/operations*", (route) => route.fulfill({ json: {
    data: [], page: { has_more: false, next_after_sequence: 0 }
  } }));
  await page.goto("/app/whiteboard");
  await expect(page.locator(".k-comms-drawing-surface")).toBeVisible();
  const dock = page.locator("#workspace-navigation");
  await expect(dock).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  await expect(dock.getByRole("link", { name: "Shared documents", exact: true })).not.toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.screenshot({ path: testInfo.outputPath("whiteboard-dark.png") });
  }
  await page.mouse.click(700, 300);
  await expect(dock).toBeHidden();
});
