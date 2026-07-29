import { expect, mockServiceStatus, test } from "./fixtures";
import type { Locator, Page, Route } from "@playwright/test";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const messageId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

const viewportCases = [
  { width: 320, height: 640 },
  { width: 390, height: 844 },
  { width: 700, height: 900 }
] as const;

test.describe("authenticated mobile web acceptance", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== "chromium", "explicit mobile viewport matrix runs once");
    await installDeterministicMediaDevices(page);
  });

  for (const viewport of viewportCases) {
    test(`${viewport.width}px supports list, messaging, account and product navigation`, async ({ page }, testInfo) => {
      await page.setViewportSize(viewport);
      const fixture = await installWorkspace(page);

      await page.goto("/app/");
      await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
      await expect(page.getByRole("button", { name: "Create conversation" })).toContainText("New");
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(page.getByRole("button", { name: "Open main menu" })).toBeVisible();
      await expect(page.locator("nav.mobile-product-nav")).toHaveCount(0);
      await expect(page.locator("nav.product-nav")).toBeHidden();
      await exposeInstallPrompt(page);
      await expectNoDocumentOverflow(page);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && viewport.width === 390) {
        await page.screenshot({ path: testInfo.outputPath("inbox-390.png"), fullPage: true });
      }

      const conversation = page.getByRole("button", { name: /General/ });
      await expectMinimumTarget(conversation, "conversation row");
      const menuTrigger = page.getByRole("button", { name: "Open main menu" });
      const notificationTrigger = page.getByRole("button", { name: "Notifications" });
      await expectMinimumTarget(menuTrigger, "main menu control");
      await expectMinimumTarget(notificationTrigger, "notification control");
      const menuTriggerBox = await menuTrigger.boundingBox();
      const notificationTriggerBox = await notificationTrigger.boundingBox();
      expect(menuTriggerBox).not.toBeNull();
      expect(notificationTriggerBox).not.toBeNull();
      expect(menuTriggerBox!.width).toBeGreaterThanOrEqual(52);
      expect(menuTriggerBox!.height).toBeGreaterThanOrEqual(52);
      expect(menuTriggerBox!.x).toBeGreaterThan(notificationTriggerBox!.x);
      expect(menuTriggerBox!.x + menuTriggerBox!.width)
        .toBeLessThanOrEqual(viewport.width + 1);

      await menuTrigger.click();
      const productMenu = page.getByRole("dialog", { name: "Acme Workspace" });
      await expect(productMenu).toBeVisible();
      const productMenuBox = await productMenu.boundingBox();
      expect(productMenuBox).not.toBeNull();
      expect(Math.abs(
        productMenuBox!.x + productMenuBox!.width - viewport.width
      )).toBeLessThanOrEqual(1);
      await expectMinimumTargets(
        productMenu.getByRole("navigation", { name: "All product areas" }).locator("a"),
        "all product menu"
      );
      await expect(productMenu.getByRole("link", { name: "Workspace administration" })).toBeVisible();
      await expect(productMenu.getByRole("link", { name: "Service operations" })).toBeVisible();
      await expect(productMenu.getByRole("button", { name: "Install K-Comms" })).toBeVisible();
      await expect(productMenu.getByRole("button", { name: "Sign out" })).toBeVisible();
      await expectMinimumTargets(
        productMenu.locator("a, button"),
        "complete mobile menu",
        52
      );
      const closeMainMenu = productMenu.getByRole("button", {
        name: "Close main menu"
      });
      const closeMainMenuBox = await closeMainMenu.boundingBox();
      expect(closeMainMenuBox).not.toBeNull();
      expect(closeMainMenuBox!.width).toBeGreaterThanOrEqual(52);
      expect(closeMainMenuBox!.height).toBeGreaterThanOrEqual(52);
      await expectNoDocumentOverflow(page);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && viewport.width === 390) {
        await page.screenshot({ path: testInfo.outputPath("menu-390.png"), fullPage: true });
      }
      await closeMainMenu.click();
      await expect(productMenu).toHaveCount(0);
      await expect(menuTrigger).toBeFocused();
      await menuTrigger.click();
      await page.keyboard.press("Escape");
      await expect(productMenu).toHaveCount(0);
      await expect(menuTrigger).toBeFocused();

      await notificationTrigger.click();
      const notificationDialog = page.getByRole("dialog", { name: "Notifications" });
      await expect(notificationDialog).toBeVisible();
      const notificationBox = await notificationDialog.boundingBox();
      expect(notificationBox).not.toBeNull();
      expect(notificationBox!.y).toBeGreaterThanOrEqual(0);
      expect(notificationBox!.x).toBeGreaterThanOrEqual(0);
      expect(notificationBox!.x + notificationBox!.width).toBeLessThanOrEqual(viewport.width + 1);
      expect(notificationBox!.y + notificationBox!.height).toBeLessThanOrEqual(viewport.height + 1);
      expect(notificationBox!.height).toBeGreaterThan(viewport.height * .6);
      await expectNoDocumentOverflow(page);
      const finalNotification = notificationDialog.getByText("Mobile notification 18", { exact: true });
      await expect(finalNotification).toBeAttached();
      await finalNotification.scrollIntoViewIfNeeded();
      await expect(finalNotification).toBeInViewport();
      const notificationScroll = await notificationDialog.evaluate((element) => ({
        overflowY: window.getComputedStyle(element).overflowY,
        scrollable: element.scrollHeight > element.clientHeight,
        scrollTop: element.scrollTop
      }));
      expect(["auto", "scroll"]).toContain(notificationScroll.overflowY);
      expect(notificationScroll.scrollable).toBe(true);
      expect(notificationScroll.scrollTop).toBeGreaterThan(0);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && viewport.width === 390) {
        await page.screenshot({ path: testInfo.outputPath("notifications-390.png"), fullPage: true });
      }
      await expectMinimumTarget(
        notificationDialog.getByRole("button", { name: "Close notifications" }),
        "notification close control"
      );
      await notificationDialog.getByRole("button", { name: "Close notifications" }).click();
      await expect(notificationDialog).toHaveCount(0);
      await expect(notificationTrigger).toBeFocused();

      await page.waitForTimeout(650);
      expect(fixture.readCursorRequests).toBe(0);

      await page.goto(`/app/?conversation=${conversationId}`);
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-messages/);
      await expect(page.getByText("Mobile-ready message body", { exact: true })).toBeVisible();
      await expect(page.locator("nav.mobile-product-nav")).toHaveCount(0);
      const moreMessageActions = page.getByRole("button", { name: "More message actions" });
      await expectMinimumTarget(moreMessageActions, "more-message-actions control");
      await moreMessageActions.click();
      const messageActions = page.locator(".message-actions");
      await expect(messageActions.getByRole("button", { name: "Start thread" })).toBeVisible();
      await expect(messageActions.getByRole("button", { name: "Reply" })).toBeVisible();
      await expect(messageActions.getByRole("button", { name: "Report" })).toBeVisible();
      await expect(messageActions.getByRole("button", { name: "Edit" })).toBeVisible();
      await expect(messageActions.getByRole("button", { name: "Delete" })).toBeVisible();
      await expectMinimumTargets(messageActions.locator("button"), "own-message actions");
      await expectNoHorizontalOverflow(page.locator(".message-scroll"), "message scroller");

      const back = page.getByRole("button", { name: "Back to conversations" });
      const startAudio = page.getByRole("button", { name: "Start audio call" });
      const startVideo = page.getByRole("button", { name: "Start video call" });
      const details = page.getByRole("button", { name: "Details" });
      const attachment = page.locator(".composer .attachment-button");
      const mention = page.locator(".composer .mention-trigger");
      const send = page.locator(".composer .send-button");

      await expectMinimumTarget(back, "conversation back control");
      await expectMinimumTarget(startAudio, "audio-call control");
      await expectMinimumTarget(startVideo, "video-call control");
      await expectMinimumTarget(details, "conversation details control");
      await expectMinimumTarget(attachment, "attachment control");
      await expectMinimumTarget(mention, "mention control");
      await expectMinimumTarget(send, "send control");
      await moreMessageActions.click();
      await expectNoDocumentOverflow(page);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && viewport.width === 390) {
        await page.screenshot({ path: testInfo.outputPath("conversation-390.png"), fullPage: true });
      }
      await expect.poll(() => fixture.readCursorRequests).toBeGreaterThan(0);

      await back.click();
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(conversation).toBeVisible();
      await expect(conversation).toBeFocused();

      await page.getByRole("button", { name: "Open main menu" }).click();
      await page.getByRole("dialog", { name: "Acme Workspace" }).getByRole("link", { name: "You" }).click();
      await expect(page.getByRole("heading", { name: "Profile and settings" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
      await page.addStyleTag({ content: "html { overflow-y: scroll; scrollbar-gutter: stable; }" });
      await expectNoDocumentOverflow(page);

      await page.getByRole("button", { name: "Open main menu" }).click();
      await page.getByRole("dialog", { name: "Acme Workspace" }).getByRole("link", { name: "Workspace administration" }).click();
      await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Tenant settings" })).toBeVisible();
      await expectNoDocumentOverflow(page);

      await page.getByRole("button", { name: "Open main menu" }).click();
      await page.getByRole("dialog", { name: "Acme Workspace" }).getByRole("link", { name: "Service operations" }).click();
      await expect(page.getByRole("heading", { name: "Service operations" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Operations triage" })).toBeVisible();
      await expectNoDocumentOverflow(page);
      expect(fixture.unexpectedRequests).toEqual([]);
    });
  }

  test("desktop notification portal remains beside the workspace rail", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installWorkspace(page);
    await page.goto("/app/");

    const rail = page.getByRole("complementary", { name: "Workspace navigation" });
    const trigger = page.getByRole("button", { name: /Notifications/ });
    await expect(rail).toBeVisible();
    const railBox = await rail.boundingBox();
    await trigger.click();

    const dialog = page.getByRole("dialog", { name: "Notifications" });
    await expect(dialog).toBeVisible();
    const dialogBox = await dialog.boundingBox();
    expect(railBox).not.toBeNull();
    expect(dialogBox).not.toBeNull();
    expect(dialogBox!.x).toBeGreaterThanOrEqual(railBox!.x + railBox!.width);
    expect(dialogBox!.x + dialogBox!.width).toBeLessThanOrEqual(1281);
    expect(Math.abs((dialogBox!.y + dialogBox!.height) - (800 - 16))).toBeLessThanOrEqual(2);
    await expectNoDocumentOverflow(page);
  });

  test("short landscape phones keep the hamburger and contain long workspace names", async ({ page }) => {
    const longWorkspaceName = "Workspace".repeat(15);
    await page.setViewportSize({ width: 844, height: 390 });
    await installWorkspace(page, { tenantName: longWorkspaceName });
    await page.goto("/app/");

    const trigger = page.getByRole("button", { name: "Open main menu" });
    await expect(trigger).toBeVisible();
    await expect(page.getByRole("complementary", { name: "Workspace navigation" })).toHaveCount(0);
    await trigger.click();

    const menu = page.getByRole("dialog", { name: longWorkspaceName });
    await expect(menu).toBeVisible();
    await expectMinimumTargets(menu.locator("a, button"), "landscape mobile menu");
    await expectNoDocumentOverflow(page);

    await page.setViewportSize({ width: 1280, height: 800 });
    await expect(menu).toHaveCount(0);
    await page.setViewportSize({ width: 844, height: 390 });
    await expect(page.getByRole("dialog")).toHaveCount(0);
  });

  test("browser history closes an open mobile menu", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await installWorkspace(page);
    await page.goto("/app/");
    await page.goto("/app/you");
    await page.getByRole("button", { name: "Open main menu" }).click();
    await expect(page.getByRole("dialog", { name: "Acme Workspace" })).toBeVisible();

    await page.goBack();

    await expect(page).toHaveURL(/\/app\/$/);
    await expect(page.getByRole("dialog", { name: "Acme Workspace" })).toHaveCount(0);
  });

  for (const viewport of [
    { width: 320, height: 640 },
    { width: 390, height: 844 }
  ]) {
    test(`phone sign-in exposes one complete task at ${viewport.width}px`, async ({ page }) => {
      await page.setViewportSize(viewport);
      await page.route("**/api/v1/status", (route) =>
        json(route, mockServiceStatus())
      );

      await page.goto("/sign-in");
      const heading = page.getByRole("heading", { name: "Sign in to your workspace" });
      const workspace = page.getByRole("textbox", { name: "Workspace address" });
      const submit = page.getByRole("button", { name: "Sign in" });
      await expect(heading).toBeVisible();
      await expect(workspace).toBeVisible();
      await expect(submit).toBeVisible();

      const headingBox = await heading.boundingBox();
      const submitBox = await submit.boundingBox();
      expect(headingBox).not.toBeNull();
      expect(submitBox).not.toBeNull();
      expect(headingBox!.y).toBeLessThan(220);
      expect(submitBox!.y + submitBox!.height).toBeLessThanOrEqual(viewport.height);
      expect(submitBox!.height).toBeGreaterThanOrEqual(44);
      await expectNoDocumentOverflow(page);
    });
  }

  test("all onboarding paths remain visible in the first 320px phone view", async ({ page }) => {
    const controlledInputErrors: string[] = [];
    page.on("console", (message) => {
      if (
        message.type() === "error"
        && message.text().includes("controlled input to be uncontrolled")
      ) {
        controlledInputErrors.push(message.text());
      }
    });
    await page.setViewportSize({ width: 320, height: 720 });
    await page.route("**/api/v1/status", (route) =>
      json(route, mockServiceStatus({ bootstrap: true }))
    );

    await page.goto("/sign-in");
    const actions = page.getByRole("group", { name: "Other ways to continue" });
    const invitation = actions.getByRole("button", { name: "Use invitation code" });
    const setup = actions.getByRole("button", { name: "Create workspace" });

    await expect(actions).toBeVisible();
    await expectMinimumTarget(invitation, "invitation entry");
    await expectMinimumTarget(setup, "workspace setup entry");
    await expect(setup).toBeInViewport({ ratio: 0.99 });
    await expectNoDocumentOverflow(page);

    await setup.click();
    await expect(page.getByRole("heading", { name: "Create your workspace" })).toBeVisible();
    await expect(page.getByLabel("Workspace name")).toBeVisible();
    expect(controlledInputErrors).toEqual([]);
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
  });
});

