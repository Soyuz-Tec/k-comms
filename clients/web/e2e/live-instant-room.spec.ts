import { expect, test } from "@playwright/test";
import type { Browser, BrowserContext, Page } from "@playwright/test";
import { createHash, randomUUID } from "node:crypto";

// The room URL contains a bearer credential. Keep Playwright's optional AI
// failure context, traces, screenshots, and video from retaining that value.
process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";

const enabled =
  process.env.K_COMMS_LIVE_INSTANT_ROOM_E2E === "true" &&
  process.env.K_COMMS_EXTERNAL_E2E_SERVER === "true";
const guestSessionStorageKey = "k-comms.guest-session.v1";

interface StoredRoomIdentity {
  userId: string;
  accountType: string | null;
  tenantId: string;
  tenantSlug: string;
  roomId: string;
  conversationId: string;
}

test.use({ trace: "off", screenshot: "off", video: "off" });

test.describe("real-stack instant-room acceptance", () => {
  test.describe.configure({ mode: "serial" });
  test.skip(
    !enabled,
    "set K_COMMS_LIVE_INSTANT_ROOM_E2E=true and K_COMMS_EXTERNAL_E2E_SERVER=true to run against an instant-room-enabled K-Comms release"
  );
  test.setTimeout(120_000);

  test("creates in isolation then communicates through the retained public app", async ({
    browser
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the bearer-safe real-stack journey runs once in Chromium"
    );
    const {
      clientAddress,
      qualificationAppOrigin,
      publicOrigin,
      tenantSlug
    } = sealedInstantRoomEnvironment();
    let qualificationContext: BrowserContext | null =
      await qualificationRoomContext(
        browser,
        qualificationAppOrigin,
        clientAddress
      );
    let hostContext: BrowserContext | null = null;
    let guestContext: BrowserContext | null = null;
    let createRequestCount = 0;
    let createRequestUsedClientAddress = false;
    let createRequestUsedQualificationOriginHeader = false;
    let createRequestUsedQualificationOrigin = false;
    let createRequestUsedUnexpectedOrigin = false;
    let publicRequestUsedForwardedFor = false;

    try {
      const qualificationPage = await qualificationContext.newPage();
      qualificationPage.on("request", async (request) => {
        if (
          request.method() === "POST" &&
          new URL(request.url()).pathname === "/api/v1/instant-rooms"
        ) {
          // Playwright intentionally omits security-related headers such as
          // Origin from request.headers(). Read only the two headers this
          // isolation proof needs, without materializing cookies or tokens.
          const [forwardedFor, originHeader] = await Promise.all([
            request.headerValue("x-forwarded-for"),
            request.headerValue("origin")
          ]);
          const requestOrigin = new URL(request.url()).origin;
          createRequestUsedClientAddress =
            forwardedFor === clientAddress;
          createRequestUsedQualificationOriginHeader =
            originHeader === qualificationAppOrigin;
          createRequestUsedQualificationOrigin =
            requestOrigin === qualificationAppOrigin;
          createRequestUsedUnexpectedOrigin =
            requestOrigin !== qualificationAppOrigin;
          createRequestCount += 1;
        }
      });

      await qualificationPage.goto(
        new URL("/", qualificationAppOrigin).toString()
      );
      await expect(
        qualificationPage.getByRole("heading", {
          name: "Start an instant room"
        })
      ).toBeVisible({ timeout: 30_000 });
      await qualificationPage
        .getByRole("textbox", { name: "Your display name" })
        .fill("Live Room Host");
      await qualificationPage
        .getByRole("button", { name: "Start instant room" })
        .click();
      await expect(
        qualificationPage.getByRole("heading", { name: "Instant room" })
      ).toBeVisible({ timeout: 30_000 });
      await expect(
        qualificationPage.locator(".guest-connection.live")
      ).toHaveText("live", { timeout: 30_000 });
      await expect.poll(() => createRequestCount).toBe(1);
      expect(createRequestUsedClientAddress).toBe(true);
      expect(createRequestUsedQualificationOriginHeader).toBe(true);
      expect(createRequestUsedQualificationOrigin).toBe(true);
      expect(createRequestUsedUnexpectedOrigin).toBe(false);

      const hostIdentity = await storedGuestRoomIdentity(qualificationPage);
      expect(hostIdentity).toMatchObject({
        accountType: "guest",
        tenantSlug
      });
      const shareField = qualificationPage.getByRole("textbox", {
        name: /(?:Secure room|Room invite) link/
      });
      const shareURL = await shareField.inputValue();
      assertInstantRoomShareURL(shareURL, publicOrigin);

      const shareFingerprint = qrValueFingerprint(shareURL);
      const qr = qualificationPage.locator(".guest-qr");
      await redactShareField(qualificationPage);
      await expect(qr).toHaveAttribute(
        "data-qr-fingerprint",
        shareFingerprint,
        { timeout: 20_000 }
      );
      await expect(
        qr.getByRole("img", { name: "Scan to join Instant room" })
      ).toBeVisible();

      const hostGuestSession =
        await captureGuestSessionForHandoff(qualificationPage);
      await qualificationContext.close();
      qualificationContext = null;

      hostContext = await roomContext(browser, publicOrigin);
      await installGuestSessionHandoff(
        hostContext,
        publicOrigin,
        hostGuestSession
      );
      guestContext = await roomContext(browser, publicOrigin);
      const hostPage = await hostContext.newPage();
      const guestPage = await guestContext.newPage();
      for (const page of [hostPage, guestPage]) {
        page.on("request", (request) => {
          if ("x-forwarded-for" in request.headers()) {
            publicRequestUsedForwardedFor = true;
          }
          if (
            request.method() === "POST" &&
            new URL(request.url()).pathname === "/api/v1/instant-rooms"
          ) {
            createRequestCount += 1;
            createRequestUsedUnexpectedOrigin = true;
          }
        });
      }

      await hostPage.goto(new URL("/", publicOrigin).toString());
      await expect(
        hostPage.getByRole("heading", { name: "Instant room" })
      ).toBeVisible({ timeout: 30_000 });
      await redactShareField(hostPage);
      await expect(hostPage.locator(".guest-connection.live")).toHaveText(
        "live",
        { timeout: 30_000 }
      );
      expect(await storedGuestRoomIdentity(hostPage)).toEqual(hostIdentity);
      await expect.poll(() => createRequestCount).toBe(1);
      expect(createRequestUsedUnexpectedOrigin).toBe(false);
      expect(publicRequestUsedForwardedFor).toBe(false);

      await navigateToSecureRoom(guestPage, shareURL);
      await expect
        .poll(() =>
          guestPage.evaluate(() => ({
            pathname: window.location.pathname,
            fragmentCleared: window.location.hash === "",
            queryCleared: new URL(window.location.href).search === ""
          }))
        )
        .toEqual({
          pathname: "/join",
          fragmentCleared: true,
          queryCleared: true
        });

      await expect(
        guestPage.getByRole("heading", { name: "Instant room" })
      ).toBeVisible({ timeout: 30_000 });
      await guestPage
        .getByRole("textbox", { name: "Your display name" })
        .fill("Live Room Guest");
      await guestPage
        .getByRole("button", { name: "Join conversation" })
        .click();

      await Promise.all([
        expect(hostPage.locator(".guest-connection.live")).toHaveText("live", {
          timeout: 30_000
        }),
        expect(guestPage.locator(".guest-connection.live")).toHaveText("live", {
          timeout: 30_000
        }),
        expect(hostPage.getByText(/2 people online/i)).toBeVisible({
          timeout: 30_000
        }),
        expect(guestPage.getByText(/2 people online/i)).toBeVisible({
          timeout: 30_000
        })
      ]);
      await expect(
        guestPage.getByRole("textbox", {
          name: /(?:Secure room|Room invite) link/
        })
      ).toHaveCount(0);

      const hostRoster = hostPage.getByRole("list", {
        name: "Room participants"
      });
      const guestRoster = guestPage.getByRole("list", {
        name: "Room participants"
      });
      await Promise.all([
        expect(hostRoster.getByText("Live Room Guest")).toBeVisible({
          timeout: 30_000
        }),
        expect(guestRoster.getByText("Live Room Guest", { exact: false }))
          .toContainText("Live Room Guest (you)", { timeout: 30_000 }),
        expect(hostRoster.getByText("Live Room Host", { exact: false }))
          .toContainText("Live Room Host (you)", { timeout: 30_000 }),
        expect(guestRoster.getByText("Live Room Host")).toBeVisible({
          timeout: 30_000
        })
      ]);

      const guestIdentity = await storedGuestRoomIdentity(guestPage);
      expect(guestIdentity).toMatchObject({
        tenantId: hostIdentity.tenantId,
        tenantSlug,
        roomId: hostIdentity.roomId,
        conversationId: hostIdentity.conversationId,
        accountType: "guest"
      });

      const guestMessage = `Guest live message ${shortSuffix()}`;
      await sendMessage(guestPage, guestMessage);
      await expect(
        hostPage.getByText(guestMessage, { exact: true })
      ).toBeVisible({ timeout: 30_000 });

      const hostMessage = `Host live reply ${shortSuffix()}`;
      await sendMessage(hostPage, hostMessage);
      await expect(
        guestPage.getByText(hostMessage, { exact: true })
      ).toBeVisible({ timeout: 30_000 });

      expect(await storedGuestRoomIdentity(hostPage)).toEqual(hostIdentity);
      expect(await storedGuestRoomIdentity(guestPage)).toEqual(guestIdentity);
      await expect.poll(() => createRequestCount).toBe(1);
      expect(createRequestUsedUnexpectedOrigin).toBe(false);
      expect(publicRequestUsedForwardedFor).toBe(false);

      await leaveAndAwaitRevocation(guestPage, publicOrigin);
      await leaveAndAwaitRevocation(hostPage, publicOrigin);
    } finally {
      const contexts = [
        qualificationContext,
        hostContext,
        guestContext
      ].filter((context): context is BrowserContext => context !== null);
      await Promise.allSettled(contexts.map((context) => context.close()));
    }
  });
});

