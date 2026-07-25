import { expect, test } from "@playwright/test";
import type {
  APIRequestContext,
  APIResponse,
  Browser,
  Page,
  TestInfo
} from "@playwright/test";
import { createHash, randomUUID } from "node:crypto";
import type { Conversation, GuestSession, Session } from "../src/types";

// Playwright's AI failure context is separate from trace/screenshot/video and
// would otherwise retain the share field's runtime value in an ARIA snapshot.
process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";

const enabled =
  process.env.K_COMMS_LIVE_GUEST_E2E === "true" &&
  process.env.K_COMMS_EXTERNAL_E2E_SERVER === "true";
const liveStackURL =
  process.env.K_COMMS_LIVE_GUEST_BASE_URL || "http://127.0.0.1:4178";

interface BootstrapResponse extends Session {
  conversation: Conversation;
}

interface DataResponse<T> {
  data: T;
}

interface GuestLinkResponse {
  data: {
    id: string;
    conversation_id: string;
    conversion_enabled: boolean;
    email_hint: string | null;
  };
  token: string;
  share_url: string;
  conversion_verification_code: string;
}

interface LiveGuestSession extends GuestSession {
  capabilities: GuestSession["capabilities"] & {
    conversion_enabled: boolean;
    email_hint: string | null;
  };
}

test.use({ trace: "off", screenshot: "off", video: "off" });

