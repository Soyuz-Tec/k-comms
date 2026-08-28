import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { activeVideoFixtureMarkup } from "./mobile-ui-support";

/*
 * Geometry of the Immersive ActiveContentStage, and of the legacy call
 * presentation it falls back to.
 *
 * The stage is pure layout, so it is tested the way the mobile call surface
 * already is: harvest the application's real stylesheets, set static markup
 * carrying the real class names, inject the CSS, and measure. That exercises
 * the shipped rules rather than a reimplementation of them, and needs no
 * LiveKit session to reach a joined call.
 */

const viewport = { width: 1440, height: 900 };

async function mountCall(page: Page, experienceMode?: "workspace" | "immersive") {
  await page.goto("/sign-in");
  const applicationCss = await page.evaluate(() =>
    Array.from(document.styleSheets)
      .flatMap((sheet) => {
        try {
          return Array.from(sheet.cssRules, (rule) => rule.cssText);
        } catch {
          return [];
        }
      })
      .join("\n")
  );
  expect(applicationCss.length).toBeGreaterThan(1_000);
  await page.setContent(activeVideoFixtureMarkup({ experienceMode }));
  await page.addStyleTag({ content: applicationCss });
  /*
   * .button transitions background and border-color over 160ms. Reading a
   * computed colour before that settles returns the value at t=0 -- the UA
   * default -- which looks exactly like a rule that failed to apply.
   */
  await page.waitForTimeout(400);
  return page.locator(".video-call-screen");
}

test.describe("immersive active content stage", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== "chromium", "stage geometry is measured once");
    await page.setViewportSize(viewport);
  });

  test("fills the visual viewport exactly, without browser fullscreen", async ({ page }) => {
    const call = await mountCall(page, "immersive");

    const box = await call.boundingBox();
    expect(box).not.toBeNull();
    // Exactly the viewport: no inset, no max-width cap, no rounding slack.
    expect(box!.x).toBe(0);
    expect(box!.y).toBe(0);
    expect(box!.width).toBe(viewport.width);
    expect(box!.height).toBe(viewport.height);

    // Immersive is in-tab. Nothing here may depend on the Fullscreen API.
    expect(await page.evaluate(() => document.fullscreenElement)).toBeNull();
  });

  test("keeps chrome off the stage's layout, not merely out of sight", async ({ page }) => {
    const call = await mountCall(page, "immersive");

    // §4.1: no permanent top bar or control row consumes stage layout space.
    // Absolutely positioned boxes cannot resize their containing block, which
    // is what makes §8.2's "reveal changes the stage box by <= 1px" hold by
    // construction rather than by assertion.
    for (const selector of [".audio-call-dock-heading", ".audio-call-actions"]) {
      expect(
        await call.locator(selector).evaluate((el) => getComputedStyle(el).position)
      ).toBe("absolute");
    }

    // The media plane therefore gets the whole stage, and the overlays sit on
    // top of it rather than above and below it.
    const stage = await call.locator(".call-stage").boundingBox();
    const heading = await call.locator(".audio-call-dock-heading").boundingBox();
    expect(stage!.height).toBe(viewport.height);
    expect(heading!.y).toBeLessThan(stage!.y + heading!.height);
  });

  test("leaves the legacy presentation inset and capped when not immersive", async ({ page }) => {
    // The contract's fallback is "the current production call presentation",
    // so the absence of the mode must change nothing about it.
    const call = await mountCall(page);

    const box = await call.boundingBox();
    expect(box!.x).toBeGreaterThan(0);
    expect(box!.y).toBeGreaterThan(0);
    expect(box!.width).toBeLessThan(viewport.width);
    expect(box!.height).toBeLessThan(viewport.height);

    // And the heading still occupies its own row rather than floating.
    expect(
      await call
        .locator(".audio-call-dock-heading")
        .evaluate((el) => getComputedStyle(el).position)
    ).not.toBe("absolute");
  });

  test("meets WCAG A and AA on the stage, including contrast on media", async ({ page }) => {
    // The stage puts text and controls on the media ramp rather than the
    // workspace one, so its contrast is a separate question from every other
    // surface the suite already checks.
    await mountCall(page, "immersive");
    const results = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
      .analyze();
    expect(
      results.violations.map(({ id, impact, nodes }) => ({
        id,
        impact,
        targets: nodes.map((node) => node.target)
      }))
    ).toEqual([]);
  });

  test("keeps the stage usable in forced colors", async ({ page }) => {
    // Forced colors replaces every author colour, so the stage must not
    // depend on its own fills to stay readable or operable.
    await page.emulateMedia({ forcedColors: "active" });
    const call = await mountCall(page, "immersive");

    await expect(call.getByRole("button", { name: "Minimize" })).toBeVisible();
    for (const label of ["Mic", "Camera", "Screen", "People", "Leave"]) {
      await expect(call.getByRole("button", { name: label })).toBeVisible();
    }
    await expect(call.getByRole("heading", { name: "Instant room" })).toBeVisible();
  });

  test("does not pull a minimized call into the stage", async ({ page }) => {
    // A minimized call is the Workspace companion, wherever the mode says we
    // are. Immersive must not drag the capsule into the middle of the screen.
    const call = await mountCall(page, "immersive");
    await call.evaluate((element) => element.classList.add("minimized"));

    const box = await call.boundingBox();
    expect(box!.width).toBeLessThan(viewport.width);
    expect(box!.height).toBeLessThan(viewport.height);
  });
});
