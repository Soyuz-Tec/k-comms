import AxeBuilder from "@axe-core/playwright";
import { expect, mockServiceStatus, test } from "./fixtures";
import type { Locator, Page, Route } from "@playwright/test";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const guestId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const roomId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const entryViewports = [
  { width: 320, height: 640 },
  { width: 390, height: 844 }
] as const;

test.describe("instant-room front door", () => {
  for (const viewport of entryViewports) {
    test(`opens a local-first workspace at ${viewport.width}px`, async ({
      page
    }, testInfo) => {
      await page.setViewportSize(viewport);
      const fixture = await installInstantRoomFixture(page);

      await page.goto("/");

      const landingHeading = page.getByRole("heading", {
        name: "Message. Draw. Share."
      });
      const canvas = page.getByLabel("Local drawing canvas");
      const drawingSurface = page.getByTestId("k-comms-drawing-surface");
      const roomTab = page.getByRole("button", {
        name: "Room",
        exact: true
      });
      const displayName = page.getByRole("textbox", {
        name: "Your display name"
      });
      const roomName = page.getByRole("textbox", { name: /Room name/ });
      const start = page.getByRole("button", { name: "Create room" });
      const signIn = page.getByRole("link", {
        name: /Sign in/i
      });

      await expect(landingHeading).toHaveClass(/sr-only/);
      await expect(landingHeading).toBeFocused();
      await expect(canvas).toBeVisible();
      await expect(drawingSurface).not.toContainText(/Excalidraw/i);
      await expect(
        drawingSurface.locator(
          'a[href*="excalidraw"], a[href*="discord.gg/UexuTaE"]'
        )
      ).toHaveCount(0);
      await expect(roomTab).toBeVisible();
      await expect(roomTab).toHaveAttribute("aria-pressed", "false");
      await expectMinimumTarget(roomTab);
      await expectNoDocumentOverflow(page);
      await expectDocumentFitsViewport(page);
      await expectNoWcagFailures(page);

      expect(fixture.createRequests).toHaveLength(0);
      await roomTab.click();
      await expect(roomTab).toHaveAttribute("aria-pressed", "true");
      await expect(displayName).toBeVisible();
      await expect(roomName).toBeVisible();
      await expect(start).toBeVisible();
      await expect(start).toBeEnabled();
      await expect(signIn).toBeVisible();
      await expect(displayName).toHaveValue(/^Guest \d{4}$/);
      await expect(displayName).toHaveCSS("font-size", "16px");
      await expect(roomName).toHaveCSS("font-size", "16px");
      await expectMinimumTarget(displayName);
      await expectMinimumTarget(roomName);
      await expectMinimumTarget(start);
      await expectMinimumTarget(signIn);
      await expectContained(displayName, viewport);
      await expectContained(roomName, viewport);
      await expectContained(start, viewport);
      await expectContained(signIn, viewport);
      await expectNoDocumentOverflow(page);
      await expectDocumentFitsViewport(page);
      await expectOnlyDraftSetupScroller(page);
      await expectNoWcagFailures(page);
      expect(fixture.createRequests).toHaveLength(0);

      if (
        process.env.K_COMMS_VISUAL_CAPTURE === "1" &&
        testInfo.project.name === "chromium" &&
        viewport.width === 390
      ) {
        await page.screenshot({
          path: testInfo.outputPath("instant-room-entry-390.png"),
          fullPage: true
        });
      }

      await displayName.fill("Taylor Host");
      await expect(displayName).toHaveAttribute("aria-invalid", "false");
      await signIn.focus();
      await expect(signIn).toBeFocused();
    });
  }

  test("keeps the complete pre-room workflow inside a 1366 by 768 viewport", async ({
    page
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the desktop layout qualification runs once in Chromium"
    );
    const viewport = { width: 1366, height: 768 };
    await page.setViewportSize(viewport);
    const fixture = await installInstantRoomFixture(page);

    await page.goto("/");

    await expect(page.getByRole("banner")).toHaveCount(0);
    await expect(page.getByLabel("Local drawing canvas")).toBeVisible();
    await expect(page.getByLabel("Room setup")).toBeVisible();
    const createRoom = page.getByRole("button", { name: "Create room" });
    await expect(createRoom).toBeVisible();
    await expectContained(createRoom, viewport);
    await expectDocumentFitsViewport(page);
    await expectNoDocumentOverflow(page);
    expect(fixture.createRequests).toHaveLength(0);
  });

  test("keeps the drawing engine fully white-labeled", async ({
    page
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the deterministic white-label interaction runs once in Chromium"
    );
    await page.setViewportSize({ width: 1024, height: 768 });
    await installInstantRoomFixture(page);

    await page.goto("/");
    const drawingSurface = page.getByTestId("k-comms-drawing-surface");
    await expect(page.getByTestId("toolbar-rectangle")).toBeVisible();
    await expect(drawingSurface).not.toContainText(/Excalidraw/i);
    await expect(
      drawingSurface.locator(
        'a[href*="excalidraw"], a[href*="discord.gg/UexuTaE"]'
      )
    ).toHaveCount(0);
    await expect(
      drawingSurface.getByRole("button", { name: "Help" })
    ).toHaveCount(0);
    await expect(
      drawingSurface.getByRole("checkbox", { name: /Library/i })
    ).toHaveCount(0);

    await expect(
      drawingSurface.getByRole("button", { name: "Canvas settings" })
    ).toBeVisible();
    await expect(
      drawingSurface.getByRole("checkbox", { name: "K-Comms canvas resources" })
    ).toHaveCount(0);

    await drawingSurface.getByRole("button", { name: "Canvas settings" }).click();
    await expect(
      drawingSurface.getByRole("button", { name: /mode$/i })
    ).toBeVisible();
    await expect(drawingSurface.getByText("Excalidraw links")).toHaveCount(0);
    await expect(
      drawingSurface.getByRole("link", { name: /GitHub|Discord|X/i })
    ).toHaveCount(0);

    await page.keyboard.press("Escape");
    await drawingSurface
      .locator("canvas.excalidraw__canvas.interactive")
      .press("?");
    await expect(page.getByRole("dialog", { name: "Help" })).toHaveCount(0);
  });

  test("opens invite details only after room creation", async ({
    page
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the deterministic one-action journey runs once in Chromium"
    );
    await page.setViewportSize({ width: 1024, height: 768 });
    const fixture = await installInstantRoomFixture(page);

    await page.goto("/");
    expect(fixture.createRequests).toHaveLength(0);
    await expect(page.getByRole("button", { name: "Share" })).toHaveCount(0);
    await page.getByRole("button", { name: "Create room" }).click();
    const invite = await ensureRoomMenuOpen(page);
    await expect(
      invite.getByRole("heading", { name: "Scan to join" })
    ).toBeVisible();
    await expect(
      invite.getByRole("img", { name: "Scan to join Instant room" })
    ).toBeVisible();
    await expect(
      invite.getByRole("button", { name: "Copy invite link" })
    ).toBeVisible();
    expect(fixture.createRequests).toHaveLength(1);
    await expectNoDocumentOverflow(page);
  });

  test("opens mobile invite actions from the live room menu", async ({
    page
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the deterministic one-action journey runs once in Chromium"
    );
    await page.setViewportSize({ width: 390, height: 844 });
    const fixture = await installInstantRoomFixture(page);

    await page.goto("/");
    expect(fixture.createRequests).toHaveLength(0);
    await page.getByRole("button", { name: "Room", exact: true }).click();
    await page.getByRole("button", { name: "Create room" }).click();
    const roomMenu = await ensureRoomMenuOpen(page);
    await expect(
      roomMenu.getByRole("heading", { name: "Scan to join" })
    ).toBeVisible();
    await expect(
      roomMenu.getByRole("img", { name: "Scan to join Instant room" })
    ).toBeVisible();
    await expect(
      roomMenu.getByRole("button", { name: "Copy invite link" })
    ).toBeVisible();
    await expect(
      roomMenu.getByRole("button", { name: "Share invite link" })
    ).toBeVisible();
    expect(fixture.createRequests).toHaveLength(1);
    await expectNoDocumentOverflow(page);
  });

  for (const callJourney of [
    {
      kind: "audio",
      action: "Start audio call",
      dialog: "Start an audio call",
      viewport: { width: 1024, height: 768 }
    },
    {
      kind: "video",
      action: "Start video call",
      dialog: "Start a video call",
      viewport: { width: 390, height: 844 }
    }
  ] as const) {
    test(`opens the ${callJourney.kind} prejoin from the live room`, async ({
      page
    }, testInfo) => {
      test.skip(
        testInfo.project.name !== "chromium",
        "the deterministic direct-call journey runs once in Chromium"
      );
      await page.setViewportSize(callJourney.viewport);
      const fixture = await installInstantRoomFixture(page);

      await page.goto("/");
      if (callJourney.viewport.width <= 520) {
        await page.getByRole("button", { name: "Room", exact: true }).click();
      }
      await expect(page.getByRole("button", { name: callJourney.action })).toHaveCount(0);
      await page.getByRole("button", { name: "Create room" }).click();
      const roomMenu = await ensureRoomMenuOpen(page);
      const action = roomMenu.getByRole("button", {
        name: callJourney.action
      });
      await expect(action).toBeEnabled();
      expect(fixture.createRequests).toHaveLength(1);
      await action.click();

      const dialog = page.getByRole("dialog", { name: callJourney.dialog });
      await expect(dialog).toBeVisible();
      await expect(
        dialog.getByRole("heading", { name: "Ready to join?" })
      ).toBeVisible();
      expect(fixture.createRequests).toHaveLength(1);
      await expect(page.getByRole("dialog", { name: "Instant room" }))
        .toHaveCount(0);
      await expectNoDocumentOverflow(page);
    });
  }

  test("creates once and exposes a one-step shareable room at 320px", async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "deterministic create flow runs once in Chromium"
    );
    await page.setViewportSize({ width: 320, height: 700 });
    const fixture = await installInstantRoomFixture(page);

    await page.goto("/");

    await expect(
      page.getByRole("heading", { name: "Message. Draw. Share." })
    ).toHaveClass(/sr-only/);
    await page.getByRole("button", { name: "Room", exact: true }).click();
    expect(fixture.createRequests).toHaveLength(0);
    await page
      .getByRole("textbox", { name: "Your display name" })
      .fill("Taylor Host");
    await page
      .getByRole("textbox", { name: /Room name/ })
      .fill("Instant room");
    await page.getByRole("button", { name: "Create room" }).click();

    await expect(
      page.locator(".canvas-room-layout > h1", { hasText: "Instant room" })
    ).toBeAttached();
    await expect(page.locator(".guest-shell-header")).toHaveCount(0);
    await expect(
      page.getByRole("region", { name: "Invite people" })
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Invite people" })
    ).toHaveCount(0);
    const roomMenu = page.getByRole("button", { name: "Open room controls" });
    await expect(roomMenu).toBeVisible();
    await expectMinimumTarget(roomMenu);
    const roomMenuBox = await roomMenu.boundingBox();
    expect(roomMenuBox).not.toBeNull();
    expect(roomMenuBox!.width).toBeGreaterThanOrEqual(44);
    expect(roomMenuBox!.height).toBeGreaterThanOrEqual(44);
    await expectContained(roomMenu, { width: 320, height: 700 });
    const menuDialog = await ensureRoomMenuOpen(page);
    await expect(menuDialog).toHaveCount(1);
    await expect(menuDialog).toBeVisible();
    const roomMenuDialogBox = await menuDialog.boundingBox();
    expect(roomMenuDialogBox).not.toBeNull();
    await expectContained(menuDialog, { width: 320, height: 700 });
    await expect(menuDialog.getByRole("button", { name: "Close" })).toBeFocused();
    await expect(
      menuDialog.getByRole("button", { name: "Clear canvas" })
    ).toBeVisible();
    await expect(
      menuDialog.getByRole("heading", { name: "Scan to join" })
    ).toBeVisible();
    await expect(
      menuDialog.getByRole("img", { name: "Scan to join Instant room" })
    ).toBeVisible();
    await expect(menuDialog.getByLabel("Room invite link")).toHaveCount(0);
    const inviteIdentifier = menuDialog.locator(
      ".instant-room-menu-invite-id"
    );
    await expect(inviteIdentifier).toBeVisible();
    await expect(inviteIdentifier).not.toContainText(fixture.shareUrl);
    const qr = menuDialog.locator(".instant-room-menu-qr-card .guest-qr");
    const qrBox = await qr.boundingBox();
    expect(qrBox).not.toBeNull();
    expect(qrBox!.width).toBeGreaterThanOrEqual(220);
    const menuCopy = menuDialog.getByRole("button", {
      name: "Copy invite link"
    });
    const menuDownload = menuDialog.getByRole("button", {
      name: "Download QR code"
    });
    const menuShare = menuDialog.getByRole("button", {
      name: "Share invite link"
    });
    await expect(menuCopy).toBeVisible();
    await expect(menuDownload).toBeEnabled();
    await expect(menuShare).toBeVisible();
    await expectMinimumTarget(menuCopy);
    await expectMinimumTarget(menuDownload);
    await expectMinimumTarget(menuShare);
    await expect(menuCopy.locator("svg.lucide-copy")).toHaveCount(1);
    await expect(menuDownload.locator("svg.lucide-download")).toHaveCount(1);
    await expect(menuShare.locator("svg.lucide-share")).toHaveCount(1);
    const downloadPromise = page.waitForEvent("download");
    await menuDownload.click();
    const qrDownload = await downloadPromise;
    expect(qrDownload.suggestedFilename()).toBe(
      "k-comms-room-invite-qr.png"
    );
    await page.evaluate(() => {
      document.documentElement.style.fontSize = "200%";
    });
    const scaledActions = [menuCopy, menuDownload, menuShare];
    for (const action of scaledActions) {
      await action.scrollIntoViewIfNeeded();
      await expect(action).toBeVisible();
      await expectContained(action, { width: 320, height: 700 });
    }
    const actionColumns = await menuDialog
      .locator(".instant-room-menu-invite-actions")
      .evaluate((element) =>
        getComputedStyle(element).gridTemplateColumns
          .split(" ")
          .filter(Boolean).length
      );
    expect(actionColumns).toBe(1);
    await qr.scrollIntoViewIfNeeded();
    const scaledQrBox = await qr.boundingBox();
    expect(scaledQrBox).not.toBeNull();
    expect(scaledQrBox!.width).toBeGreaterThanOrEqual(220);
    await expectNoDocumentOverflow(page);
    await page.evaluate(() => {
      document.documentElement.style.fontSize = "";
    });
    await expect(
      page.getByRole("dialog", { name: "Invite someone" })
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Show QR code" })
    ).toHaveCount(0);
    await expect(page.getByRole("dialog")).toHaveCount(1);
    await expect(
      menuDialog.getByRole("button", { name: /Leave room/ })
    ).toBeVisible();
    await expectContained(menuDialog, { width: 320, height: 700 });
    await expectNoDocumentOverflow(page);
    await expectNoWcagFailures(page);
    const closeMenu = menuDialog.getByRole("button", { name: "Close" });
    await closeMenu.scrollIntoViewIfNeeded();
    await closeMenu.click();
    await expect(menuDialog).toHaveCount(0);
    await expect(roomMenu).toHaveAttribute("aria-expanded", "false");
    await expect(roomMenu).toBeFocused();

    const reopenedMenu = await ensureRoomMenuOpen(page);
    const participants = reopenedMenu.getByRole("button", {
      name: "Participants",
      exact: true
    });
    await expect(participants).toHaveAttribute("aria-expanded", "false");
    await expect(
      reopenedMenu.getByText(
        /(?:1 person online|presence unknown)\s*·\s*(?:connecting|live|offline|reconnecting)/
      )
    ).toBeVisible();
    await expect(
      page.getByText("1 online · 1 total", { exact: true })
    ).toHaveCount(0);
    await expectMinimumTarget(participants);
    await participants.click();
    await expect(
      reopenedMenu
        .getByRole("list", { name: "Room participants" })
        .getByText("Taylor Host", { exact: false })
    ).toContainText("Taylor Host (you)");
    await participants.click();
    await expect(
      reopenedMenu.getByRole("list", { name: "Room participants" })
    ).toHaveCount(0);

    await expectCompactCallActions(reopenedMenu, { width: 320, height: 700 });
    await reopenedMenu.getByRole("button", { name: "Close" }).click();
    const floatingChat = page.locator(".guest-floating-chat");
    const messageMenuTrigger = floatingChat.getByRole("button", {
      name: "Open message menu"
    });
    await expect(messageMenuTrigger).toBeVisible();
    await expect(messageMenuTrigger.locator("svg.lucide-menu")).toHaveCount(1);
    await messageMenuTrigger.click();
    const messageMenu = floatingChat.getByRole("menu", {
      name: "Message controls"
    });
    await expect(messageMenu).toBeVisible();
    await expect(
      messageMenu.getByRole("menuitem", { name: "Write a message" })
    ).toBeVisible();
    await expect(
      messageMenu.getByRole("menuitem", { name: "Jump to latest" })
    ).toBeVisible();
    await expect(
      messageMenu.getByRole("menuitem", { name: "Collapse messages" })
    ).toBeVisible();
    for (const roomAction of [
      "Participants",
      "Start audio call",
      "Start video call",
      "Copy invite link",
      "Clear canvas"
    ]) {
      await expect(
        messageMenu.getByRole("menuitem", { name: roomAction })
      ).toHaveCount(0);
    }
    await messageMenu
      .getByRole("menuitem", { name: "Collapse messages" })
      .click();
    await expect(floatingChat).toHaveClass(/is-collapsed/);
    await expect(
      floatingChat.getByRole("region", { name: "Room messages" })
    ).toHaveCount(0);
    await expect(messageMenuTrigger).toBeVisible();
    await messageMenuTrigger.click();
    await expect(floatingChat).not.toHaveClass(/is-collapsed/);
    await expect(messageMenu).toBeVisible();
    await messageMenu.press("Escape");
    await expect(messageMenu).toHaveCount(0);
    await expect(messageMenuTrigger).toBeFocused();

    const composer = page.getByRole("textbox", { name: "Message" });
    const send = page.getByRole("button", { name: "Send" });
    await expect(composer).toBeVisible();
    await expect(composer).toHaveAttribute("placeholder", "Write a message");
    await expect(composer).toHaveCSS("font-size", "16px");
    const composerTextMetrics = await composer.evaluate((element) => ({
      clientHeight: element.clientHeight,
      scrollHeight: element.scrollHeight
    }));
    expect(composerTextMetrics.scrollHeight).toBeLessThanOrEqual(
      composerTextMetrics.clientHeight
    );
    await expect(send).toBeVisible();
    await expectMinimumTarget(send);
    await expectContained(composer, { width: 320, height: 700 });
    await expectContained(send, { width: 320, height: 700 });
    await expectOnlyMessageScroller(page);
    await expectNoDocumentOverflow(page);
    await expectNoWcagFailures(page);

    const chatBeforeMove = await floatingChat.boundingBox();
    expect(chatBeforeMove).not.toBeNull();
    const chatMoveHandle = page.getByRole("button", {
      name: "Move messages"
    });
    await chatMoveHandle.focus();
    await chatMoveHandle.press("ArrowUp");
    const chatAfterMove = await floatingChat.boundingBox();
    expect(chatAfterMove).not.toBeNull();
    expect(chatAfterMove!.y).toBeLessThan(chatBeforeMove!.y);

    await expectContained(composer, { width: 320, height: 700 });
    await expectContained(send, { width: 320, height: 700 });
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: testInfo.outputPath("instant-room-320.png"),
        fullPage: false
      });
    }

    expect(fixture.createRequests).toHaveLength(1);
    expect(fixture.createRequests[0]).toMatchObject({
      display_name: "Taylor Host",
      title: "Instant room"
    });
    expect(fixture.idempotencyKeys).toHaveLength(1);
    expect(fixture.idempotencyKeys[0]).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const storage = await page.evaluate(() => ({
      session: sessionStorage.getItem("k-comms.guest-session.v1"),
      persistent: localStorage.getItem("k-comms.guest-session.v1")
    }));
    expect(storage.session).toContain("guest-access");
    expect(storage.persistent).toBeNull();
  });

  for (const viewport of [
    { width: 390, height: 844 },
    { width: 430, height: 860 },
    { width: 600, height: 900 },
    { width: 760, height: 900 },
    { width: 844, height: 390 }
  ]) {
    test(`keeps the compact live-room workspace contained at ${viewport.width}px`, async ({
      page
    }, testInfo) => {
      test.skip(
        testInfo.project.name !== "chromium",
        "deterministic create flow runs once in Chromium"
      );
      await page.setViewportSize(viewport);
      const fixture = await installInstantRoomFixture(page);
      await page.goto("/");
      const draftRoomTab = page.getByRole("button", {
        name: "Room",
        exact: true
      });
      if (await draftRoomTab.isVisible()) {
        await draftRoomTab.click();
      }
      await page
        .getByRole("textbox", { name: "Your display name" })
        .fill("Taylor Host");
      await page.getByRole("button", { name: "Create room" }).click();

      const menuTrigger = page.getByRole("button", {
        name: "Open room controls"
      });
      const initiallyOpenMenu = page.getByRole("dialog", {
        name: "Instant room"
      });
      if (await initiallyOpenMenu.isVisible()) {
        await initiallyOpenMenu.getByRole("button", { name: "Close" }).click();
      }
      const floatingChat = page.locator(".guest-floating-chat");
      const messageMenuTrigger = floatingChat.getByRole("button", {
        name: "Open message menu"
      });
      const controls = [
        menuTrigger,
        messageMenuTrigger,
        page.getByRole("button", { name: "Send" })
      ];
      for (const control of controls) {
        await expect(control).toBeVisible();
        await expectMinimumTarget(control);
        await expectContained(control, viewport);
      }
      await expect(
        page.getByLabel("Whiteboard for Instant room")
      ).toBeVisible();
      for (const layerHandle of [
        page.getByRole("button", { name: "Move room controls button" }),
        page.getByRole("button", { name: "Move canvas status" }),
        page.getByRole("button", { name: "Move messages" })
      ]) {
        await expect(layerHandle).toBeVisible();
        await expectContained(layerHandle, viewport);
      }
      await expect(
        page.getByRole("region", { name: "Invite people" })
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: "Invite people" })
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: "Copy invite link" })
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: /Clear (?:board|canvas)/ })
      ).toHaveCount(0);
      await expect(
        page.getByRole("img", { name: "Scan to join Instant room" })
      ).toHaveCount(0);
      await expect(page.locator(".guest-shell-header")).toHaveCount(0);
      await expect(
        page.getByText("1 online · 1 total", { exact: true })
      ).toHaveCount(0);
      await expectFillsViewport(
        page.locator(".guest-collaboration-workspace.canvas-workspace"),
        viewport
      );
      await expectFillsViewport(page.locator(".guest-whiteboard-panel"), viewport);
      await expectContained(
        page.getByRole("textbox", { name: "Message" }),
        viewport
      );
      await expectOnlyMessageScroller(page);
      await expectNoDocumentOverflow(page);
      expect(fixture.createRequests).toHaveLength(1);

      await messageMenuTrigger.click();
      const messageMenu = floatingChat.getByRole("menu", {
        name: "Message controls"
      });
      await expect(messageMenu).toBeVisible();
      await expect(
        messageMenu.getByRole("menuitem", { name: "Write a message" })
      ).toBeVisible();
      await expect(
        messageMenu.getByRole("menuitem", { name: "Jump to latest" })
      ).toBeVisible();
      await expect(
        messageMenu.getByRole("menuitem", { name: "Collapse messages" })
      ).toBeVisible();
      await expect(messageMenu.getByText("Participants")).toHaveCount(0);
      await expect(messageMenu.getByText("Calls")).toHaveCount(0);
      await expect(messageMenu.getByText("Invite and share")).toHaveCount(0);
      await messageMenu.press("Escape");
      await expect(messageMenu).toHaveCount(0);
      await expect(messageMenuTrigger).toBeFocused();

      const menuDialog = await ensureRoomMenuOpen(page);
      await expect(menuDialog).toHaveCount(1);
      await expect(menuDialog).toBeVisible();
      await expectContained(menuDialog, viewport);
      await expect(menuDialog.getByRole("button", { name: "Close" })).toBeFocused();
      await expect(
        menuDialog.getByRole("button", { name: "Clear canvas" })
      ).toBeVisible();
      const participantToggle = menuDialog.getByRole("button", {
        name: "Participants",
        exact: true
      });
      await expect(participantToggle).toBeVisible();
      await expectMinimumTarget(participantToggle);
      await expectCompactCallActions(menuDialog, viewport);
      await expect(
        menuDialog.getByRole("heading", { name: "Scan to join" })
      ).toBeVisible();
      await expect(
        menuDialog.getByRole("img", { name: "Scan to join Instant room" })
      ).toBeVisible();
      await expect(
        menuDialog.getByRole("button", { name: "Copy invite link" })
      ).toBeVisible();
      const downloadQr = menuDialog.getByRole("button", {
        name: "Download QR code"
      });
      await expect(downloadQr).toBeEnabled();
      await expectMinimumTarget(downloadQr);
      await downloadQr.scrollIntoViewIfNeeded();
      await expectContained(downloadQr, viewport);
      await expect(
        menuDialog.getByRole("button", { name: "Share invite link" })
      ).toBeVisible();
      const qrCard = menuDialog.locator(".instant-room-menu-qr-card");
      await expect(qrCard).toBeVisible();
      await qrCard.scrollIntoViewIfNeeded();
      await expectContained(qrCard, viewport);
      await expect(
        page.getByRole("dialog", { name: "Invite someone" })
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: "Show QR code" })
      ).toHaveCount(0);
      await expect(page.getByRole("dialog")).toHaveCount(1);
      await expectContained(menuDialog, viewport);
      await expectNoDocumentOverflow(page);
      if (viewport.width === 390) {
        const menuBeforeMove = await menuDialog.boundingBox();
        expect(menuBeforeMove).not.toBeNull();
        const menuMoveHandle = menuDialog.getByRole("button", {
          name: "Move room controls"
        });
        await menuMoveHandle.focus();
        await menuMoveHandle.press("ArrowUp");
        const menuAfterMove = await menuDialog.boundingBox();
        expect(menuAfterMove).not.toBeNull();
        expect(menuAfterMove!.y).toBeLessThan(menuBeforeMove!.y);
      }
      await menuDialog.getByRole("button", { name: "Close" }).click();
      await expect(menuDialog).toHaveCount(0);
      await expect(menuTrigger).toHaveAttribute("aria-expanded", "false");
      await expect(menuTrigger).toBeFocused();

      if (
        process.env.K_COMMS_VISUAL_CAPTURE === "1" &&
        viewport.width === 390
      ) {
        await page.screenshot({
          path: testInfo.outputPath("instant-room-workspace-390.png"),
          fullPage: false
        });
      }

      if (viewport.width === 390) {
        await page.addStyleTag({ content: "html { font-size: 200%; }" });
        await expectNoDocumentOverflow(page);
        const scaledMenu = await ensureRoomMenuOpen(page);
        await participantToggle.scrollIntoViewIfNeeded();
        await expectContained(participantToggle, viewport);
        await expectCompactCallActions(scaledMenu, viewport);
        await expectContained(scaledMenu, viewport);
        await scaledMenu.getByRole("button", { name: "Close" }).click();
        await page
          .getByRole("textbox", { name: "Message" })
          .scrollIntoViewIfNeeded();
        await expectContained(
          page.getByRole("textbox", { name: "Message" }),
          viewport
        );
        await expectContained(
          page.getByRole("button", { name: "Send" }),
          viewport
        );
      }

      if (viewport.width === 760) {
        const responsiveMenu = await ensureRoomMenuOpen(page);
        await page.setViewportSize({ width: 761, height: viewport.height });
        await expect(responsiveMenu).toBeVisible();
        await expectContained(responsiveMenu, {
          width: 761,
          height: viewport.height
        });
      }
    });
  }
});