function activeVideoFixtureMarkup() {
  return `<!doctype html>
    <html>
      <head>
      </head>
      <body>
        <main class="app-shell">Workspace beneath the call</main>
        <section class="call-dock audio-call-dock active-call-screen video-call-dock video-call-screen" data-call-control-labels="visible">
          <div class="audio-call-dock-heading">
            <div class="call-heading-summary">
              <h2 class="call-room-title">Instant room</h2>
              <div class="call-progress-meta">
                <span class="call-progress-duration">04:18</span>
                <span class="call-progress-separator">·</span>
                <span class="call-participant-count">1 participant</span>
              </div>
            </div>
            <div class="call-dock-heading-actions app-surface-control-cluster">
              <button class="button ghost compact app-surface-control" type="button" aria-label="Minimize">${callFixtureIcon("minimize")}</button>
              <button class="button ghost compact app-menu-trigger app-menu-trigger-overlay" type="button" aria-label="Open call menu">${callFixtureIcon("menu")}</button>
            </div>
          </div>
          <div class="active-call-details">
            <section class="call-stage">
              <div class="video-participant-grid participant-count-1">
                <article class="video-participant-tile" data-participant-id="participant-1">
                  <div class="video-track-stack">
                    <div class="video-placeholder">
                      <span>AL</span>
                      <small>Camera off</small>
                    </div>
                  </div>
                  <div class="video-participant-caption">
                    <strong>Ada Lovelace (you)</strong>
                  </div>
                </article>
              </div>
            </section>
            <div class="audio-call-actions">
              ${["Mic", "Camera", "Screen", "People", "Leave"].map((label) => `
                <button class="button compact ${label === "Leave" ? "danger call-action-leave" : "ghost"}" type="button">
                  <span class="call-action-glyph" aria-hidden="true">${callFixtureIcon(label.toLowerCase())}</span>
                  <span class="call-action-label">${label}</span>
                </button>
              `).join("")}
            </div>
          </div>
        </section>
      </body>
    </html>`;
}