function roomContext(
  browser: Browser,
  baseURL: string
): Promise<BrowserContext> {
  return browser.newContext({ baseURL });
}

function qualificationRoomContext(
  browser: Browser,
  baseURL: string,
  clientAddress: string
): Promise<BrowserContext> {
  return browser.newContext({
    baseURL,
    extraHTTPHeaders: { "X-Forwarded-For": clientAddress }
  });
}

async function installGuestSessionHandoff(
  context: BrowserContext,
  publicOrigin: string,
  serializedSession: string
) {
  try {
    await context.addInitScript(
      ({ expectedOrigin, storageKey, sessionValue }) => {
        if (
          window.location.origin === expectedOrigin &&
          !window.sessionStorage.getItem(storageKey)
        ) {
          window.sessionStorage.setItem(storageKey, sessionValue);
        }
      },
      {
        expectedOrigin: publicOrigin,
        storageKey: guestSessionStorageKey,
        sessionValue: serializedSession
      }
    );
  } catch {
    throw new Error("the in-memory guest session handoff failed");
  }
}

async function navigateToSecureRoom(page: Page, shareURL: string) {
  try {
    await page.goto(shareURL);
  } catch {
    throw new Error("instant-room navigation failed; bearer URL redacted");
  }
}

async function sendMessage(page: Page, body: string) {
  const composer = page.getByRole("textbox", { name: "Message" });
  await composer.fill(body);
  await composer.press("Enter");
  await expect(page.getByText(body, { exact: true })).toBeVisible({
    timeout: 30_000
  });
}

