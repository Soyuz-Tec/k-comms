import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";
import type { Page, Route } from "@playwright/test";
import { createHash } from "node:crypto";

const tenantId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const hostUserId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const guestUserId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const conversationId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const guestLinkId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const guestToken = "link.part_7FQpV9gN2_unique";
const conversionVerificationCode = "V".repeat(43);
const expiresAt = "2099-01-01T00:00:00Z";

test.describe("guest communication by secure link or QR", () => {
  test.beforeEach(({ page }, testInfo) => {
    void page;
    test.skip(testInfo.project.name !== "chromium", "deterministic guest flow runs once in Chromium");
  });

  test("host shares the exact fragment link and a guest joins, chats, then optionally creates an account", async ({ page }) => {
    const fixture = await installGuestCommunicationFixture(page, true);
    const observedRequestUrls: string[] = [];
    page.on("request", (request) => observedRequestUrls.push(request.url()));

    await page.goto(`/app/?conversation=${conversationId}`);
    await expect(page.getByRole("heading", { name: "Partner room" })).toBeVisible();

    await page.getByRole("button", { name: "Invite guest" }).click();
    const dialog = page.getByRole("dialog", { name: "Invite to Partner room" });
    await expect(dialog).toBeVisible();
    await dialog
      .getByRole("button", { name: "Preauthorize optional account creation" })
      .click();
    await dialog
      .getByRole("textbox", { name: "Authorized account email" })
      .fill("jordan@example.test");
    await dialog.getByRole("button", { name: "Create link and QR" }).click();

    const origin = new URL(page.url()).origin;
    const expectedJoinUrl =
      `${origin}/join#${new URLSearchParams({ guest: guestToken }).toString()}`;
    const linkField = dialog.getByRole("textbox", { name: "Secure guest link" });
    await expect(linkField).toHaveValue(expectedJoinUrl);
    await expect(linkField).not.toBeEditable();
    const verificationCodeField = dialog.getByRole("textbox", {
      name: "Account verification code"
    });
    await expect(verificationCodeField).toHaveValue(conversionVerificationCode);
    await expect(verificationCodeField).not.toBeEditable();
    await expect(linkField).not.toHaveValue(
      new RegExp(conversionVerificationCode)
    );
    await expect(dialog.locator(".guest-qr")).toHaveAttribute(
      "data-qr-fingerprint",
      qrValueFingerprint(expectedJoinUrl)
    );
    await expect(dialog.locator(".guest-qr")).not.toHaveAttribute("data-qr-value", /.+/);
    await expect(
      dialog.getByRole("img", { name: "QR code for the guest link to Partner room" })
    ).toBeVisible();
    await expect(dialog.getByRole("button", { name: "Copy link" })).toBeVisible();
    await expect(dialog.getByRole("button", { name: "Share…" })).toBeVisible();
    expect(fixture.createdLinkInput).toEqual({
      expires_in_seconds: 86_400,
      max_uses: 1,
      conversion_email: "jordan@example.test"
    });
    await dialog.getByRole("button", { name: "Revoke" }).click();
    const confirmation = page.getByRole("alertdialog", {
      name: "Revoke this guest link?"
    });
    await expect(confirmation).toBeVisible();
    const layers = await page.evaluate(() => ({
      confirmation: getComputedStyle(
        document.querySelector("[data-action-dialog-backdrop]") as HTMLElement
      ).zIndex,
      share: getComputedStyle(
        document.querySelector(".guest-dialog-backdrop") as HTMLElement
      ).zIndex
    }));
    expect(Number(layers.confirmation)).toBeGreaterThan(Number(layers.share));
    await confirmation.getByRole("button", { name: "Cancel" }).click();

    await page.evaluate(() => {
      sessionStorage.removeItem("k-comms.session.v1");
      sessionStorage.removeItem("k-comms.guest-session.v1");
    });
    fixture.guestPhase = true;
    await page.goto(expectedJoinUrl);

    await expect(page.getByRole("heading", { name: "Partner room" })).toBeVisible();
    await expect(page).toHaveURL(`${origin}/join`);
    await expectNoWcagFailures(page);
    expect(fixture.previewToken).toBe(guestToken);
    expect(observedRequestUrls.every((url) => !url.includes(guestToken))).toBe(true);

    const joinForm = page.locator(".guest-join-form");
    await expect(joinForm.getByRole("textbox")).toHaveCount(1);
    await joinForm.getByRole("textbox", { name: "Your display name" }).fill("Jordan Guest");
    await joinForm.getByRole("button", { name: "Join conversation" }).click();

    await expect(page.getByRole("main")).toHaveClass(/guest-shell/);
    await expect(page.getByRole("heading", { name: "Partner room" })).toBeVisible();
    const participantRoster = page.getByRole("list", {
      name: "Room participants"
    });
    await expect(participantRoster.getByText("Jordan Guest", { exact: false }))
      .toContainText("Jordan Guest (you)");
    await expect(participantRoster.getByText("Ada Host")).toBeVisible();
    expect(fixture.joinInput).toMatchObject({
      token: guestToken,
      display_name: "Jordan Guest",
      device: { platform: "web" }
    });

    const composer = page.getByRole("textbox", { name: "Message" });
    await expect(composer).toBeFocused();
    await composer.fill("Hello from the shared guest room");
    await composer.press("Enter");
    await expect(page.getByText("Hello from the shared guest room", { exact: true })).toBeVisible();
    await expect(
      page.locator(".guest-message-meta").filter({
        hasText: "Jordan Guest (you)"
      })
    ).toBeVisible();
    await expect(composer).toBeFocused();
    expect(fixture.guestMessageInput).toMatchObject({
      body: "Hello from the shared guest room",
      attachment_ids: []
    });
    expect(fixture.guestPhaseNormalMessageRequests).toEqual([]);

    await page.getByRole("button", { name: "Create account", exact: true }).click();
    const accountCard = page.getByRole("region", { name: "Keep your conversation" });
    const accountEmail = accountCard.getByRole("textbox", { name: "Work email" });
    await expect(accountEmail).toBeFocused();
    await accountEmail.fill("jordan@example.test");
    await accountCard
      .getByRole("textbox", { name: "Account verification code" })
      .fill(conversionVerificationCode);
    await accountCard.getByLabel("Password").fill("correct horse battery staple");
    await expectNoWcagFailures(page);
    await accountCard.getByRole("button", { name: "Create account", exact: true }).click();

    await expect(page).toHaveURL(new RegExp(`/app\\?conversation=${conversationId}$`));
    expect(fixture.conversionInput).toEqual({
      email: "jordan@example.test",
      verification_code: conversionVerificationCode,
      password: "correct horse battery staple"
    });
    await expect.poll(() => page.evaluate(() => {
      const value = sessionStorage.getItem("k-comms.session.v1");
      return value ? JSON.parse(value).user.account_type : null;
    })).toBe("human");
  });

  test("the one-step guest entry and room remain usable at 320px", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 640 });
    const fixture = await installGuestCommunicationFixture(page, false);
    const origin = "http://127.0.0.1:4178";

    await page.goto(
      `${origin}/join#${new URLSearchParams({ guest: guestToken }).toString()}`
    );

    const heading = page.getByRole("heading", { name: "Partner room" });
    const displayName = page.getByRole("textbox", { name: "Your display name" });
    const join = page.getByRole("button", { name: "Join conversation" });
    await expect(heading).toBeVisible();
    await expect(displayName).toBeVisible();
    await expect(join).toBeInViewport({ ratio: 0.99 });
    await expect(join).toHaveCSS("min-height", "48px");
    await expectNoDocumentOverflow(page);

    await displayName.fill("Phone Guest");
    await join.click();

    await expect(page.getByRole("heading", { name: "Partner room" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Create account" })).toBeVisible();
    await expect(page.getByRole("textbox", { name: "Message" })).toBeVisible();
    await expect(
      page.getByRole("list", { name: "Room participants" })
    ).toBeVisible();
    await expectNoDocumentOverflow(page);
    await expectNoWcagFailures(page);
    expect(fixture.joinInput?.display_name).toBe("Phone Guest");
  });
});

