import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { activeVideoFixtureMarkup, conversationId, installDeterministicMediaDevices, installWorkspace } from "./mobile-ui-support";

async function loadCallStyles(page: Page) {
  await installWorkspace(page);
  await installDeterministicMediaDevices(page);
  await page.goto(`/app/?conversation=${conversationId}`);
  await page.getByRole("button", { name: "Start video call" }).click();
  await expect(page.getByRole("dialog", { name: "Start a video call" })).toBeVisible();
  const css = await page.evaluate(() => Array.from(document.styleSheets).flatMap(sheet => {
    try { return Array.from(sheet.cssRules, rule => rule.cssText); } catch { return []; }
  }).join("\n"));
  expect(css).toContain(".call-recording-status");
  // Discard the mounted application's async prejoin updates before replacing
  // its document with the explicit recording-state CSS fixture.
  await page.goto("about:blank");
  return css;
}

for (const status of ["pending_consent", "recording", "stopping"] as const) {
  for (const presentation of ["minimized", "idle"] as const) {
    test(`${presentation}: ${status} recording disclosure remains visible and keyboard reachable under the shipped call styles`, async ({ page }) => {
      const css = await loadCallStyles(page);
      await page.setContent(activeVideoFixtureMarkup({ experienceMode: "immersive", recordingStatus: status, minimized: presentation === "minimized", controlsCollapsed: presentation === "idle" }));
      await page.addStyleTag({ content: css });
      const cue = page.getByRole("button", { name: status === "pending_consent" ? "Review recording consent" : "Review active recording" });
      await expect(cue).toBeVisible();
      await expect(cue).toHaveCSS("visibility", "visible");
      await expect(cue.locator("..")).toHaveClass("call-critical-status");
      await cue.focus();
      await expect(cue).toBeFocused();
      const box = await cue.boundingBox();
      expect(box).not.toBeNull();
      expect(box!.height).toBeGreaterThanOrEqual(44);
      expect(box!.x).toBeGreaterThanOrEqual(0);
      expect(box!.x + box!.width).toBeLessThanOrEqual(await page.evaluate(() => innerWidth));
      await expect(page.getByRole("button", { name: "Leave call" })).toBeVisible();
      if (presentation === "idle") await expect(page.locator(".audio-call-dock-heading")).toHaveCSS("visibility", "hidden");
      const accessibility = await new AxeBuilder({ page }).include(".call-critical-status").withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
      expect(accessibility.violations).toEqual([]);
    });
  }
}