async function leaveAndAwaitRevocation(page: Page, publicOrigin: string) {
  const [response] = await Promise.all([
    page.waitForResponse((candidate) => {
      const request = candidate.request();
      const url = new URL(candidate.url());
      return (
        request.method() === "DELETE" &&
        url.origin === publicOrigin &&
        url.pathname === "/api/v1/guest/sessions/current" &&
        url.search === ""
      );
    }, { timeout: 30_000 }),
    page.getByRole("button", { name: "Leave" }).click()
  ]);
  expect(response.status()).toBe(204);
}

async function storedGuestRoomIdentity(
  page: Page
): Promise<StoredRoomIdentity> {
  return page.evaluate(() => {
    const serialized = sessionStorage.getItem("k-comms.guest-session.v1");
    if (!serialized) {
      throw new Error("the guest room session is missing");
    }
    const session = JSON.parse(serialized) as {
      tenant?: { id?: string; slug?: string };
      user?: {
        id?: string;
        tenant_id?: string;
        account_type?: string | null;
      };
      conversation?: { id?: string; tenant_id?: string };
      instant_room?: { id?: string };
    };
    if (
      !session.tenant?.id ||
      !session.tenant.slug ||
      !session.user?.id ||
      session.user.tenant_id !== session.tenant.id ||
      !session.conversation?.id ||
      session.conversation.tenant_id !== session.tenant.id ||
      !session.instant_room?.id
    ) {
      throw new Error("the stored guest room identity is incomplete");
    }
    return {
      userId: session.user.id,
      accountType: session.user.account_type || null,
      tenantId: session.tenant.id,
      tenantSlug: session.tenant.slug,
      roomId: session.instant_room.id,
      conversationId: session.conversation.id
    };
  });
}

