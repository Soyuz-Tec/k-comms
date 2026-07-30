import { expect, test } from "./fixtures";
import {
  activeVideoFixtureMarkup,
  conversationId,
  expectMinimumTargets,
  expectNoDocumentOverflow,
  installDeterministicMediaDevices,
  installWorkspace
} from "./mobile-ui-support";

test.describe("mobile call acceptance", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== "chromium", "mobile call viewport checks run once");
    await installDeterministicMediaDevices(page);
  });

  test("video prejoin remains contained or independently scrollable on a short phone", async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 390, height: 640 });
    const fixture = await installWorkspace(page);
    await page.goto(`/app/?conversation=${conversationId}`);

    await page.getByRole("button", { name: "Start video call" }).click();
    const dialog = page.getByRole("dialog", { name: "Start a video call" });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("heading", { name: "Ready to join?" })).toBeVisible();
    await expect(dialog.getByText("Audio", { exact: true })).toBeVisible();
    await expect(dialog.getByText("Video", { exact: true })).toBeVisible();
    await expect(dialog.getByRole("checkbox", { name: "Use microphone when I join" })).toBeVisible();
    await expect(dialog.getByRole("checkbox", { name: "Use camera when I join" })).toBeVisible();
    await expect(page.locator("nav.mobile-product-nav")).toHaveCount(0);
    await expect(page.locator(".composer")).toBeHidden();
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({ path: testInfo.outputPath("video-prejoin-390.png"), fullPage: true });
    }
    await dialog.getByText("Device settings", { exact: true }).click();
    await expect(dialog.getByRole("combobox", { name: /^Microphone/ })).toBeAttached();
    await expect(dialog.getByRole("combobox", { name: /^Camera/ })).toBeAttached();

    const containment = await dialog.evaluate((element) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      const fits = rect.top >= -1 && rect.bottom <= window.innerHeight + 1;
      const scrollable = ["auto", "scroll"].includes(style.overflowY)
        && element.scrollHeight > element.clientHeight;
      return {
        fits,
        horizontallyContained: rect.left >= -1 && rect.right <= window.innerWidth + 1,
        scrollable
      };
    });

    expect(containment.horizontallyContained).toBe(true);
    expect(containment.fits || containment.scrollable).toBe(true);
    await expectNoDocumentOverflow(page);

    await dialog.getByRole("button", { name: "Cancel" }).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Start video call" })).toBeFocused();
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("active video uses the complete viewport with safe overlay controls", async ({
    page
  }, testInfo) => {
    const viewport = { width: 390, height: 844 };
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
    await page.setContent(activeVideoFixtureMarkup());
    await page.addStyleTag({ content: applicationCss });

    const call = page.locator(".video-call-screen");
    await expect.poll(
      () => call.evaluate((element) => window.getComputedStyle(element).position)
    ).toBe("fixed");

    for (const locator of [
      call,
      call.locator(".active-call-details"),
      call.locator(".call-stage"),
      call.locator(".video-participant-grid")
    ]) {
      const box = await locator.boundingBox();
      expect(box).not.toBeNull();
      expect(box!.x).toBeCloseTo(0, 0);
      expect(box!.y).toBeCloseTo(0, 0);
      expect(box!.width).toBeCloseTo(viewport.width, 0);
      expect(box!.height).toBeCloseTo(viewport.height, 0);
    }

    const edgeTreatment = await call.evaluate((element) => {
      const root = window.getComputedStyle(element);
      const grid = window.getComputedStyle(
        element.querySelector(".video-participant-grid")!
      );
      const tile = window.getComputedStyle(
        element.querySelector(".video-participant-tile")!
      );
      const header = window.getComputedStyle(
        element.querySelector(".audio-call-dock-heading")!
      );
      const actions = window.getComputedStyle(
        element.querySelector(".audio-call-actions")!
      );
      const label = window.getComputedStyle(
        element.querySelector(".call-action-label")!
      );
      const caption = window.getComputedStyle(
        element.querySelector(".video-participant-caption")!
      );
      return {
        rootBorder: root.borderTopWidth,
        rootPadding: root.paddingTop,
        rootRadius: root.borderTopLeftRadius,
        gridGap: grid.gap,
        gridOverflow: grid.overflowY,
        tileBorder: tile.borderTopWidth,
        tileRadius: tile.borderTopLeftRadius,
        headerPosition: header.position,
        actionsPosition: actions.position,
        labelSize: Number.parseFloat(label.fontSize),
        captionBottom: Number.parseFloat(caption.bottom)
      };
    });

    expect(edgeTreatment).toMatchObject({
      rootBorder: "0px",
      rootPadding: "0px",
      rootRadius: "0px",
      gridGap: "0px",
      gridOverflow: "hidden",
      tileBorder: "0px",
      tileRadius: "0px",
      headerPosition: "absolute",
      actionsPosition: "absolute"
    });
    expect(edgeTreatment.labelSize).toBeGreaterThanOrEqual(14);
    expect(edgeTreatment.captionBottom).toBeGreaterThan(100);

    const headingControls = call.locator(".call-dock-heading-actions > button");
    await expectMinimumTargets(headingControls, "active call window controls", 52);
    await expectNoDocumentOverflow(page);

    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: testInfo.outputPath("active-video-call-390.png"),
        fullPage: false
      });
    }

    await call.locator(".video-participant-grid").evaluate((grid) => {
      const tile = grid.querySelector(".video-participant-tile");
      if (!tile) throw new Error("video fixture tile is unavailable");
      for (let index = 1; index < 25; index += 1) {
        const clone = tile.cloneNode(true) as HTMLElement;
        clone.dataset.participantId = `participant-${index + 1}`;
        clone.querySelector("strong")!.textContent = `Person ${index + 1}`;
        grid.append(clone);
      }
    });
    const largeGrid = call.locator(".video-participant-grid");
    const largeCallLayout = await largeGrid.evaluate((grid) => {
      const style = window.getComputedStyle(grid);
      const tile = grid.querySelector<HTMLElement>(".video-participant-tile");
      return {
        overflowY: style.overflowY,
        scrollable: grid.scrollHeight > grid.clientHeight,
        tileHeight: tile?.getBoundingClientRect().height ?? 0
      };
    });
    expect(largeCallLayout.overflowY).toBe("auto");
    expect(largeCallLayout.scrollable).toBe(true);
    expect(largeCallLayout.tileHeight).toBeGreaterThanOrEqual(140);

    await call.locator(".active-call-details").evaluate((details) => {
      details.insertAdjacentHTML("beforeend", `
        <section class="call-workspace-sheet mobile-open">
          <header class="call-menu-header">
            <h3>Call menu</h3>
            <button class="app-surface-control app-menu-close" type="button">
              Close
            </button>
          </header>
          <nav class="call-collaboration-links">
            <button type="button">Chat</button>
            <button type="button">People</button>
          </nav>
          <div class="call-workspace-body">Call options</div>
          <div class="call-menu-secondary-actions">
            <button class="button" type="button">Hide labels</button>
            <button class="button danger" type="button">Leave call</button>
          </div>
        </section>
      `);
    });
    await page.addStyleTag({
      content: ":root { --safe-top: 24px; --safe-right: 10px; --safe-bottom: 20px; --safe-left: 8px; }"
    });
    const safeAreaLayout = await call.locator(".call-workspace-sheet").evaluate(
      (sheet) => {
        const close = sheet.querySelector("header button")!.getBoundingClientRect();
        const actions = sheet.querySelector(".call-menu-secondary-actions")!;
        const actionsStyle = window.getComputedStyle(actions);
        return {
          closeTop: close.top,
          bottomPadding: Number.parseFloat(actionsStyle.paddingBottom)
        };
      }
    );
    expect(safeAreaLayout.closeTop).toBeGreaterThanOrEqual(24);
    expect(safeAreaLayout.bottomPadding).toBeGreaterThanOrEqual(20);

    await call.locator(".call-stage").evaluate((stage) => {
      stage.insertAdjacentHTML("beforeend", `
        <div class="inline-notice" role="status">
          <span>Browser media playback is paused.</span>
          <button class="button ghost compact" type="button">Enable call media</button>
        </div>
      `);
      const stack = stage.querySelector(".video-track-stack");
      if (!stack) throw new Error("video track fixture is unavailable");
      stack.insertAdjacentHTML("afterbegin", `
        <div class="video-track-frame screen-share"></div>
        <div class="video-track-frame camera"></div>
      `);
    });
    await page.setViewportSize({ width: 812, height: 375 });
    await page.addStyleTag({
      content: ":root { --safe-top: 24px; --safe-right: 44px; --safe-bottom: 20px; --safe-left: 44px; }"
    });

    const notchedLandscape = await call.evaluate((element) => {
      const bounds = (selector: string) => {
        const rect = element.querySelector(selector)!.getBoundingClientRect();
        return { left: rect.left, right: rect.right };
      };
      return {
        caption: bounds(".video-participant-caption"),
        notice: bounds(".call-stage > .inline-notice"),
        pictureInPicture: bounds(".video-track-frame.camera")
      };
    });
    for (const overlay of Object.values(notchedLandscape)) {
      expect(overlay.left).toBeGreaterThanOrEqual(43);
      expect(overlay.right).toBeLessThanOrEqual(769);
    }

    await call.locator(".call-menu-secondary-actions").evaluate((actions) => {
      actions.insertAdjacentHTML(
        "beforeend",
        '<button class="button danger" type="button">End for everyone</button>'
      );
    });
    await page.setViewportSize({ width: 568, height: 320 });
    await page.addStyleTag({
      content: ":root { --safe-top: 0px; --safe-right: 0px; --safe-bottom: 0px; --safe-left: 0px; }"
    });
    const compactLandscapeMenu = await call.locator(".call-workspace-sheet").evaluate(
      (sheet) => {
        const body = sheet.querySelector(".call-workspace-body")!;
        const actions = sheet.querySelector(".call-menu-secondary-actions")!;
        const columns = window.getComputedStyle(actions).gridTemplateColumns
          .split(" ")
          .filter(Boolean);
        return {
          bodyHeight: body.getBoundingClientRect().height,
          actionColumns: columns.length,
          sheetOverflowY: window.getComputedStyle(sheet).overflowY
        };
      }
    );
    expect(compactLandscapeMenu.bodyHeight).toBeGreaterThanOrEqual(84);
    expect(compactLandscapeMenu.actionColumns).toBe(3);
    expect(compactLandscapeMenu.sheetOverflowY).toBe("auto");
  });
});