test.describe("sealed guest communication qualification", () => {
  test.describe.configure({ mode: "serial" });
  test.skip(
    !enabled,
    "set K_COMMS_LIVE_GUEST_E2E=true and K_COMMS_EXTERNAL_E2E_SERVER=true to run against the packaged K-Comms release"
  );
  test.setTimeout(90_000);

  test("a shared link admits one guest, delivers a realtime message, and revocation ends API and socket access", async ({
    browser,
    request
  }, testInfo) => {
    const fixture = await provisionOwnerJourney(request);
    const createdGuestLinkIds = new Set<string>();
    const ownerContext = await ownerBrowserContext(browser, fixture.owner, testInfo);
    const guestContext = await browser.newContext({
      baseURL: String(testInfo.project.use.baseURL || liveStackURL)
    });
    let primaryTestFailed = false;
    let testFailure: unknown;

    try {
      const ownerPage = await ownerContext.newPage();
      const guestPage = await guestContext.newPage();
      const conversationURL =
        `/app/?conversation=${encodeURIComponent(fixture.conversation.id)}`;

      await ownerPage.goto(conversationURL);
      await expect(
        ownerPage.getByRole("heading", { name: fixture.conversation.title || "Guest qualification" })
      ).toBeVisible({ timeout: 20_000 });
      await expect(
        ownerPage.locator(".connection-summary").getByText("Live", { exact: true })
      ).toBeVisible({ timeout: 20_000 });

      await ownerPage.getByRole("button", { name: "Invite guest" }).click();
      await expect(
        ownerPage.getByRole("heading", {
          name: `Invite to ${fixture.conversation.title || "Guest qualification"}`
        })
      ).toBeVisible();
      await ownerPage.getByRole("button", { name: "Create link and QR" }).click();

      const secureLink = ownerPage.getByRole("textbox", { name: "Secure guest link" });
      const shareURL = await secureLink.inputValue({ timeout: 20_000 });
      await secureLink.evaluate((element) => {
        const input = element as HTMLInputElement;
        input.value = "[redacted secure guest link]";
        input.setAttribute("value", "[redacted secure guest link]");
      });
      await expect(secureLink).toBeVisible();
      await expect(secureLink).not.toBeEditable();
      assertGuestShareURL(shareURL);
      const shareURLFingerprint = qrValueFingerprint(shareURL);

      const qr = ownerPage.locator(".guest-qr");
      await expect(qr).toHaveAttribute(
        "data-qr-fingerprint",
        shareURLFingerprint
      );
      await expect(qr).not.toHaveAttribute("data-qr-value", /.+/);
      await expect(
        qr.getByRole("img", {
          name: `QR code for the guest link to ${fixture.conversation.title || "Guest qualification"}`
        })
      ).toBeVisible();
      await ownerPage.getByRole("button", { name: "Close guest invitation" }).click();
      await expect(qr).toBeHidden();

      const linkListResponse = await request.get(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/guest-links`,
        { headers: authorization(fixture.owner) }
      );
      const linkList = await expectJSON<
        DataResponse<Array<{ id: string; status: string }>>
      >(linkListResponse, 200, "guest-link list after browser creation");
      const createdLink = linkList.data.find(({ status }) => status === "active");
      if (!createdLink) {
        throw new Error("browser-created guest link was not listed as active");
      }
      createdGuestLinkIds.add(createdLink.id);

      await navigateToGuestLink(guestPage, shareURL);
      await expect
        .poll(
          () =>
            guestPage.evaluate(
              () =>
                window.location.pathname === "/join" &&
                window.location.hash === "" &&
                !window.location.href.includes("guest=")
            ),
          { message: "guest navigation did not scrub the redacted fragment" }
        )
        .toBe(true);
      await expect(
        guestPage.getByRole("heading", { name: fixture.conversation.title || "Guest qualification" })
      ).toBeVisible({ timeout: 20_000 });
      await guestPage.getByRole("textbox", { name: "Your display name" }).fill("Sealed Guest");
      await guestPage.getByRole("button", { name: "Join conversation" }).click();
      await expect(guestPage.locator(".guest-connection.live")).toHaveText("live", {
        timeout: 20_000
      });
      const guest = await guestPage.evaluate(() => {
        const value = sessionStorage.getItem("k-comms.guest-session.v1");
        if (!value) throw new Error("guest session was not stored after browser join");
        return JSON.parse(value) as LiveGuestSession;
      });
      expect(guest.conversation.id).toBe(fixture.conversation.id);
      expect(guest.capabilities.conversion_enabled).toBe(false);

      const messageBody = `Sealed guest message ${fixture.suffix}`;
      const composer = guestPage.getByRole("textbox", { name: "Message" });
      await composer.fill(messageBody);
      await composer.press("Enter");

      await expect(
        ownerPage.getByText(messageBody, { exact: true })
      ).toBeVisible({ timeout: 20_000 });

      const hostHistory = await request.get(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/messages`,
        { headers: authorization(fixture.owner) }
      );
      const history = await expectJSON<{ data: Array<{ body: string }> }>(
        hostHistory,
        200,
        "host message history"
      );
      expect(history.data.some((message) => message.body === messageBody)).toBe(true);

      const revoke = await request.delete(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}` +
          `/guest-links/${encodeURIComponent(createdLink.id)}`,
        { headers: authorization(fixture.owner) }
      );
      await expectStatus(revoke, 200, "guest-link revocation");
      createdGuestLinkIds.delete(createdLink.id);

      await expect(
        guestPage.getByRole("heading", { name: "This guest link is unavailable" })
      ).toBeVisible({ timeout: 20_000 });
      await expect(
        guestPage.getByRole("alert").filter({
          hasText: "This communication link is unavailable"
        })
      ).toBeVisible({ timeout: 20_000 });
      await expect(
        guestPage.getByRole("link", { name: "Return to K-Comms sign in" })
      ).toBeVisible({ timeout: 20_000 });

      const deniedConversation = await request.get("/api/v1/guest/conversation", {
        headers: authorization(guest)
      });
      await expectStatus(deniedConversation, 401, "revoked guest conversation access");

      const deniedTicket = await request.post("/api/v1/guest/socket-tickets", {
        headers: authorization(guest)
      });
      await expectStatus(deniedTicket, 401, "revoked guest socket access");
    } catch (error) {
      primaryTestFailed = true;
      testFailure = error;
    } finally {
      const [linkCleanup] = await Promise.allSettled([
        revokeCreatedGuestLinks(request, fixture, createdGuestLinkIds),
        ownerContext.close(),
        guestContext.close()
      ]);
      if (!primaryTestFailed && linkCleanup.status === "rejected") {
        testFailure = linkCleanup.reason;
      }
    }
    if (primaryTestFailed || testFailure !== undefined) throw testFailure;
  });

  test("a pre-authorized guest may convert in place while a mismatched email fails closed", async ({
    request
  }) => {
    const ownerFixture = await provisionOwnerJourney(request);
    const createdGuestLinkIds = new Set<string>();
    let primaryTestFailed = false;
    let testFailure: unknown;

    try {
      const fixture = await provisionGuestJourney(
        request,
        ownerFixture,
        createdGuestLinkIds
      );
      const convertedPassword = strongPassword();

      const mismatchedConversion = await request.post("/api/v1/guest/account", {
        headers: authorization(fixture.guest),
        data: {
          email: `wrong-${fixture.suffix}@example.test`,
          password: strongPassword()
        }
      });
      const mismatch = await expectJSON<{
        error: { code: string; detail: string };
      }>(mismatchedConversion, 403, "mismatched guest conversion");
      expect(mismatch.error.code).toBe(
        "guest_account_conversion_email_mismatch"
      );

      const stillGuest = await request.get("/api/v1/guest/conversation", {
        headers: authorization(fixture.guest)
      });
      await expectStatus(stillGuest, 200, "guest access after rejected conversion");

      const conversionResponse = await request.post("/api/v1/guest/account", {
        headers: authorization(fixture.guest),
        data: {
          email: fixture.conversionEmail,
          password: convertedPassword,
          verification_code: fixture.conversionVerificationCode,
          display_name: "Converted Sealed Guest",
          device: {
            name: "Converted sealed guest browser",
            platform: "playwright"
          }
        }
      });
      const conversion = await expectJSON<{
        authentication: Session;
        conversation: Conversation;
      }>(conversionResponse, 200, "guest account conversion");
      expect(conversion.authentication.user.id).toBe(fixture.guest.user.id);
      expect(conversion.authentication.user.account_type).toBe("human");
      expect(conversion.conversation.id).toBe(fixture.conversation.id);

      const humanAccess = await request.get("/api/v1/me", {
        headers: authorization(conversion.authentication)
      });
      const currentHuman = await expectJSON<{
        user: { id: string; account_type: string };
      }>(humanAccess, 200, "converted human access");
      expect(currentHuman.user).toMatchObject({
        id: fixture.guest.user.id,
        account_type: "human"
      });

      const oldGuestAccess = await request.get("/api/v1/guest/conversation", {
        headers: authorization(fixture.guest)
      });
      await expectStatus(oldGuestAccess, 401, "old guest credential after conversion");
    } catch (error) {
      primaryTestFailed = true;
      testFailure = error;
    } finally {
      try {
        await revokeCreatedGuestLinks(
          request,
          ownerFixture,
          createdGuestLinkIds
        );
      } catch (error) {
        if (!primaryTestFailed) testFailure = error;
      }
    }
    if (primaryTestFailed || testFailure !== undefined) throw testFailure;
  });
});

async function provisionGuestJourney(
  request: APIRequestContext,
  fixture: Awaited<ReturnType<typeof provisionOwnerJourney>>,
  createdGuestLinkIds: Set<string>
) {
  const { owner, ownerPassword, conversation, conversionEmail } = fixture;

  const stepUp = await request.post("/api/v1/me/step-up", {
    headers: authorization(owner),
    data: { current_password: ownerPassword }
  });
  await expectStatus(stepUp, 200, "owner step-up");

  const guestLinkResponse = await request.post(
    `/api/v1/conversations/${encodeURIComponent(conversation.id)}/guest-links`,
    {
      headers: authorization(owner),
      data: {
        expires_in_seconds: 900,
        max_uses: 1,
        conversion_email: conversionEmail
      }
    }
  );
  const guestLink = await expectJSON<GuestLinkResponse>(
    guestLinkResponse,
    201,
    "guest-link creation"
  );
  expect(guestLink.data.conversation_id).toBe(conversation.id);
  expect(guestLink.data.conversion_enabled).toBe(true);
  expect(guestLink.data.email_hint).toBeTruthy();
  expect(guestLink.share_url.includes("/join#guest=")).toBe(true);
  createdGuestLinkIds.add(guestLink.data.id);

  const previewResponse = await request.post("/api/v1/guest-links/preview", {
    data: { token: guestLink.token }
  });
  const preview = await expectJSON<{
    data: {
      room_title: string;
      expires_at: string;
      conversion_enabled: boolean;
      email_hint: string | null;
    };
  }>(previewResponse, 200, "guest-link preview");
  expect(Object.keys(preview.data).sort()).toEqual(
    ["conversion_enabled", "email_hint", "expires_at", "room_title"].sort()
  );
  expect(preview.data.room_title).toBe(conversation.title);
  expect(preview.data.conversion_enabled).toBe(true);
  expect(preview.data.email_hint).toBeTruthy();

  const guestSessionResponse = await request.post("/api/v1/guest-sessions", {
    data: {
      token: guestLink.token,
      display_name: "Sealed Guest",
      device: {
        name: "Sealed guest browser",
        platform: "playwright"
      }
    }
  });
  const guest = withReceivedAt(
    await expectJSON<LiveGuestSession>(
      guestSessionResponse,
      201,
      "guest-link redemption"
    )
  );
  expect(guest.conversation.id).toBe(conversation.id);
  expect(guest.capabilities.conversion_enabled).toBe(true);
  expect(guest.capabilities.email_hint).toBeTruthy();

  return {
    ...fixture,
    guest,
    guestLinkId: guestLink.data.id,
    conversionVerificationCode: guestLink.conversion_verification_code
  };
}

async function provisionOwnerJourney(request: APIRequestContext) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
  const tenantSlug = `guest-e2e-${suffix}`;
  const ownerPassword = strongPassword();
  const conversionEmail = `guest-convert-${suffix}@example.test`;

  const bootstrap = await request.post("/api/v1/bootstrap", {
    data: {
      tenant_name: `Guest E2E ${suffix}`,
      tenant_slug: tenantSlug,
      display_name: "Guest Journey Owner",
      email: `guest-owner-${suffix}@example.test`,
      password: ownerPassword
    }
  });
  const owner = withReceivedAt(
    await expectJSON<BootstrapResponse>(bootstrap, 201, "workspace bootstrap")
  );

  const conversationResponse = await request.post("/api/v1/conversations", {
    headers: authorization(owner),
    data: {
      kind: "group",
      visibility: "private",
      title: "Guest qualification",
      member_ids: []
    }
  });
  const conversation = (
    await expectJSON<DataResponse<Conversation>>(
      conversationResponse,
      201,
      "guest qualification conversation"
    )
  ).data;

  return {
    suffix,
    owner,
    ownerPassword,
    conversation,
    conversionEmail
  };
}

async function ownerBrowserContext(
  browser: Browser,
  owner: Session,
  testInfo: TestInfo
) {
  const baseURL = String(testInfo.project.use.baseURL || liveStackURL);
  const context = await browser.newContext({ baseURL });
  await context.addInitScript((session: Session) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(session));
    localStorage.setItem(
      `k-comms:onboarding:${session.tenant.id}:${session.user.id}`,
      "dismissed"
    );
  }, owner);
  return context;
}

async function navigateToGuestLink(page: Page, shareURL: string) {
  try {
    await page.goto(shareURL);
  } catch {
    throw new Error("guest-link navigation failed; URL redacted");
  }
}

function assertGuestShareURL(value: string) {
  try {
    const url = new URL(value);
    if (url.pathname !== "/join" || !url.hash.startsWith("#guest=")) {
      throw new Error();
    }
  } catch {
    throw new Error("browser-created guest link had an invalid redacted URL shape");
  }
}

function qrValueFingerprint(value: string) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

async function revokeCreatedGuestLinks(
  request: APIRequestContext,
  fixture: Awaited<ReturnType<typeof provisionOwnerJourney>>,
  createdGuestLinkIds: Set<string>
) {
  let initialListFailureCount = 0;
  let initialLinks: Array<{ id: string; status: string }> = [];
  try {
    initialLinks = await listGuestLinksForCleanup(request, fixture, "initial");
  } catch {
    initialListFailureCount = 1;
  }
  for (const link of initialLinks) {
    if (link.status === "active") createdGuestLinkIds.add(link.id);
  }

  const trackedIds = [...createdGuestLinkIds];
  const deletionResults = await Promise.all(
    trackedIds.map(async (id) => {
      try {
        const response = await request.delete(
          `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}` +
            `/guest-links/${encodeURIComponent(id)}`,
          { headers: authorization(fixture.owner) }
        );
        return response.status() === 200;
      } catch {
        return false;
      }
    })
  );
  const failedDeleteCount = deletionResults.filter((succeeded) => !succeeded).length;

  let verificationListFailureCount = 0;
  let verificationLinks: Array<{ id: string; status: string }> = [];
  try {
    verificationLinks = await listGuestLinksForCleanup(
      request,
      fixture,
      "verification"
    );
  } catch {
    verificationListFailureCount = 1;
  }
  const activeIds = new Set(
    verificationLinks
      .filter(({ status }) => status === "active")
      .map(({ id }) => id)
  );
  const remainingTrackedActiveCount = trackedIds.filter((id) =>
    activeIds.has(id)
  ).length;

  if (
    initialListFailureCount > 0 ||
    failedDeleteCount > 0 ||
    verificationListFailureCount > 0 ||
    remainingTrackedActiveCount > 0
  ) {
    throw new Error(
      "guest-link cleanup incomplete: " +
        `initial list failures=${initialListFailureCount}; ` +
        `delete failures=${failedDeleteCount}; ` +
        `verification list failures=${verificationListFailureCount}; ` +
        `tracked active links=${remainingTrackedActiveCount}`
    );
  }

  createdGuestLinkIds.clear();
}

async function listGuestLinksForCleanup(
  request: APIRequestContext,
  fixture: Awaited<ReturnType<typeof provisionOwnerJourney>>,
  phase: "initial" | "verification"
): Promise<Array<{ id: string; status: string }>> {
  let response: APIResponse;
  try {
    response = await request.get(
      `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/guest-links`,
      { headers: authorization(fixture.owner) }
    );
  } catch {
    throw new Error(`guest-link cleanup ${phase} list request failed`);
  }

  if (response.status() !== 200) {
    throw new Error(`guest-link cleanup ${phase} list was unsuccessful`);
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new Error(`guest-link cleanup ${phase} list returned invalid data`);
  }

  const data = (payload as { data?: unknown } | null)?.data;
  if (!Array.isArray(data) || !data.every(isGuestLinkSummary)) {
    throw new Error(`guest-link cleanup ${phase} list returned invalid data`);
  }

  return data;
}

function isGuestLinkSummary(
  value: unknown
): value is { id: string; status: string } {
  if (typeof value !== "object" || value === null) return false;
  const link = value as { id?: unknown; status?: unknown };
  return typeof link.id === "string" && typeof link.status === "string";
}

function authorization(session: Pick<Session, "access_token">) {
  return { Authorization: `Bearer ${session.access_token}` };
}

function withReceivedAt<T extends Session>(session: T): T {
  return { ...session, received_at: Date.now() };
}

function strongPassword() {
  return `Kc!${randomUUID()}Aa9`;
}

async function expectStatus(
  response: APIResponse,
  expectedStatus: number,
  step: string
) {
  if (response.status() !== expectedStatus) {
    throw new Error(`${step} failed with status ${response.status()}`);
  }
}

async function expectJSON<T>(
  response: APIResponse,
  expectedStatus: number,
  step: string
): Promise<T> {
  await expectStatus(response, expectedStatus, step);
  return (await response.json()) as T;
}
