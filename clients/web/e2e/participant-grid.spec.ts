import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { participantGridFixtureMarkup } from "./mobile-ui-support";

/*
 * Participant grid layout at the sizes the contract names.
 *
 * 1, 4 and 16 are ordinary. 49 is a stress target for the UI only: authenticated
 * room capacity comes from the server's admission policy, and nothing here
 * should be read as a claim that 49 participants are supported.
 *
 * These measure the shipped stylesheets against static markup, the same way the
 * stage geometry fixtures do, so no LiveKit session is needed to reach a call
 * with 49 people in it.
 */
const viewport = { width: 1440, height: 900 };

async function mountGrid(page: Page, tiles: number) {
  await page.setViewportSize(viewport);
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
  await page.setContent(participantGridFixtureMarkup(tiles, { experienceMode: "immersive" }));
  await page.addStyleTag({ content: applicationCss });
  await page.waitForTimeout(200);
  return page.locator(".video-participant-grid");
}

test.describe("participant grid", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== "chromium", "grid layout is measured once");
    await page.setViewportSize(viewport);
  });

  for (const tiles of [1, 4, 16, 49]) {
    test(`renders ${tiles} tile${tiles === 1 ? "" : "s"} without overflowing the page`, async ({
      page
    }) => {
      const grid = await mountGrid(page, tiles);
      await expect(grid.locator(".video-participant-tile")).toHaveCount(tiles);

      // The page itself must never scroll sideways, whatever the count.
      const overflow = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth
      }));
      expect(overflow.scrollWidth).toBeLessThanOrEqual(overflow.clientWidth + 1);

      // Every tile has real area. A grid that collapses a tile to nothing has
      // technically rendered it and shown the participant nothing.
      const boxes = await grid.locator(".video-participant-tile").evaluateAll((tilesInGrid) =>
        tilesInGrid.map((tile) => {
          const rect = tile.getBoundingClientRect();
          return { width: rect.width, height: rect.height };
        })
      );
      expect(boxes).toHaveLength(tiles);
      for (const box of boxes) {
        // "Non-zero" is too weak a bar: a 2-column grid at 49 participants
        // gives every tile 36px of height with the avatar clipped, which
        // renders all 49 and shows nobody. A tile has to be big enough to
        // carry a face and a name.
        expect(box.width).toBeGreaterThanOrEqual(120);
        expect(box.height).toBeGreaterThanOrEqual(80);
      }
    });
  }

  test("gives a single participant the stage rather than a half-width column", async ({ page }) => {
    const grid = await mountGrid(page, 1);
    const tile = await grid.locator(".video-participant-tile").first().boundingBox();
    const stage = await page.locator(".call-stage").boundingBox();
    // One participant should not be pinned into one of two columns.
    expect(tile!.width).toBeGreaterThan(stage!.width * 0.5);
  });

  test("keeps the stage itself the same size regardless of participant count", async ({ page }) => {
    // Participant count is content. It must not change the geometry of the
    // stage that contains it, or the overlay budgets measured against that
    // stage stop meaning anything.
    const sizes: { tiles: number; width: number; height: number }[] = [];
    for (const tiles of [1, 4, 16, 49]) {
      await mountGrid(page, tiles);
      const stage = await page.locator(".call-stage").boundingBox();
      sizes.push({ tiles, width: stage!.width, height: stage!.height });
    }
    const [first] = sizes;
    for (const size of sizes) {
      expect(Math.abs(size.width - first.width), `width at ${size.tiles}`).toBeLessThanOrEqual(1);
      expect(Math.abs(size.height - first.height), `height at ${size.tiles}`).toBeLessThanOrEqual(1);
    }
  });

  test("contains a 49-tile stress grid inside the stage rather than the page", async ({ page }) => {
    // 49 is a stress target, not a supported capacity. What matters is that
    // the overflow is contained and scrollable rather than pushing the call
    // controls off the viewport.
    const grid = await mountGrid(page, 49);
    await expect(grid.locator(".video-participant-tile")).toHaveCount(49);

    const contained = await page.evaluate(() => {
      const dock = document.querySelector(".audio-call-dock") as HTMLElement;
      const actions = document.querySelector(".audio-call-actions") as HTMLElement;
      const dockRect = dock.getBoundingClientRect();
      const actionsRect = actions.getBoundingClientRect();
      return {
        dockWithinViewport: dockRect.bottom <= window.innerHeight + 1,
        actionsWithinViewport: actionsRect.bottom <= window.innerHeight + 1,
        pageScrolls: document.documentElement.scrollHeight > document.documentElement.clientHeight + 1
      };
    });

    expect(contained.dockWithinViewport).toBe(true);
    // The controls must stay reachable: 49 tiles must not push Leave off-screen.
    expect(contained.actionsWithinViewport).toBe(true);
    expect(contained.pageScrolls).toBe(false);

    // The grid, not the page, absorbs the overflow.
    const gridScrolls = await grid.evaluate(
      (element) => element.scrollHeight > element.clientHeight + 1
    );
    const stageBox = await page.locator(".call-stage").boundingBox();
    expect(stageBox!.height).toBeLessThanOrEqual(viewport.height + 1);
    // Either everything fits, or the grid itself is the scroll container.
    expect(gridScrolls || stageBox!.height <= viewport.height).toBe(true);
  });
});