function callFixtureIcon(name: string) {
  const paths: Record<string, string> = {
    minimize: `
      <polyline points="4 14 10 14 10 20"></polyline>
      <polyline points="20 10 14 10 14 4"></polyline>
      <line x1="14" x2="21" y1="10" y2="3"></line>
      <line x1="3" x2="10" y1="21" y2="14"></line>`,
    menu: `
      <line x1="4" x2="20" y1="6" y2="6"></line>
      <line x1="4" x2="20" y1="12" y2="12"></line>
      <line x1="4" x2="20" y1="18" y2="18"></line>`,
    mic: `
      <rect x="9" y="2" width="6" height="12" rx="3"></rect>
      <path d="M5 10a7 7 0 0 0 14 0M12 17v5M8 22h8"></path>`,
    camera: `
      <rect x="3" y="6" width="13" height="12" rx="2"></rect>
      <path d="m16 10 5-3v10l-5-3z"></path>`,
    screen: `
      <rect x="2" y="3" width="20" height="14" rx="2"></rect>
      <path d="M8 21h8M12 17v4"></path>`,
    people: `
      <circle cx="9" cy="8" r="3"></circle>
      <circle cx="17" cy="9" r="2"></circle>
      <path d="M3 20a6 6 0 0 1 12 0M15 15a5 5 0 0 1 6 5"></path>`,
    leave: `
      <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 2 .7 2.8a2 2 0 0 1-.4 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z"></path>
      <path d="m2 2 20 20"></path>`
  };
  return `<svg class="app-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${paths[name] ?? ""}</svg>`;
}

