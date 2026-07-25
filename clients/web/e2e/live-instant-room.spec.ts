import { expect, test } from "@playwright/test";
import type { Browser, BrowserContext, Page } from "@playwright/test";
import { createHash, randomUUID } from "node:crypto";

// The room URL contains a bearer credential. Keep Playwright's optional AI
// failure context, traces, screenshots, and video from retaining that value.
process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";

const enabled =
  process.env.K_COMMS_LIVE_INSTANT_ROOM_E2E === "true" &&
  process.env.K_COMMS_EXTERNAL_E2E_SERVER === "true";
const liveStackURL =
  process.env.K_COMMS_LIVE_INSTANT_ROOM_BASE_URL ||
  process.env.K_COMMS_E2E_BASE_URL ||
  "http://127.0.0.1:4188";

interface StoredRoomIdentity {
  userId: string;
  accountType: string | null;
  roomId: string;
  conversationId: string;
}

interface StoredMemberContinuity {
  account: {
    userId: string;
    accountType: string | null;
  } | null;
  guestSessionPresent: boolean;
  continuity: {
    roomId: string;
    conversationId: string;
  } | null;
}

test.use({ trace: "off", screenshot: "off", video: "off" });

test.describe("real-stack instant-room acceptance", () => {
  test.describe.configure({ mode: "serial" });
  test.skip(
    !enabled,
    "set K_COMMS_LIVE_INSTANT_ROOM_E2E=true and K_COMMS_EXTERNAL_E2E_SERVER=true to run against an instant-room-enabled K-Comms release"
  );
  test.setTimeout(120_000);

  test("auto-creates, shares, joins, communicates, converts, and restores one room", async ({
    browser
  }, testInfo) => {
    test.skip(
      testInfo.project.name !== "chromium",
      "the bearer-safe real-stack journey runs once in Chromium"
    );
    const hostContext = await roomContext(browser);
    const guestContext = await roomContext(browser);
    let createRequestCount = 0;

    try {
      const hostPage = await hostContext.newPage();
      const guestPage = await guestContext.newPage();
      hostPage.on("request", (request) => {
        if (
          request.method() === "POST" &&
          new URL(request.url()).pathname === "/api/v1/instant-rooms"
        ) {
          createRequestCount += 1;
        }
      });

      await hostPage.goto(new URL("/", liveStackURL).toString());
      await expect(
        hostPage.getByRole("heading", { name: "Instant room" })
      ).toBeVisible({ timeout: 30_000 });
      await expect(hostPage.locator(".guest-connection.live")).toHaveText(
        "live",
        { timeout: 30_000 }
      );
      await expect.poll(() => createRequestCount).toBe(1);

      const hostBeforeConversion = await storedGuestRoomIdentity(hostPage);
      const shareField = hostPage.getByRole("textbox", {
        name: "Secure room link"
      });
      const shareURL = await shareField.inputValue();
      assertInstantRoomShareURL(shareURL);

      const shareFingerprint = qrValueFingerprint(shareURL);
      const qr = hostPage.locator(".guest-qr");
      await expect(qr).toHaveAttribute(
        "data-qr-fingerprint",
        shareFingerprint,
        { timeout: 20_000 }
      );
      await expect(
        qr.getByRole("img", { name: "Scan to join Instant room" })
      ).toBeVisible();

      await navigateToSecureRoom(guestPage, shareURL);
      await expect
        .poll(() =>
          guestPage.evaluate(() => ({
            pathname: window.location.pathname,
            hash: window.location.hash,
            tokenInQuery: new URL(window.location.href).searchParams.has(
              "token"
            )
          }))
        )
        .toEqual({
          pathname: "/join",
          hash: "",
          tokenInQuery: false
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
        expect(hostRoster.getByText("Guest host", { exact: false }))
          .toContainText("Guest host (you)", { timeout: 30_000 }),
        expect(guestRoster.getByText("Guest host")).toBeVisible({
          timeout: 30_000
        })
      ]);

      const guestIdentity = await storedGuestRoomIdentity(guestPage);
      expect(guestIdentity).toMatchObject({
        roomId: hostBeforeConversion.roomId,
        conversationId: hostBeforeConversion.conversationId,
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

      const conversionEmail = `instant-owner-${shortSuffix()}@example.test`;
      await hostPage
        .getByRole("button", { name: "Create account" })
        .click();
      const accountCard = hostPage.locator("#guest-account-conversion");
      await expect(
        accountCard.getByRole("heading", { name: "Keep your conversation" })
      ).toBeVisible();
      await accountCard
        .getByRole("textbox", { name: "Work email" })
        .fill(conversionEmail);
      await accountCard
        .getByRole("textbox", { name: /Display name/ })
        .fill("Registered Room Owner");
      await accountCard
        .getByLabel("Password")
        .fill(strongPassword());
      await accountCard
        .getByRole("button", { name: "Create account" })
        .click();

      await expect(
        hostPage.locator(".guest-room-heading .guest-badge")
      ).toHaveText("Member", { timeout: 30_000 });
      await expect(
        hostPage.getByText(
          "When everyone leaves, this room remains available for 24 hours."
        )
      ).toBeVisible({ timeout: 30_000 });
      await expect(hostPage.locator(".guest-connection.live")).toHaveText(
        "live",
        { timeout: 30_000 }
      );
      await expect(hostPage.getByText(/2 people online/i)).toBeVisible({
        timeout: 30_000
      });
      await expect(
        hostPage.getByText(guestMessage, { exact: true })
      ).toBeVisible();
      await expect(
        guestPage.getByText(hostMessage, { exact: true })
      ).toBeVisible();

      const converted = await storedMemberContinuity(hostPage);
      expect(converted).toEqual({
        account: {
          userId: hostBeforeConversion.userId,
          accountType: "human"
        },
        guestSessionPresent: false,
        continuity: {
          roomId: hostBeforeConversion.roomId,
          conversationId: hostBeforeConversion.conversationId
        }
      });

      await redactShareField(hostPage);
      await hostPage.reload();

      await expect(
        hostPage.getByRole("heading", { name: "Instant room" })
      ).toBeVisible({ timeout: 30_000 });
      await expect(hostPage.locator(".guest-connection.live")).toHaveText(
        "live",
        { timeout: 30_000 }
      );
      await expect(hostPage.getByText(/2 people online/i)).toBeVisible({
        timeout: 30_000
      });
      await expect(
        hostPage.getByText(guestMessage, { exact: true })
      ).toBeVisible({ timeout: 30_000 });
      await expect.poll(() => createRequestCount).toBe(1);

      const afterReload = await storedMemberContinuity(hostPage);
      expect(afterReload).toEqual(converted);

      const messageAfterReload = `After refresh ${shortSuffix()}`;
      await sendMessage(guestPage, messageAfterReload);
      await expect(
        hostPage.getByText(messageAfterReload, { exact: true })
      ).toBeVisible({ timeout: 30_000 });

      await guestPage.getByRole("button", { name: "Leave" }).click();
      await hostPage.getByRole("button", { name: "Leave" }).click();
    } finally {
      await Promise.allSettled([hostContext.close(), guestContext.close()]);
    }
  });
});

function roomContext(browser: Browser): Promise<BrowserContext> {
  return browser.newContext({ baseURL: liveStackURL });
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

async function storedGuestRoomIdentity(
  page: Page
): Promise<StoredRoomIdentity> {
  return page.evaluate(() => {
    const serialized = sessionStorage.getItem("k-comms.guest-session.v1");
    if (!serialized) {
      throw new Error("the guest room session is missing");
    }
    const session = JSON.parse(serialized) as {
      user?: { id?: string; account_type?: string | null };
      conversation?: { id?: string };
      instant_room?: { id?: string };
    };
    if (
      !session.user?.id ||
      !session.conversation?.id ||
      !session.instant_room?.id
    ) {
      throw new Error("the stored guest room identity is incomplete");
    }
    return {
      userId: session.user.id,
      accountType: session.user.account_type || null,
      roomId: session.instant_room.id,
      conversationId: session.conversation.id
    };
  });
}

async function storedMemberContinuity(
  page: Page
): Promise<StoredMemberContinuity> {
  return page.evaluate(() => {
    const accountValue = sessionStorage.getItem("k-comms.session.v1");
    const guestSessionPresent =
      sessionStorage.getItem("k-comms.guest-session.v1") !== null;
    const continuityValue = sessionStorage.getItem(
      "k-comms.member-instant-room.v1"
    );
    const account = accountValue
      ? (JSON.parse(accountValue) as {
          user?: { id?: string; account_type?: string | null };
        })
      : null;
    const continuity = continuityValue
      ? (JSON.parse(continuityValue) as {
          room?: { id?: string };
          conversation?: { id?: string };
        })
      : null;

    return {
      account: account?.user?.id
        ? {
            userId: account.user.id,
            accountType: account.user.account_type || null
          }
        : null,
      guestSessionPresent,
      continuity:
        continuity?.room?.id && continuity.conversation?.id
          ? {
              roomId: continuity.room.id,
              conversationId: continuity.conversation.id
            }
          : null
    };
  });
}

async function redactShareField(page: Page) {
  await page
    .getByRole("textbox", { name: "Secure room link" })
    .evaluate((element) => {
      const input = element as HTMLInputElement;
      input.value = "[redacted secure room link]";
      input.setAttribute("value", "[redacted secure room link]");
    });
}

function assertInstantRoomShareURL(value: string) {
  try {
    const url = new URL(value);
    const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
    const keys = [...fragment.keys()];
    const token = fragment.get("guest") || "";
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
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

function qrValueFingerprint(value: string) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function shortSuffix() {
  return randomUUID().replaceAll("-", "").slice(0, 16);
}

function strongPassword() {
  return `Kc!${randomUUID()}Aa9`;
}