async function installInstantRoomFixture(page: Page) {
  const shareUrl =
    "http://127.0.0.1:4178/join#guest=server-returned-instant-secret";
  const tenant = {
    id: tenantId,
    name: "Public rooms",
    slug: "public-rooms",
    status: "active"
  };
  const guest = {
    id: guestId,
    tenant_id: tenantId,
    display_name: "Taylor Host",
    account_type: "guest",
    role: "member",
    status: "active"
  };
  const device = {
    id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    user_id: guestId,
    name: "Browser",
    platform: "web"
  };
  const conversation = {
    id: conversationId,
    tenant_id: tenantId,
    kind: "group",
    title: "Instant room",
    counterpart_display_name: null,
    visibility: "private",
    latest_sequence: 0,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z"
  };
  const room = {
    id: roomId,
    conversation_id: conversationId,
    owner_user_id: guestId,
    owner_kind: "guest",
    status: "active",
    participant_limit: 25,
    idle_since: null,
    expires_at: null,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z"
  };
  const createRequests: unknown[] = [];
  const idempotencyKeys: string[] = [];

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (method === "GET" && path === "/api/v1/status") {
      return json(route, mockServiceStatus());
    }
    if (method === "POST" && path === "/api/v1/instant-rooms") {
      createRequests.push(request.postDataJSON());
      idempotencyKeys.push(request.headers()["idempotency-key"] || "");
      return json(route, {
        access_token: "guest-access",
        refresh_token: "guest-refresh",
        token_type: "Bearer",
        expires_in: 900,
        tenant,
        user: guest,
        device,
        room,
        conversation,
        share_url: shareUrl,
        capabilities: {
          allow_audio_calls: true,
          allow_video_calls: true,
          conversion_enabled: true,
          self_service_conversion: true
        }
      }, 201);
    }
    if (method === "GET" && path === "/api/v1/guest/conversation") {
      return json(route, { data: conversation });
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/members") {
      return json(route, {
        data: [{
          id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
          role: "owner",
          joined_at: "2026-07-24T12:00:00Z",
          last_read_sequence: 0,
          user: guest
        }]
      });
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/messages") {
      return json(route, {
        data: [],
        page: {
          has_more: false,
          next_after_sequence: null,
          reset_required: false
        }
      });
    }
    if (
      method === "GET" &&
      path === "/api/v1/guest/conversation/whiteboard/operations"
    ) {
      return json(route, {
        data: [],
        page: {
          has_more: false,
          next_after_sequence: null
        }
      });
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/call") {
      return json(route, { data: null });
    }

    return json(route, {
      error: {
        code: "unexpected_request",
        detail: `${method} ${path}`
      }
    }, 501);
  });

  return { createRequests, idempotencyKeys, shareUrl };
}

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(
    () => Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    ) - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(1);
}