interface GuestFixture {
  createdLinkInput: Record<string, unknown> | null;
  previewToken: string | null;
  joinInput: Record<string, unknown> | null;
  guestMessageInput: Record<string, unknown> | null;
  conversionInput: Record<string, unknown> | null;
  guestPhase: boolean;
  guestPhaseNormalMessageRequests: string[];
}

async function installGuestCommunicationFixture(
  page: Page,
  authenticatedHost: boolean
): Promise<GuestFixture> {
  const fixture: GuestFixture = {
    createdLinkInput: null,
    previewToken: null,
    joinInput: null,
    guestMessageInput: null,
    conversionInput: null,
    guestPhase: false,
    guestPhaseNormalMessageRequests: []
  };
  const tenant = {
    id: tenantId,
    name: "Acme Workspace",
    slug: "acme",
    status: "active"
  };
  const host = {
    id: hostUserId,
    tenant_id: tenantId,
    display_name: "Ada Host",
    email: "ada@example.test",
    account_type: "human",
    role: "owner",
    status: "active",
    version: 1
  };
  const guest = {
    id: guestUserId,
    tenant_id: tenantId,
    display_name: "Jordan Guest",
    account_type: "guest",
    role: "member",
    status: "active",
    version: 1
  };
  const converted = {
    ...guest,
    email: "jordan@example.test",
    account_type: "human"
  };
  const hostDevice = {
    id: "11111111-1111-4111-8111-111111111111",
    user_id: hostUserId,
    name: "Host browser",
    platform: "web"
  };
  const guestDevice = {
    id: "22222222-2222-4222-8222-222222222222",
    user_id: guestUserId,
    name: "Guest browser",
    platform: "web"
  };
  const conversation = {
    id: conversationId,
    tenant_id: tenantId,
    kind: "group",
    title: "Partner room",
    counterpart_display_name: null,
    visibility: "private",
    latest_sequence: 0,
    last_read_sequence: 0,
    unread_count: 0,
    membership_role: "owner",
    version: 1,
    inserted_at: "2026-07-24T12:00:00Z",
    updated_at: "2026-07-24T12:00:00Z"
  };
  const guestConversation = { ...conversation, membership_role: "member" };
  const hostSession = authentication("host-access", "host-refresh", tenant, host, hostDevice);
  const guestSession = authentication("guest-access", "guest-refresh", tenant, guest, guestDevice);
  const convertedSession = authentication(
    "converted-access",
    "converted-refresh",
    tenant,
    converted,
    guestDevice
  );
  let guestMessages: Record<string, unknown>[] = [];

  if (authenticatedHost) {
    await page.addInitScript((session) => {
      const bootstrapKey = "k-comms.e2e.host-session-installed";
      if (sessionStorage.getItem(bootstrapKey) !== "true") {
        sessionStorage.setItem("k-comms.session.v1", JSON.stringify(session));
        sessionStorage.setItem(bootstrapKey, "true");
      }
      localStorage.setItem(
        `k-comms:onboarding:${session.tenant.id}:${session.user.id}`,
        "dismissed"
      );
    }, hostSession);
  }

  // The production Phoenix fallback serves the SPA at /join. Vite deliberately
  // protects its /app/ base during mocked source-client tests, so fulfill only
  // this document navigation with the same Vite index while preserving /join
  // in the browser address bar.
  await page.route("**/join", async (route) => {
    if (route.request().resourceType() !== "document") return route.continue();
    const response = await route.fetch({
      url: new URL("/app/", route.request().url()).toString()
    });
    return route.fulfill({ response });
  });

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    const method = request.method();
    const authorization = request.headers().authorization || "";
    const convertedRequest = authorization === "Bearer converted-access";

    if (
      fixture.guestPhase &&
      /^\/api\/v1\/conversations\/[^/]+\/messages$/.test(path)
    ) {
      fixture.guestPhaseNormalMessageRequests.push(`${method} ${path}`);
    }

    if (method === "GET" && path === "/api/v1/status") {
      return json(route, {
        service: "k-comms",
        version: "0.3.0",
        status: "operational",
        node: "guest-e2e@node",
        capabilities: {
          administration: true,
          audio_calls: false,
          video_calls: false,
          attachment_scanning: true,
          bootstrap: false,
          guest_links: true,
          notifications: true,
          push_notifications: false,
          realtime: false,
          webhooks: true
        }
      });
    }
    if (method === "POST" && path === "/api/v1/instant-rooms/preview") {
      // GuestAccessPage probes the new instant-room contract first because
      // both room kinds use the same fragment-only join route. This fixture
      // intentionally exercises a legacy host-created guest link, so mirror
      // the real endpoint's safe not-found response and allow the client to
      // fall back to /guest-links/preview.
      return json(route, {
        error: {
          code: "not_found",
          detail: "The room link is unavailable."
        }
      }, 404);
    }
    if (method === "GET" && path === "/api/v1/me") {
      const identity = convertedRequest ? convertedSession : hostSession;
      return json(route, {
        tenant: identity.tenant,
        user: identity.user,
        device: identity.device,
        capabilities: {
          allow_audio_calls: false,
          allow_video_calls: false,
          allow_public_channels: true,
          message_edit_window_seconds: 900,
          max_attachment_bytes: 25_000_000
        }
      });
    }
    if (method === "GET" && path === "/api/v1/users") {
      return json(route, { data: convertedRequest ? [converted] : [host] });
    }
    if (method === "GET" && path === "/api/v1/conversations") {
      return json(route, { data: [convertedRequest ? guestConversation : conversation] });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/members`) {
      return json(route, {
        data: [{
          id: "33333333-3333-4333-8333-333333333333",
          role: convertedRequest ? "member" : "owner",
          joined_at: "2026-07-24T12:00:00Z",
          last_read_sequence: 0,
          version: 1,
          user: convertedRequest ? converted : host
        }]
      });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/messages`) {
      return json(route, {
        data: convertedRequest ? guestMessages : [],
        page: { has_more: false, next_after_sequence: null, reset_required: false }
      });
    }
    if (method === "PUT" && path === `/api/v1/conversations/${conversationId}/read-cursor`) {
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && path === `/api/v1/conversations/${conversationId}/call`) {
      return json(route, { data: null });
    }
    if (method === "POST" && path === `/api/v1/conversations/${conversationId}/guest-links`) {
      fixture.createdLinkInput = request.postDataJSON();
      const shareUrl =
        `${url.origin}/join#${new URLSearchParams({ guest: guestToken }).toString()}`;
      return json(route, {
        data: {
          id: guestLinkId,
          tenant_id: tenantId,
          conversation_id: conversationId,
          created_by_user_id: hostUserId,
          expires_at: expiresAt,
          max_uses: 1,
          use_count: 0,
          conversion_enabled: true,
          email_hint: "j***@example.test",
          revoked_at: null,
          version: 1,
          share_url: shareUrl
        },
        token: guestToken,
        conversion_verification_code: conversionVerificationCode
      }, 201);
    }
    if (method === "POST" && path === "/api/v1/guest-links/preview") {
      fixture.previewToken = request.postDataJSON().token;
      return json(route, {
        data: {
          room_title: guestConversation.title,
          expires_at: expiresAt,
          conversion_enabled: true,
          email_hint: "j***@example.test"
        }
      });
    }
    if (method === "POST" && path === "/api/v1/guest-sessions") {
      fixture.joinInput = request.postDataJSON();
      const displayName = fixture.joinInput?.display_name || guest.display_name;
      guest.display_name = String(displayName);
      return json(route, {
        data: {
          authentication: { ...guestSession, user: { ...guest, display_name: displayName } },
          conversation: guestConversation,
          capabilities: {
            allow_audio_calls: false,
            allow_video_calls: false,
            conversion_enabled: true,
            email_hint: "j***@example.test"
          },
          admission: {
            guest_link_id: guestLinkId,
            expires_at: expiresAt
          }
        }
      }, 201);
    }
    if (method === "GET" && path === "/api/v1/guest/conversation") {
      return json(route, { data: guestConversation });
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/members") {
      return json(route, {
        data: [
          {
            id: "33333333-3333-4333-8333-333333333333",
            role: "owner",
            joined_at: "2026-07-24T11:00:00Z",
            last_read_sequence: 0,
            version: 1,
            user: host
          },
          {
            id: "44444444-4444-4444-8444-444444444444",
            role: "member",
            joined_at: "2026-07-24T12:00:00Z",
            last_read_sequence: 0,
            version: 1,
            user: guest
          }
        ]
      });
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/messages") {
      return json(route, {
        data: guestMessages,
        page: { has_more: false, next_after_sequence: null, reset_required: false }
      });
    }
    if (method === "POST" && path === "/api/v1/guest/conversation/messages") {
      fixture.guestMessageInput = request.postDataJSON();
      const message = {
        id: "55555555-5555-4555-8555-555555555555",
        tenant_id: tenantId,
        conversation_id: conversationId,
        sender_user_id: guestUserId,
        sender_device_id: guestDevice.id,
        client_message_id: request.headers()["idempotency-key"],
        conversation_sequence: 1,
        body: fixture.guestMessageInput.body,
        metadata: {},
        status: "active",
        thread_root_message_id: null,
        thread_reply_count: 0,
        mentioned_user_ids: [],
        inserted_at: "2026-07-24T12:01:00Z",
        attachments: [],
        reactions: []
      };
      guestMessages = [message];
      return json(route, { data: message }, 201);
    }
    if (method === "PUT" && path === "/api/v1/guest/conversation/read-cursor") {
      return route.fulfill({ status: 204 });
    }
    if (method === "POST" && path === "/api/v1/guest/socket-tickets") {
      return json(route, {
        error: {
          code: "realtime_unavailable_in_mock",
          detail: "Realtime is intentionally disabled in this mocked browser test."
        }
      }, 503);
    }
    if (method === "GET" && path === "/api/v1/guest/conversation/call") {
      return json(route, { data: null });
    }
    if (method === "POST" && path === "/api/v1/guest/account") {
      fixture.conversionInput = request.postDataJSON();
      return json(route, {
        data: {
          authentication: convertedSession,
          conversation: guestConversation
        }
      });
    }
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, {
        data: [],
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: 0 }
      });
    }

    return json(route, { data: [] });
  });

  return fixture;
}

function authentication(
  accessToken: string,
  refreshToken: string,
  tenant: Record<string, unknown>,
  user: Record<string, unknown>,
  device: Record<string, unknown>
) {
  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: "Bearer",
    expires_in: 3_600,
    received_at: Date.now(),
    tenant,
    user,
    device
  };
}

function qrValueFingerprint(value: string) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body)
  });
}

async function expectNoDocumentOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => ({
    client: document.documentElement.clientWidth,
    scroll: document.documentElement.scrollWidth
  }))).toEqual({ client: 320, scroll: 320 });
}

async function expectNoWcagFailures(page: Page) {
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(results.violations.map(({ id, nodes }) => ({
    id,
    targets: nodes.map((node) => node.target)
  }))).toEqual([]);
}
