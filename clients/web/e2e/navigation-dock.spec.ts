import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { installWorkspace } from "./mobile-ui-support";

test.beforeEach(async ({ page }, testInfo) => {
  test.skip(!["chromium", "webkit"].includes(testInfo.project.name), "Desktop dock coverage");
  await page.setViewportSize({ width: 1440, height: 900 });
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
      await expect(dock).toBeVisible();
      expect((await dock.boundingBox())!.width).toBe(48);
      await expect(dock).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
      const original = await workspace.boundingBox();
      expect(original!.x).toBe(0);
      expect(original!.width).toBe(width);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
        await page.screenshot({ path: testInfo.outputPath("compact.png") });
      }

      // Ordinary work and mouse movement outside the menu must not renew its timer.
      await page.mouse.move(700, 200);
      await page.clock.fastForward(4_000);
      await page.mouse.move(600, 260);
      await page.clock.fastForward(4_300);
      await expect(dock).toBeHidden();
      await expect(dock).toHaveAttribute("inert", "");
      expect(await workspace.boundingBox()).toEqual(original);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
        await page.screenshot({ path: testInfo.outputPath("hidden.png") });
      }

      // Crossing the edge briefly, or dragging to it, is not a menu request.
      await page.mouse.move(3, 180);
      await page.mouse.move(100, 180);
      await page.clock.fastForward(300);
      await expect(dock).toBeHidden();
      await page.mouse.down();
      await page.mouse.move(3, 180);
      await page.clock.fastForward(300);
      await expect(dock).toBeHidden();
      await page.mouse.up();
      await page.mouse.move(100, 180);
      await page.mouse.move(3, 180);
      await page.clock.fastForward(300);
      await expect(dock).toBeVisible();
      expect((await dock.boundingBox())!.width).toBe(48);
      expect(await workspace.boundingBox()).toEqual(original);
      await expect(dock.getByRole("link", { name: "Calls", exact: true })).toHaveAttribute("title", "Calls");
      const accessibility = await new AxeBuilder({ page }).include("#workspace-navigation").analyze();
      expect(accessibility.violations).toEqual([]);
    });
  }
}

test("keyboard recovery, Escape and pinning keep navigation reachable", async ({ page }) => {
  const dock = page.locator("#workspace-navigation");
  await page.clock.fastForward(8_300);
  await expect(dock).toBeHidden();
  const reveal = page.getByRole("button", { name: "Show workspace navigation" });
  await reveal.focus();
  await page.keyboard.press("Enter");
  await page.clock.runFor(20);
  const toggle = page.getByRole("button", { name: "Keep navigation open" });
  await expect(toggle).toBeFocused();
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dock).toBeHidden();
  await expect(dock).toHaveAttribute("aria-hidden", "true");
  await reveal.click();
  await page.clock.runFor(20);
  await toggle.click();
  await page.mouse.click(700, 200);
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  await expect(page.getByRole("button", { name: "Use compact navigation" })).toHaveAttribute("aria-pressed", "true");
  await page.reload();
  await expect(page.getByRole("button", { name: "Use compact navigation" })).toBeVisible();
});

test("account and notification popovers survive idle time", async ({ page }, testInfo) => {
  const dock = page.locator("#workspace-navigation");
  await page.locator(".workspace-account-trigger").click();
  const account = page.getByRole("region", { name: "Signed-in account" });
  await expect(account).toBeVisible();
  await page.clock.fastForward(16_000);
  await expect(dock).toBeVisible();
  const box = await account.boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(48);
  expect(box!.x + box!.width).toBeLessThanOrEqual(1440);
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.screenshot({ path: testInfo.outputPath("account.png") });
  }
  await page.keyboard.press("Escape");
  await expect(account).toBeHidden();
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
  await expect(dock.getByRole("link", { name: "Calls", exact: true })).not.toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.screenshot({ path: testInfo.outputPath("whiteboard-dark.png") });
  }
  await page.mouse.click(700, 300);
  await expect(dock).toBeHidden();
});