async function expectDocumentFitsViewport(page: Page) {
  const overflow = await page.evaluate(() => Math.max(
    document.documentElement.scrollHeight,
    document.body.scrollHeight
  ) - document.documentElement.clientHeight);
  expect(overflow).toBeLessThanOrEqual(1);
}

async function expectOnlyDraftSetupScroller(page: Page) {
  const activeScrollers = await page.locator("body *").evaluateAll((elements) =>
    elements
      .filter((element) => {
        const style = window.getComputedStyle(element);
        return ["auto", "scroll"].includes(style.overflowY)
          && element.scrollHeight > element.clientHeight + 1;
      })
      .map((element) => ({
        tagName: element.tagName,
        className: typeof element.className === "string" ? element.className : "",
        id: element.id,
        clientHeight: element.clientHeight,
        scrollHeight: element.scrollHeight
      }))
  );
  expect(
    activeScrollers.filter(
      ({ className }) => !className.includes("instant-draft-setup-scroll")
    )
  ).toEqual([]);
}

async function expectOnlyMessageScroller(page: Page) {
  const activeScrollers = await page.locator("body *").evaluateAll((elements) =>
    elements
      .filter((element) => {
        const style = window.getComputedStyle(element);
        return ["auto", "scroll"].includes(style.overflowY)
          && element.scrollHeight > element.clientHeight + 1;
      })
      .map((element) => element.className)
  );
  expect(
    activeScrollers.every((className) =>
      typeof className === "string" && className.includes("guest-message-scroll")
    )
  ).toBe(true);
}

