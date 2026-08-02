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
    test(`keeps the empty entry form usable at ${viewport.width}px`, async ({
      page
    }, testInfo) => {
      await page.setViewportSize(viewport);
      const fixture = await installInstantRoomFixture(page);

      await page.goto("/");

      const landingHeading = page.getByRole("heading", {
        name: "Message. Draw. Share."
      });
      const roomHeading = page.getByRole("heading", {
        name: "Start an instant room"
      });
      const displayName = page.getByRole("textbox", {
        name: "Your display name"
      });
      const roomName = page.getByRole("textbox", { name: /Room name/ });
      const start = page.getByRole("button", { name: "Start instant room" });
      const signIn = page.getByRole("link", {
        name: "Have a workspace? Sign in"
      });

      await expect(landingHeading).toBeVisible();
      await expect(landingHeading).toBeFocused();
      await expectContained(landingHeading, viewport);
      await expectNoDocumentOverflow(page);

      await expect(displayName).toBeVisible();
      await expect(roomName).toBeVisible();
      await expect(start).toBeVisible();
      await expect(start).toBeEnabled();
      await expect(signIn).toBeVisible();
      const headingMetrics = await roomHeading.evaluate((element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return {
          height: rect.height,
          lineHeight: Number.parseFloat(style.lineHeight),
          scrollWidth: element.scrollWidth,
          clientWidth: element.clientWidth
        };
      });
      expect(headingMetrics.height).toBeLessThanOrEqual(
        headingMetrics.lineHeight * 1.1
      );
      expect(headingMetrics.scrollWidth).toBeLessThanOrEqual(
        headingMetrics.clientWidth + 1
      );
      await expect(displayName).toHaveCSS("font-size", "16px");
      await expect(roomName).toHaveCSS("font-size", "16px");
      await expectMinimumTarget(displayName);
      await expectMinimumTarget(roomName);
      await expectMinimumTarget(start);
      await expectMinimumTarget(signIn);
      await expectContained(roomHeading, viewport);
      await expectContained(displayName, viewport);
      await expectContained(roomName, viewport);
      await start.scrollIntoViewIfNeeded();
      await expectContained(start, viewport);
      await signIn.scrollIntoViewIfNeeded();
      await expectContained(signIn, viewport);
      await expectNoDocumentOverflow(page);
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

      await page.keyboard.press("Tab");
      await expect(displayName).toBeFocused();
      await page.keyboard.press("Tab");
      await expect(roomName).toBeFocused();
      await page.keyboard.press("Tab");
      await expect(start).toBeFocused();
      await page.keyboard.press("Enter");

      await expect(
        page.getByText("Enter your display name to continue.")
      ).toBeVisible();
      await expect(displayName).toBeFocused();
      await expect(displayName).toHaveAttribute("aria-invalid", "true");
      expect(fixture.createRequests).toHaveLength(0);

      await displayName.fill("Taylor Host");
      await expect(displayName).toHaveAttribute("aria-invalid", "false");
      await page.keyboard.press("Tab");
      await expect(roomName).toBeFocused();
      await page.keyboard.press("Tab");
      await expect(start).toBeFocused();
      if (testInfo.project.name === "webkit") {
        expect(await signIn.evaluate((element) => element.tabIndex))
          .toBeGreaterThanOrEqual(0);
        await signIn.focus();
      } else {
        await page.keyboard.press("Tab");
      }
      await expect(signIn).toBeFocused();
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
      page.getByRole("heading", { name: "Start an instant room" })
    ).toBeVisible();
    expect(fixture.createRequests).toHaveLength(0);
    await page
      .getByRole("textbox", { name: "Your display name" })
      .fill("Taylor Host");
    await page
      .getByRole("textbox", { name: /Room name/ })
      .fill("Instant room");
    await page.getByRole("button", { name: "Start instant room" }).click();

    await expect(page.getByRole("heading", { name: "Instant room" })).toBeVisible();
    await expect(
      page.getByRole("region", { name: "Invite people" })
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Invite people" })
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Copy invite link" })
    ).toHaveCount(0);
    await expect(page.getByLabel("Room invite link")).toHaveCount(0);
    await expect(
      page.getByRole("img", { name: "Scan to join Instant room" })
    ).toHaveCount(0);
    await expect(
      page.getByRole("dialog", { name: "Room menu" })
    ).toHaveCount(0);

    const roomMenu = page.getByRole("button", { name: "Open room menu" });
    await expect(roomMenu).toBeVisible();
    await expect(roomMenu).toHaveAttribute("aria-expanded", "false");
    await expectMinimumTarget(roomMenu);
    const roomMenuBox = await roomMenu.boundingBox();
    expect(roomMenuBox).not.toBeNull();
    expect(roomMenuBox!.width).toBeGreaterThanOrEqual(52);
    expect(roomMenuBox!.height).toBeGreaterThanOrEqual(52);
    expect(roomMenuBox!.x).toBeGreaterThan(160);
    await roomMenu.click();
    const menuDialog = page.getByRole("dialog", { name: "Room menu" });
    await expect(menuDialog).toHaveCount(1);
    await expect(menuDialog).toBeVisible();
    const roomMenuDialogBox = await menuDialog.boundingBox();
    expect(roomMenuDialogBox).not.toBeNull();
    expect(Math.abs(
      roomMenuDialogBox!.x + roomMenuDialogBox!.width - 320
    )).toBeLessThanOrEqual(1);
    await expect(menuDialog.getByRole("button", { name: "Close" })).toBeFocused();
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

    const participants = page.getByRole("button", {
      name: "Participants",
      exact: true
    });
    await expect(participants).toHaveAttribute("aria-expanded", "false");
    await expect(
      page.locator(".guest-shell-header .guest-room-heading p")
    ).toContainText(
      /(?:1 person online|presence unknown)\s*·\s*(?:connecting|live|offline|reconnecting)/
    );
    await expect(
      page.getByText("1 online · 1 total", { exact: true })
    ).toHaveCount(0);
    await expectMinimumTarget(participants);
    await participants.click();
    await expect(
      page
        .getByRole("list", { name: "Room participants" })
        .getByText("Taylor Host", { exact: false })
    ).toContainText("Taylor Host (you)");
    await participants.click();
    await expect(page.getByRole("list", { name: "Room participants" })).toHaveCount(0);

    await expectLargeCenteredCallLaunchers(page, { width: 320, height: 700 });
    await page.getByRole("button", { name: "Messages" }).click();
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
      await page
        .getByRole("textbox", { name: "Your display name" })
        .fill("Taylor Host");
      await page.getByRole("button", { name: "Start instant room" }).click();

      const menuTrigger = page.getByRole("button", {
        name: "Open room menu"
      });
      const participantToggle = page.getByRole("button", {
        name: "Participants",
        exact: true
      });
      if (viewport.width <= 520) {
        await page.getByRole("button", { name: "Messages" }).click();
      }
      const controls = [
        menuTrigger,
        participantToggle,
        page.getByRole("button", { name: "Start audio call" }),
        page.getByRole("button", { name: "Start video call" }),
        page.getByRole("button", { name: "Send" })
      ];
      for (const control of controls) {
        await expect(control).toBeVisible();
        await expectMinimumTarget(control);
        await expectContained(control, viewport);
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
        page.getByRole("img", { name: "Scan to join Instant room" })
      ).toHaveCount(0);
      await expect(
        page.locator(".guest-shell-header .guest-room-heading p")
      ).toContainText(
        /(?:1 person online|presence unknown)\s*·\s*(?:connecting|live|offline|reconnecting)/
      );
      await expect(
        page.getByText("1 online · 1 total", { exact: true })
      ).toHaveCount(0);
      await expectLargeCenteredCallLaunchers(page, viewport);
      await expectContained(
        page.getByRole("textbox", { name: "Message" }),
        viewport
      );
      await expectOnlyMessageScroller(page);
      await expectNoDocumentOverflow(page);
      expect(fixture.createRequests).toHaveLength(1);

      await menuTrigger.click();
      const menuDialog = page.getByRole("dialog", { name: "Room menu" });
      await expect(menuDialog).toHaveCount(1);
      await expect(menuDialog).toBeVisible();
      const menuDialogBox = await menuDialog.boundingBox();
      expect(menuDialogBox).not.toBeNull();
      expect(Math.abs(
        menuDialogBox!.x + menuDialogBox!.width - viewport.width
      )).toBeLessThanOrEqual(1);
      await expect(menuDialog.getByRole("button", { name: "Close" })).toBeFocused();
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
        await participantToggle.scrollIntoViewIfNeeded();
        await expectContained(participantToggle, viewport);
        await expectLargeCenteredCallLaunchers(page, viewport);
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
        await menuTrigger.click();
        await expect(
          page.getByRole("dialog", { name: "Room menu" })
        ).toBeVisible();
        await page.setViewportSize({ width: 761, height: viewport.height });
        await expect(
          page.getByRole("dialog", { name: "Room menu" })
        ).toHaveCount(0);
        await expect(
          page.getByRole("heading", { name: "Instant room" })
        ).toBeFocused();

        await page.setViewportSize(viewport);
        await participantToggle.focus();
        await page.setViewportSize({ width: 761, height: viewport.height });
        await expect(
          page.getByRole("heading", { name: "Participants" })
        ).toBeFocused();
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

async function expectLargeCenteredCallLaunchers(
  page: Page,
  viewport: { width: number; height: number }
) {
  const audio = page.getByRole("button", { name: "Start audio call" });
  const video = page.getByRole("button", { name: "Start video call" });
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
    expect(buttonBox!.height).toBeGreaterThanOrEqual(80);

    await expect(icon).toHaveCount(1);
    await expect(icon).toBeVisible();
    const iconBox = await icon.boundingBox();
    expect(iconBox).not.toBeNull();
    expect(iconBox!.width).toBeGreaterThanOrEqual(26);
    expect(iconBox!.height).toBeGreaterThanOrEqual(26);
  }

  const [audioBox, videoBox] = await Promise.all([
    audio.boundingBox(),
    video.boundingBox()
  ]);
  expect(audioBox).not.toBeNull();
  expect(videoBox).not.toBeNull();
  const groupLeft = Math.min(audioBox!.x, videoBox!.x);
  const groupRight = Math.max(
    audioBox!.x + audioBox!.width,
    videoBox!.x + videoBox!.width
  );
  expect(Math.abs((groupLeft + groupRight) / 2 - viewport.width / 2))
    .toBeLessThanOrEqual(2);
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