async function installWorkspace(
  page: Page,
  options: { tenantName?: string } = {}
) {
  const state = { readCursorRequests: 0, unexpectedRequests: [] as string[] };
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3_600,
    received_at: Date.now(),
    tenant: {
      id: tenantId,
      name: options.tenantName || "Acme Workspace",
      slug: "acme",
      status: "active"
    },
    user: {
      id: userId,
      tenant_id: tenantId,
      display_name: "Ada Lovelace",
      email: "ada@example.test",
      account_type: "human",
      role: "owner",
      platform_role: "platform_operator",
      platform_role_expires_at: "2099-01-01T00:00:00Z",
      status: "active",
      version: 1
    },
    device: {
      id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      user_id: userId,
      name: "Mobile browser",
      platform: "web",
      last_seen_at: "2026-07-15T12:00:00Z"
    }
  };
  const conversation = {
    id: conversationId,
    tenant_id: tenantId,
    kind: "channel",
    title: "General",
    visibility: "tenant",
    latest_sequence: 1,
    last_read_sequence: 0,
    unread_count: 1,
    version: 1,
    inserted_at: "2026-07-15T12:00:00Z",
    updated_at: "2026-07-15T12:00:00Z"
  };
  const message = {
    id: messageId,
    tenant_id: tenantId,
    conversation_id: conversationId,
    sender_user_id: userId,
    sender_device_id: session.device.id,
    client_message_id: "mobile-message-1",
    conversation_sequence: 1,
    body: "Mobile-ready message body",
    metadata: {},
    status: "active",
    thread_root_message_id: null,
    thread_reply_count: 0,
    mentioned_user_ids: [],
    inserted_at: "2026-07-15T12:00:00Z",
    attachments: [],
    reactions: []
  };
  const capabilities = {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_public_channels: true,
    message_edit_window_seconds: 900,
    max_attachment_bytes: 25_000_000
  };
  const notifications = Array.from({ length: 18 }, (_, index) => ({
    id: `mobile-notification-${index + 1}`,
    event_type: "message.created.v1",
    title: `Mobile notification ${index + 1}`,
    body: `Notification body ${index + 1} verifies the scrollable phone drawer.`,
    conversation_id: conversationId,
    message_id: messageId,
    action_url: null,
    read_at: null,
    inserted_at: `2026-07-15T12:${String(index).padStart(2, "0")}:00Z`
  }));

  await page.addInitScript(({ storedSession, onboardingKey }) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(storedSession));
    localStorage.setItem(onboardingKey, "dismissed");
  }, {
    storedSession: session,
    onboardingKey: `k-comms:onboarding:${tenantId}:${userId}`
  });

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (method === "GET" && path === "/api/v1/me") {
      return json(route, { tenant: session.tenant, user: session.user, device: session.device, capabilities });
    }
    if (method === "GET" && path === "/api/v1/status") {
      return json(route, mockServiceStatus({
        push_notifications: false,
        realtime: false
      }));
    }
    if (method === "GET" && path === "/api/v1/users") return json(route, { data: [session.user] });
    if (method === "GET" && path === "/api/v1/conversations") return json(route, { data: [conversation] });
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/members`) {
      return json(route, { data: [{ id: "membership-1", role: "owner", joined_at: "2026-07-15T12:00:00Z", last_read_sequence: 0, user: session.user }] });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/messages`) {
      return json(route, { data: [message], page: { has_more: false, next_after_sequence: null, reset_required: false } });
    }
    if (method === "PUT" && path === `/api/v1/conversations/${conversationId}/read-cursor`) {
      state.readCursorRequests += 1;
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/call`) return json(route, { data: null });
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, {
        data: notifications,
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: notifications.length }
      });
    }
    if (method === "GET" && path === "/api/v1/me/devices") return json(route, { data: [session.device] });
    if (method === "GET" && path === "/api/v1/me/sessions") {
      return json(route, { data: [{ id: "session-1", user_id: userId, device_id: session.device.id, expires_at: "2099-01-01T00:00:00Z", last_used_at: "2026-07-15T12:00:00Z", revoked_at: null, inserted_at: "2026-07-15T12:00:00Z" }] });
    }
    if (method === "GET" && path === "/api/v1/notification-preferences") {
      return json(route, { data: { email_enabled: true, push_enabled: false, in_app_enabled: true, muted_event_types: [], updated_at: "2026-07-15T12:00:00Z" } });
    }
    if (method === "GET" && path === "/api/v1/notifications") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/notification-attempts") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/me/push-subscriptions/config") return json(route, { data: { available: false } });
    if (method === "GET" && path === "/api/v1/me/push-subscriptions") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/admin/tenant") return json(route, { data: tenantAdministration(session.tenant) });
    if (method === "GET" && path === "/api/v1/admin/invitations") return json(route, { data: [] });
    if (method === "GET" && path === "/api/v1/platform/ops") return json(route, { data: operationsSnapshot() });
    if (method === "DELETE" && path === "/api/v1/sessions/current") return route.fulfill({ status: 204 });

    state.unexpectedRequests.push(`${method} ${path}`);
    return json(route, { error: { code: "unexpected_mobile_test_request", detail: `${method} ${path}` } }, 501);
  });

  return state;
}

async function installDeterministicMediaDevices(page: Page) {
  await page.addInitScript(() => {
    if (!navigator.mediaDevices) return;
    const devices = [
      { deviceId: "microphone-1", groupId: "mobile-test", kind: "audioinput", label: "Test microphone", toJSON() { return this; } },
      { deviceId: "camera-1", groupId: "mobile-test", kind: "videoinput", label: "Test camera", toJSON() { return this; } }
    ];
    Object.defineProperty(navigator.mediaDevices, "enumerateDevices", {
      configurable: true,
      value: async () => devices
    });
  });
}

async function exposeInstallPrompt(page: Page) {
  // Route-mocked specs block workers; the PWA spec separately proves the real
  // worker while this event keeps the install-menu acceptance deterministic.
  await page.evaluate(() => {
    const installPrompt = new Event("beforeinstallprompt", {
      cancelable: true
    });
    Object.assign(installPrompt, {
      prompt: () => Promise.resolve(),
      userChoice: Promise.resolve({
        outcome: "dismissed",
        platform: "web"
      })
    });
    window.dispatchEvent(installPrompt);
  });
}

async function expectNoDocumentOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => Math.max(
    document.documentElement.scrollWidth,
    document.body.scrollWidth
  ) - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
}

async function expectNoHorizontalOverflow(locator: Locator, label: string) {
  await expect(locator, `${label} should be visible`).toBeVisible();
  const overflow = await locator.evaluate((element) => element.scrollWidth - element.clientWidth);
  expect(overflow, `${label} should not scroll horizontally`).toBeLessThanOrEqual(1);
}

async function expectMinimumTarget(locator: Locator, label: string) {
  await expect(locator, `${label} should be visible`).toBeVisible();
  const box = await locator.boundingBox();
  expect(box, `${label} should have a rendered box`).not.toBeNull();
  expect(box!.width, `${label} width`).toBeGreaterThanOrEqual(44);
  expect(box!.height, `${label} height`).toBeGreaterThanOrEqual(44);
}

async function expectMinimumTargets(
  locator: Locator,
  label: string,
  minimumSize = 44
) {
  const boxes = await locator.evaluateAll((elements) => elements
    .filter((element) => element.getClientRects().length > 0)
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return { width: rect.width, height: rect.height, text: element.textContent?.trim() || element.getAttribute("aria-label") || "control" };
    }));
  expect(boxes.length, `${label} should expose visible controls`).toBeGreaterThan(0);
  for (const box of boxes) {
    expect(box.width, `${label} ${box.text} width`).toBeGreaterThanOrEqual(minimumSize);
    expect(box.height, `${label} ${box.text} height`).toBeGreaterThanOrEqual(minimumSize);
  }
}

function tenantAdministration(tenant: Record<string, unknown>) {
  const limits = { max_active_users: 500, max_active_conversations: 2_000, max_conversation_members: 250 };
  const flags = { active_users: false, active_conversations: false, conversation_members: false, any: false };
  return {
    tenant,
    settings: {
      tenant_id: tenantId,
      allow_audio_calls: true,
      allow_video_calls: true,
      allow_public_channels: true,
      message_edit_window_seconds: 900,
      max_attachment_bytes: 25_000_000,
      default_retention_days: 365,
      ...limits,
      version: 1
    },
    usage: { active_users: 1, active_conversations: 1, largest_conversation_members: 1, limits, at_capacity: flags, over_limit: flags }
  };
}

function operationsSnapshot() {
  return {
    generated_at: "2026-07-15T12:00:00Z",
    release_revision: "a".repeat(40),
    database: { status: "ready" },
    outbox: { pending: 0, published: 12 },
    notifications: {},
    webhooks: {},
    attachments: {},
    queues: [],
    providers: { notifications: { status: "ready" }, webhooks: { status: "ready" }, attachment_scanner: { status: "ready" } }
  };
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, json: body });
}