async function expectNoWcagFailures(page: Page) {
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(
    results.violations.map(({ id, impact, tags, nodes }) => ({
      id,
      impact,
      tags,
      targets: nodes.map((node) => node.target)
    }))
  ).toEqual([]);
}

async function expectMinimumTarget(locator: Locator) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  expect(box!.height).toBeGreaterThanOrEqual(44);
}

async function expectCompactCallActions(
  root: Locator,
  viewport: { width: number; height: number }
) {
  const audio = root.getByRole("button", { name: "Start audio call" });
  const video = root.getByRole("button", { name: "Start video call" });
  const controls = [
    { button: audio, icon: audio.locator("svg.lucide-phone") },
    { button: video, icon: video.locator("svg.lucide-video") }
  ];

  for (const { button, icon } of controls) {
    await button.scrollIntoViewIfNeeded();
    await expect(button).toBeVisible();
    await expectMinimumTarget(button);
    await expectContained(button, viewport);
    const buttonBox = await button.boundingBox();
    expect(buttonBox).not.toBeNull();
    expect(buttonBox!.height).toBeGreaterThanOrEqual(44);

    await expect(icon).toHaveCount(1);
    await expect(icon).toBeVisible();
    const iconBox = await icon.boundingBox();
    expect(iconBox).not.toBeNull();
    expect(iconBox!.width).toBeGreaterThanOrEqual(12);
    expect(iconBox!.height).toBeGreaterThanOrEqual(12);
  }
}

async function ensureRoomMenuOpen(page: Page): Promise<Locator> {
  const menu = page.getByRole("dialog", { name: "Instant room" });
  if (!(await menu.isVisible())) {
    await page.getByRole("button", { name: "Open room controls" }).click();
  }
  await expect(menu).toBeVisible();
  return menu;
}

async function expectFillsViewport(
  locator: Locator,
  viewport: { width: number; height: number }
) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  expect(box!.x).toBeCloseTo(0, 0);
  expect(box!.y).toBeCloseTo(0, 0);
  expect(box!.width).toBeCloseTo(viewport.width, 0);
  expect(box!.height).toBeCloseTo(viewport.height, 0);
}

async function expectContained(
  locator: Locator,
  viewport: { width: number; height: number }
) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  expect(box!.x).toBeGreaterThanOrEqual(0);
  expect(box!.x + box!.width).toBeLessThanOrEqual(viewport.width + 1);
  expect(box!.y).toBeGreaterThanOrEqual(0);
  expect(box!.y + box!.height).toBeLessThanOrEqual(viewport.height + 1);
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body)
  });
}
