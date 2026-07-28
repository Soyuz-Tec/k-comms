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

      const heading = page.getByRole("heading", {
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

      await expect(heading).toBeVisible();
      await expect(displayName).toBeVisible();
      await expect(roomName).toBeVisible();
      await expect(start).toBeVisible();
      await expect(start).toBeEnabled();
      await expect(signIn).toBeVisible();
      await expect(heading).toBeFocused();
      const headingMetrics = await heading.evaluate((element) => {
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
      await expectContained(heading, viewport);
      await expectContained(displayName, viewport);
      await expectContained(roomName, viewport);
      await expectContained(start, viewport);
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
    const invite = page.getByRole("button", { name: "Invite people" });
    await expect(invite).toBeVisible();
    await expect(invite).toHaveAttribute("aria-expanded", "false");
    await expect(page.getByLabel("Room invite link")).toHaveCount(0);
    await expect(
      page.getByRole("img", { name: "Scan to join Instant room" })
    ).toHaveCount(0);
    await expectMinimumTarget(invite);
    await expectMinimumTarget(page.getByRole("button", { name: "Copy invite link" }));

    const roomMenu = page.getByRole("button", { name: "Open room menu" });
    await expect(roomMenu).toBeVisible();
    await expectMinimumTarget(roomMenu);
    await roomMenu.click();
    const menuDialog = page.getByRole("dialog", { name: "Room menu" });
    await expect(menuDialog).toBeVisible();
    await expect(menuDialog.getByRole("button", { name: "Close" })).toBeFocused();
    await expect(menuDialog.getByRole("button", { name: /Leave room/ })).toBeVisible();
    await menuDialog.getByRole("button", { name: "Close" }).click();
    await expect(roomMenu).toBeFocused();

    const participants = page.getByRole("button", { name: /Participants/ });
    await expect(participants).toHaveAttribute("aria-expanded", "false");
    await expectMinimumTarget(participants);
    await participants.click();
    await expect(
      page
        .getByRole("list", { name: "Room participants" })
        .getByText("Taylor Host", { exact: false })
    ).toContainText("Taylor Host (you)");
    await participants.click();
    await expect(page.getByRole("list", { name: "Room participants" })).toHaveCount(0);

    const audio = page.getByRole("button", { name: "Start audio call" });
    const video = page.getByRole("button", { name: "Start video call" });
    await expect(audio).toBeVisible();
    await expect(video).toBeVisible();
    await expectMinimumTarget(audio);
    await expectMinimumTarget(video);
    const composer = page.getByRole("textbox", { name: "Message" });
    const send = page.getByRole("button", { name: "Send" });
    await expect(composer).toBeVisible();
    await expect(composer).toHaveCSS("font-size", "16px");
    await expect(send).toBeVisible();
    await expectMinimumTarget(send);
    await expectContained(composer, { width: 320, height: 700 });
    await expectContained(send, { width: 320, height: 700 });
    await expectOnlyMessageScroller(page);
    await expectNoDocumentOverflow(page);
    await expectNoWcagFailures(page);

    await invite.click();
    const inviteDialog = page.getByRole("dialog", { name: "Invite someone" });
    await expect(inviteDialog).toBeVisible();
    await expect(
      inviteDialog.getByRole("heading", { name: "Invite someone" })
    ).toBeFocused();
    const inviteLink = page.getByLabel("Room invite link");
    await expect(inviteLink).not.toHaveValue(fixture.shareUrl);
    await expect(inviteLink).toHaveValue(/#guest=••••••••••••$/);
    await expect(
      page.getByRole("img", { name: "Scan to join Instant room" })
    ).toHaveCount(0);
    await inviteDialog.getByRole("button", { name: "Show QR code" }).click();
    await expect(
      page.getByRole("img", { name: "Scan to join Instant room" })
    ).toBeVisible();
    await page.getByRole("button", { name: "Reveal" }).click();
    await expect(inviteLink).toHaveValue(fixture.shareUrl);
    await expect(page.getByRole("button", { name: "Hide", exact: true })).toHaveCSS(
      "min-height",
      "44px"
    );
    await expect(page.getByRole("button", { name: "Copy" })).toHaveCSS(
      "min-height",
      "44px"
    );
    await expect(page.getByRole("button", { name: "Share" })).toHaveCSS(
      "min-height",
      "44px"
    );
    await expectContained(inviteDialog, { width: 320, height: 700 });
    await expectNoDocumentOverflow(page);
    await expectNoWcagFailures(page);
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.screenshot({
        path: testInfo.outputPath("instant-room-invite-320.png"),
        fullPage: false
      });
    }
    await inviteDialog.getByRole("button", { name: "Hide invite details" }).click();
    await expect(inviteDialog).toHaveCount(0);
    await expect(invite).toBeFocused();
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
    { width: 600, height: 900 },
    { width: 768, height: 900 }
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

      const controls = [
        page.getByRole("button", { name: "Open room menu" }),
        page.getByRole("button", { name: "Invite people" }),
        page.getByRole("button", { name: "Copy invite link" }),
        page.getByRole("button", { name: /Participants/ }),
        page.getByRole("button", { name: "Start audio call" }),
        page.getByRole("button", { name: "Start video call" }),
        page.getByRole("button", { name: "Send" })
      ];
      for (const control of controls) {
        await expect(control).toBeVisible();
        await expectMinimumTarget(control);
        await expectContained(control, viewport);
      }
      await expectContained(
        page.getByRole("textbox", { name: "Message" }),
        viewport
      );
      await expectOnlyMessageScroller(page);
      await expectNoDocumentOverflow(page);
      expect(fixture.createRequests).toHaveLength(1);

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
        await expectContained(
          page.getByRole("button", { name: /Participants/ }),
          viewport
        );
        await expectContained(
          page.getByRole("textbox", { name: "Message" }),
          viewport
        );
        await expectContained(
          page.getByRole("button", { name: "Send" }),
          viewport
        );
      }

      if (viewport.width === 768) {
        const menuTrigger = page.getByRole("button", {
          name: "Open room menu"
        });
        await menuTrigger.click();
        await expect(
          page.getByRole("dialog", { name: "Room menu" })
        ).toBeVisible();
        await page.setViewportSize({ width: 769, height: viewport.height });
        await expect(
          page.getByRole("dialog", { name: "Room menu" })
        ).toHaveCount(0);
        await expect(
          page.getByRole("heading", { name: "Instant room" })
        ).toBeFocused();

        await page.setViewportSize(viewport);
        const participantToggle = page.getByRole("button", {
          name: /Participants/
        });
        await participantToggle.focus();
        await page.setViewportSize({ width: 769, height: viewport.height });
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