async function captureGuestSessionForHandoff(page: Page): Promise<string> {
  return page.evaluate(() => {
    const serialized = sessionStorage.getItem("k-comms.guest-session.v1");
    if (!serialized) {
      throw new Error("the guest room session is missing");
    }
    const session = JSON.parse(serialized) as {
      access_token?: unknown;
      refresh_token?: unknown;
      instant_room?: { id?: unknown };
    };
    if (
      typeof session.access_token !== "string" ||
      typeof session.refresh_token !== "string" ||
      typeof session.instant_room?.id !== "string"
    ) {
      throw new Error("the guest room session cannot be handed off");
    }
    return serialized;
  });
}

async function redactShareField(page: Page) {
  await page
    .getByRole("textbox", { name: /(?:Secure room|Room invite) link/ })
    .evaluate((element) => {
      const input = element as HTMLInputElement;
      input.value = "[redacted secure room link]";
      input.setAttribute("value", "[redacted secure room link]");
    });
}

function assertInstantRoomShareURL(value: string, publicOrigin: string) {
  try {
    const url = new URL(value);
    const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
    const keys = [...fragment.keys()];
    const token = fragment.get("guest") || "";
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
      url.origin !== publicOrigin ||
      url.pathname !== "/join" ||
      url.search !== "" ||
      keys.length !== 1 ||
      keys[0] !== "guest" ||
      !/^[A-Za-z0-9_-]{43}$/.test(token)
    ) {
      throw new Error();
    }
  } catch {
    throw new Error(
      "the server returned an invalid instant-room bearer URL shape"
    );
  }
}

function sealedInstantRoomEnvironment() {
  const qualificationAppOrigin = exactOriginEnvironment(
    "K_COMMS_LIVE_INSTANT_ROOM_QUALIFICATION_APP_ORIGIN",
    true
  );
  const publicOrigin = exactOriginEnvironment(
    "K_COMMS_LIVE_INSTANT_ROOM_PUBLIC_ORIGIN",
    false
  );
  const tenantSlug = process.env.K_COMMS_LIVE_INSTANT_ROOM_TENANT_SLUG;
  const clientAddress =
    process.env.K_COMMS_LIVE_INSTANT_ROOM_CLIENT_ADDRESS;
  if (
    !tenantSlug ||
    !/^k-comms-qualification-[0-9a-f]{32}$/.test(tenantSlug)
  ) {
    throw new Error(
      "instant-room qualification requires a disposable marker-bound tenant"
    );
  }
  if (
    !clientAddress ||
    !/^2001:db8:[0-9a-f]{1,4}:[0-9a-f]{1,4}::1$/.test(clientAddress)
  ) {
    throw new Error(
      "instant-room qualification requires an isolated documentation client address"
    );
  }
  if (qualificationAppOrigin === publicOrigin) {
    throw new Error(
      "the temporary qualification app must be isolated from the public origin"
    );
  }
  return {
    clientAddress,
    qualificationAppOrigin,
    publicOrigin,
    tenantSlug
  };
}

function exactOriginEnvironment(name: string, loopbackOnly: boolean) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`the local-release qualifier did not supply ${name}`);
  }
  try {
    const url = new URL(value);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
      url.pathname !== "/" ||
      url.search ||
      url.hash ||
      value !== url.origin ||
      (loopbackOnly && (url.hostname !== "127.0.0.1" || !url.port))
    ) {
      throw new Error();
    }
    return url.origin;
  } catch {
    throw new Error(
      loopbackOnly
        ? `${name} must be an exact, explicit-port 127.0.0.1 origin`
        : `${name} must be an exact HTTP(S) origin`
    );
  }
}

function qrValueFingerprint(value: string) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function shortSuffix() {
  return randomUUID().replaceAll("-", "").slice(0, 16);
}
