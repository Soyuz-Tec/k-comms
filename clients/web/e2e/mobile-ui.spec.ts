import { expect, mockServiceStatus, test } from "./fixtures";
import {
  conversationId,
  expectMinimumTarget,
  expectMinimumTargets,
  expectNoDocumentOverflow,
  expectNoDocumentVerticalOverflow,
  expectNoHorizontalOverflow,
  exposeInstallPrompt,
  installDeterministicMediaDevices,
  installWorkspace,
  json,
  viewportCases
} from "./mobile-ui-support";

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
      /*
       * Nothing sits above the content on a phone. The bar that used to name
       * the surface resolved its title from the pathname, so inside a
       * conversation — addressed by query string — it said "Inbox" while you
       * read a room. The highlighted tab names the destination instead, and the
       * page heading stays in the accessibility tree.
       */
      await expect(page.locator(".app-shell > .topbar")).toHaveCount(0);
      await expect(page.locator(".mobile-workspace-heading")).toHaveCount(0);
      await expect(page.getByRole("heading", { name: "Inbox" })).toBeAttached();
      await expect(page.getByRole("button", { name: "Create conversation" })).toContainText("New");
      await expect(page.getByRole("button", { name: "Search messages" })).toBeVisible();
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(page.getByRole("button", { name: "Open more menu" })).toHaveCount(0);
      const primaryNavigation = page.getByRole("navigation", { name: "Primary navigation" });
      await expect(primaryNavigation.locator("a")).toHaveCount(5);
      await expect(primaryNavigation.getByRole("link", { name: "Whiteboard" })).toHaveCount(0);
      await expectMinimumTargets(primaryNavigation.locator("a"), "primary navigation");
      await expect(page.locator("nav.mobile-product-nav")).toHaveCount(0);
      await expect(page.locator("nav.product-nav")).toBeHidden();
      await exposeInstallPrompt(page);
      await expectNoDocumentOverflow(page);
      await expectNoDocumentVerticalOverflow(page);
      await expect(page.locator(".inbox-filter-trigger .lucide-compass")).toBeVisible();
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && [390, 513].includes(viewport.width)) {
        await page.screenshot({ path: testInfo.outputPath(`inbox-${viewport.width}.png`), fullPage: true });
      }

      const conversation = page.getByRole("button", { name: /General/ });
      await expectMinimumTarget(conversation, "conversation row");
      /*
       * Notifications moved out of the deleted top bar and into the inbox,
       * which is the surface every notification is already about. They keep a
       * 52px target and stay inside the viewport.
       */
      const notificationTrigger = page.getByRole("button", { name: "Notifications" });
      await expectMinimumTarget(notificationTrigger, "notification control");
      const notificationTriggerBox = await notificationTrigger.boundingBox();
      expect(notificationTriggerBox).not.toBeNull();
      expect(notificationTriggerBox!.width).toBeGreaterThanOrEqual(48);
      expect(notificationTriggerBox!.height).toBeGreaterThanOrEqual(48);
      expect(notificationTriggerBox!.x).toBeGreaterThanOrEqual(0);
      expect(notificationTriggerBox!.x + notificationTriggerBox!.width)
        .toBeLessThanOrEqual(viewport.width + 1);

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
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && [390, 513].includes(viewport.width)) {
        await page.screenshot({ path: testInfo.outputPath(`notifications-${viewport.width}.png`), fullPage: true });
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
      /*
       * A conversation is a leaf, not a destination, so the bottom bar steps
       * aside and back is the way out. Together with the header collapsing from
       * two rows to one, that returns 180px to the message list.
       */
      await expect(primaryNavigation).toBeHidden();
      await expect(page.locator(".conversation-section-nav")).toBeHidden();
      const conversationMore = page.getByRole("button", { name: "More conversation actions" });
      await expectMinimumTarget(conversationMore, "conversation overflow control");
      await conversationMore.click();
      const conversationSheet = page.getByRole("dialog", { name: "Conversation" });
      await expect(conversationSheet).toBeVisible();
      await expect(conversationSheet.getByRole("link", { name: "Canvas" }))
        .toHaveAttribute("href", `/app/whiteboard?conversation=${conversationId}`);
      await expect(conversationSheet.getByRole("button", { name: "Activity" })).toBeVisible();
      await expect(conversationSheet.getByRole("button", { name: "Details" })).toBeVisible();
      await expect(conversationSheet.getByRole("button", { name: "Search messages" })).toBeVisible();
      await expectMinimumTargets(conversationSheet.locator("a, button"), "conversation sheet");
      await expectNoDocumentOverflow(page);
      await conversationSheet.getByRole("button", { name: "Close conversation actions" }).click();
      await expect(conversationSheet).toHaveCount(0);
      await expect(conversationMore).toBeFocused();
      await expect(page.locator(".composer-heading")).toHaveCount(0);
      await expect(page.locator(".composer-toolbar")).toHaveCount(0);
      await expect(page.getByText(/Enter to send/)).toHaveCount(0);
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
      await expectNoHorizontalOverflow(page.locator(".conversation-header"), "conversation header");
      await expectNoDocumentVerticalOverflow(page);

      const back = page.getByRole("button", { name: "Back to conversations" });
      await expect(page.locator(".conversation-header-main")).toHaveCount(1);
      const startAudio = page.getByRole("button", { name: "Start audio call" });
      const startVideo = page.getByRole("button", { name: "Start video call" });
      const attachment = page.locator(".composer .attachment-button");
      const mention = page.locator(".composer .mention-trigger");
      const send = page.locator(".composer .send-button");
      const composerShell = page.locator(".composer .composer-shell");
      const composerField = page.getByRole("textbox", { name: "Message" });

      await expectMinimumTarget(back, "conversation back control");
      await expectMinimumTarget(startAudio, "audio-call control");
      await expectMinimumTarget(startVideo, "video-call control");
      await expectMinimumTarget(attachment, "attachment control");
      await expectMinimumTarget(mention, "mention control");
      await expectMinimumTarget(send, "send control");
      const composerShellBox = await composerShell.boundingBox();
      const composerFieldBox = await composerField.boundingBox();
      const sendBox = await send.boundingBox();
      expect(composerShellBox).not.toBeNull();
      expect(composerFieldBox).not.toBeNull();
      expect(sendBox).not.toBeNull();
      expect(composerShellBox!.width).toBeGreaterThan(viewport.width * .75);
      expect(composerFieldBox!.width).toBeGreaterThan(120);
      expect(sendBox!.x + sendBox!.width)
        .toBeLessThanOrEqual(composerShellBox!.x + composerShellBox!.width + 1);
      await moreMessageActions.click();
      await expectNoDocumentOverflow(page);
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && [390, 513].includes(viewport.width)) {
        await page.screenshot({ path: testInfo.outputPath(`conversation-${viewport.width}.png`), fullPage: true });
      }
      await expect.poll(() => fixture.readCursorRequests).toBeGreaterThan(0);

      await back.click();
      await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
      await expect(conversation).toBeVisible();
      await expect(conversation).toBeFocused();

      await page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "You" }).click();
      await expect(page.getByRole("heading", { name: "You", exact: true })).toBeAttached();
      /*
       * The You screen absorbed the deleted overflow drawer: the workspace
       * destinations that gave up a tab, the instant room, and signing out.
       */
      const workspaceTools = page.getByRole("navigation", { name: "Workspace" });
      await expect(workspaceTools.getByRole("link", { name: "Whiteboard" })).toBeVisible();
      await expect(workspaceTools.getByRole("button", { name: "Start instant room" })).toBeVisible();
      await expect(workspaceTools.getByRole("link", { name: "Workspace administration" })).toBeVisible();
      await expect(workspaceTools.getByRole("link", { name: "Service operations" })).toBeVisible();
      await expectMinimumTargets(workspaceTools.locator("a, button"), "workspace tools");
      const signOut = page.getByRole("button", { name: "Sign out" });
      await expect(signOut).toBeVisible();
      await expectMinimumTarget(signOut, "sign-out control");
      await page.getByRole("tab", { name: "Security" }).click();
      await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
      await expect(page.locator("#device-settings")).not.toHaveAttribute("open", "");
      await expect(page.locator("#session-settings")).not.toHaveAttribute("open", "");
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && [390, 513].includes(viewport.width)) {
        await page.screenshot({ path: testInfo.outputPath(`you-security-${viewport.width}.png`), fullPage: true });
      }
      await page.getByRole("tab", { name: "Notifications" }).click();
      await expect(page.getByRole("heading", { name: "Notification preferences" })).toBeVisible();
      if (process.env.K_COMMS_VISUAL_CAPTURE === "1" && [390, 513].includes(viewport.width)) {
        await page.screenshot({ path: testInfo.outputPath(`you-notifications-${viewport.width}.png`), fullPage: true });
      }
      await page.addStyleTag({ content: "html { overflow-y: scroll; scrollbar-gutter: stable; }" });
      await expectNoDocumentOverflow(page);

      await page.getByRole("tab", { name: "Profile" }).click();
      await page.getByRole("navigation", { name: "Workspace" }).getByRole("link", { name: "Workspace administration" }).click();
      await expect(page.getByRole("heading", { name: "Workspace control center" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Tenant settings" })).toBeVisible();
      await expectNoDocumentOverflow(page);

      await page.getByRole("navigation", { name: "Primary navigation" }).getByRole("link", { name: "You" }).click();
      await page.getByRole("navigation", { name: "Workspace" }).getByRole("link", { name: "Service operations" }).click();
      await expect(page.getByRole("heading", { name: "Service operations" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Operations triage" })).toBeVisible();
      await expectNoDocumentOverflow(page);
      expect(fixture.unexpectedRequests).toEqual([]);
    });
  }

  test("desktop chat keeps the conversation workspace and composer in view", async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installWorkspace(page);
    await page.goto(`/app/?conversation=${conversationId}`);

    const conversationWorkspace = page.getByRole("navigation", {
      name: "Conversation workspace"
    });
    await expect(conversationWorkspace.getByRole("link", { name: "Chat" }))
      .toHaveAttribute("aria-current", "page");
    await expect(conversationWorkspace.getByRole("link", { name: "Canvas" }))
      .toHaveAttribute("href", `/app/whiteboard?conversation=${conversationId}`);
    await expect(conversationWorkspace.getByRole("button", { name: "Activity" }))
      .toBeVisible();
    await expect(conversationWorkspace.getByRole("button", { name: "Details" }))
      .toBeVisible();
    await expect(page.locator(".composer-heading")).toHaveCount(0);
    await expect(page.locator(".composer-toolbar")).toHaveCount(0);
    await expect(page.getByText(/Enter to send/)).toHaveCount(0);
    const conversationPane = page.getByRole("region", { name: "General" });
    await expect(conversationPane.getByRole("button", { name: "Search messages" })).toBeVisible();
    await expect(conversationPane.getByRole("button", { name: "Start audio call" })).toBeVisible();
    await expect(conversationPane.getByRole("button", { name: "Start video call" })).toBeVisible();

    await expectNoHorizontalOverflow(page.locator(".conversation-header"), "desktop conversation header");
    await expectNoHorizontalOverflow(page.locator(".message-scroll"), "desktop message scroller");
    await expectNoHorizontalOverflow(page.locator(".composer"), "desktop composer");
    await expectNoDocumentOverflow(page);

    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: testInfo.outputPath("chat-window-1280.png"),
        fullPage: true
      });
    }
  });

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

  test("the inbox says which rooms have a call running before you open them", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page, { callRunning: true });
    await page.goto("/app/");

    const conversation = page.getByRole("button", { name: /General/ });
    await expect(conversation).toContainText("Active call");
    // The summary stays content-free: conversation kind and call state only.
    await expect(conversation).toContainText("Room conversation");
    await expectNoDocumentOverflow(page);
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("active-call actions preserve the mobile touch-target floor", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installWorkspace(page, { callRunning: true });
    await page.goto("/app/calls");

    const actions = page.locator(".call-session-actions a, .call-session-actions button");
    await expect(actions.first()).toBeVisible();
    await expect(actions).toHaveCount(2);
    await expectMinimumTargets(
      actions,
      "active-call actions"
    );
    await expectNoDocumentOverflow(page);
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: test.info().outputPath("calls-active-targets-390.png"),
        fullPage: true
      });
    }
    expect(fixture.unexpectedRequests).toEqual([]);
  });

  test("the inbox stays quiet when no call is running", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await installWorkspace(page);
    await page.goto("/app/");

    await expect(page.getByRole("button", { name: /General/ })).toBeVisible();
    await expect(page.getByText("Active call")).toHaveCount(0);
  });

  test("desktop rail minimization and conversation width persist across reload", async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await installWorkspace(page);
    await page.goto("/app/");

    const rail = page.getByRole("complementary", { name: "Workspace navigation" });
    const expandedRailBox = await rail.boundingBox();
    expect(expandedRailBox).not.toBeNull();
    expect(expandedRailBox!.width).toBeGreaterThan(200);

    await page.getByRole("button", { name: "Collapse navigation sidebar" }).click();
    const collapsedRailBox = await rail.boundingBox();
    expect(collapsedRailBox).not.toBeNull();
    expect(collapsedRailBox!.width).toBeLessThanOrEqual(82);
    await expect(page.getByRole("button", { name: "Expand navigation sidebar" }))
      .toHaveAttribute("aria-pressed", "true");

    const separator = page.getByRole("separator", { name: "Resize conversation list" });
    await expect(separator).toBeVisible();
    const startingWidth = Number(await separator.getAttribute("aria-valuenow"));
    await separator.focus();
    await page.keyboard.press("ArrowRight");
    await expect(separator).toHaveAttribute("aria-valuenow", String(startingWidth + 16));
    const separatorBox = await separator.boundingBox();
    expect(separatorBox).not.toBeNull();
    await page.mouse.move(
      separatorBox!.x + separatorBox!.width / 2,
      separatorBox!.y + separatorBox!.height / 2
    );
    await page.mouse.down();
    await page.mouse.move(
      separatorBox!.x + separatorBox!.width / 2 + 40,
      separatorBox!.y + separatorBox!.height / 2
    );
    await page.mouse.up();
    await expect(separator).toHaveAttribute("aria-valuenow", String(startingWidth + 56));

    const sidebarHeadingBox = await page.locator(".sidebar-heading").boundingBox();
    const conversationHeaderBox = await page.locator(".conversation-header").boundingBox();
    expect(sidebarHeadingBox).not.toBeNull();
    expect(conversationHeaderBox).not.toBeNull();
    expect(sidebarHeadingBox!.height).toBeLessThanOrEqual(72);
    expect(conversationHeaderBox!.height).toBeLessThanOrEqual(112);

    await page.reload();
    await expect(page.getByRole("button", { name: "Expand navigation sidebar" })).toBeVisible();
    await expect(page.getByRole("separator", { name: "Resize conversation list" }))
      .toHaveAttribute("aria-valuenow", String(startingWidth + 56));
    await expectNoDocumentOverflow(page);

    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: testInfo.outputPath("adjustable-workspace-1440.png"),
        fullPage: true
      });
    }
  });

  test("short landscape phones keep the phone shell and contain long workspace names", async ({ page }) => {
    const longWorkspaceName = "Workspace".repeat(15);
    await page.setViewportSize({ width: 844, height: 390 });
    await installWorkspace(page, { tenantName: longWorkspaceName });
    await page.goto("/app/");

    await expect(page.getByRole("complementary", { name: "Workspace navigation" })).toHaveCount(0);
    await expect(page.locator(".app-shell > .topbar")).toHaveCount(0);
    const primaryNavigation = page.getByRole("navigation", { name: "Primary navigation" });
    await expect(primaryNavigation.locator("a")).toHaveCount(5);
    await expectMinimumTargets(primaryNavigation.locator("a"), "landscape primary navigation");
    await expectNoDocumentOverflow(page);

    /* A short window is a phone; a tall wide one is a desk. */
    await page.setViewportSize({ width: 1280, height: 800 });
    await expect(primaryNavigation).toHaveCount(0);
    await expect(page.getByRole("complementary", { name: "Workspace navigation" })).toBeVisible();
    await page.setViewportSize({ width: 844, height: 390 });
    await expect(primaryNavigation.locator("a")).toHaveCount(5);
    await expectNoDocumentOverflow(page);
  });

  /*
   * The overflow drawer this used to cover is gone, but the contract it
   * protected is not: a back navigation must not strand a modal surface over
   * the route it lands on. The conversation sheet is the surface that inherits
   * that risk.
   */
  test("browser history closes an open conversation sheet", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await installWorkspace(page);
    await page.goto("/app/");
    await page.goto(`/app/?conversation=${conversationId}`);
    await page.getByRole("button", { name: "More conversation actions" }).click();
    await expect(page.getByRole("dialog", { name: "Conversation" })).toBeVisible();

    await page.goBack();

    await expect(page).toHaveURL(/\/app\/$/);
    await expect(page.getByRole("dialog", { name: "Conversation" })).toHaveCount(0);
    await expect(page.locator(".workspace-grid")).toHaveClass(/mobile-list/);
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

});
