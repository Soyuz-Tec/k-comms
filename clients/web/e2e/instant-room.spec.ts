import { expect, mockServiceStatus, test } from "./fixtures";
import type { Page, Route } from "@playwright/test";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const guestId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const conversationId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const roomId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

test.describe("instant-room front door", () => {
  test.beforeEach(({ page }, testInfo) => {
    void page;
    test.skip(
      testInfo.project.name !== "chromium",
      "deterministic front-door flow runs once in Chromium"
    );
  });

  test("creates once and exposes a one-step shareable room at 320px", async ({ page }) => {
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
    await expect(page.getByLabel("Room invite link")).toHaveValue(fixture.shareUrl);
    await expect(
      page.getByRole("img", { name: "Scan to join Instant room" })
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Copy" })).toHaveCSS(
      "min-height",
      "44px"
    );
    await expect(page.getByRole("button", { name: "Share" })).toHaveCSS(
      "min-height",
      "44px"
    );
    await expect(page.getByRole("textbox", { name: "Message" })).toBeVisible();
    await expect(page.getByText("Presence unknown · 1 total")).toBeVisible();
    await expect(
      page
        .getByRole("list", { name: "Room participants" })
        .getByText("Taylor Host", { exact: false })
    ).toContainText("Taylor Host (you)");

    expect(fixture.createRequests).toHaveLength(1);
    expect(fixture.createRequests[0]).toMatchObject({
      display_name: "Taylor Host",
      title: "Instant room"
    });
    expect(fixture.idempotencyKeys).toHaveLength(1);
    expect(fixture.idempotencyKeys[0]).toMatch(/^[A-Za-z0-9_-]{43}$/);
    await expectNoDocumentOverflow(page);

    const storage = await page.evaluate(() => ({
      session: sessionStorage.getItem("k-comms.guest-session.v1"),
      persistent: localStorage.getItem("k-comms.guest-session.v1")
    }));
    expect(storage.session).toContain("guest-access");
    expect(storage.persistent).toBeNull();
  });
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
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(1);
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body)
  });
}
