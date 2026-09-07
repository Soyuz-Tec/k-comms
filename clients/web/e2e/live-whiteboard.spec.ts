import type {
  APIRequestContext,
  Browser,
  BrowserContext,
  TestInfo
} from "@playwright/test";
import { expect, test } from "@playwright/test";

const liveEnabled = process.env.K_COMMS_LIVE_WHITEBOARD_E2E === "true";

test.describe("live collaborative whiteboard", () => {
  test.skip(!liveEnabled, "requires an isolated disposable qualification tenant");

  test("two devices receive presence, durable operations, replay, and clear", async ({
    browser,
    request
  }, testInfo) => {
    test.setTimeout(120_000);
    test.skip(testInfo.project.name !== "chromium", "one desktop live qualification owns this journey");
    const credentials = liveCredentials();
    const firstSession = await signIn(request, credentials, "Whiteboard device one");
    const secondSession = await signIn(request, credentials, "Whiteboard device two");
    const conversationsResponse = await request.get("/api/v1/conversations", {
      headers: authorization(firstSession)
    });
    expect(conversationsResponse.status()).toBe(200);
    const conversations = (await conversationsResponse.json()) as {
      data: Array<{ id: string; title: string | null }>;
    };
    expect(conversations.data.length).toBeGreaterThan(0);
    const conversation = conversations.data[0];

    let firstContext: BrowserContext | null = null;
    let secondContext: BrowserContext | null = null;
    try {
      firstContext = await memberContext(browser, firstSession, testInfo);
      secondContext = await memberContext(browser, secondSession, testInfo);
      const firstPage = await firstContext.newPage();
      const secondPage = await secondContext.newPage();
      const route = `/app/whiteboard?conversation=${encodeURIComponent(conversation.id)}`;
      await Promise.all([firstPage.goto(route), secondPage.goto(route)]);

      await Promise.all([
        expect(firstPage.getByText("Live canvas", { exact: true })).toBeVisible({
          timeout: 30_000
        }),
        expect(secondPage.getByText("Live canvas", { exact: true })).toBeVisible({
          timeout: 30_000
        })
      ]);
      await expect(firstPage.getByRole("heading", { name: "Canvas contents, 0 objects" })).toHaveCount(1);
      await expect(secondPage.getByRole("heading", { name: "Canvas contents, 0 objects" })).toHaveCount(1);

      const firstCanvas = firstPage.locator("canvas.excalidraw__canvas.interactive");
      const bounds = await firstCanvas.boundingBox();
      if (!bounds) throw new Error("live whiteboard canvas has no render bounds");
      await firstPage.mouse.move(bounds.x + 700, bounds.y + 180);
      await expect(secondPage.getByText("2 active", { exact: true })).toBeVisible();

      const revealTools = firstPage.getByRole("button", { name: "Show drawing tools" });
      if (await revealTools.isVisible()) await revealTools.click();
      await firstPage.getByTitle("Rectangle — R or 2").click();
      await firstPage.mouse.move(bounds.x + 420, bounds.y + 210);
      await firstPage.mouse.down();
      await firstPage.mouse.move(bounds.x + 620, bounds.y + 350, { steps: 6 });
      await firstPage.mouse.up();

      await expect(firstPage.getByRole("heading", { name: "Canvas contents, 1 object" })).toHaveCount(1);
      await expect(secondPage.getByRole("heading", { name: "Canvas contents, 1 object" })).toHaveCount(1);
      await expect(firstPage.getByText("Synced", { exact: true })).toBeVisible();
      await expect.poll(
        () => operationCount(request, conversation.id, secondSession),
        { timeout: 10_000 }
      ).toBe(1);

      await secondPage.reload();
      await expect(secondPage.getByText("Live canvas", { exact: true })).toBeVisible({
        timeout: 30_000
      });
      await expect(secondPage.getByRole("heading", { name: "Canvas contents, 1 object" })).toHaveCount(1);

      await firstPage.getByRole("button", { name: "Open canvas controls" }).click();
      await firstPage.getByRole("button", { name: "Clear canvas" }).click();
      await firstPage
        .getByRole("alertdialog", { name: "Clear this canvas?" })
        .getByRole("button", { name: "Clear canvas" })
        .click();
      await expect(firstPage.getByRole("heading", { name: "Canvas contents, 0 objects" })).toHaveCount(1);
      await expect(secondPage.getByRole("heading", { name: "Canvas contents, 0 objects" })).toHaveCount(1);
      await expect.poll(
        () => operationCount(request, conversation.id, firstSession),
        { timeout: 10_000 }
      ).toBe(1);
    } finally {
      await Promise.allSettled([
        firstContext?.close() ?? Promise.resolve(),
        secondContext?.close() ?? Promise.resolve()
      ]);
    }
  });
});

type Credentials = { tenantSlug: string; email: string; password: string };
type Session = {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
  received_at: number;
  tenant: { id: string; slug: string };
  user: { id: string };
  device: { id: string };
};

function liveCredentials(): Credentials {
  const tenantSlug = process.env.K_COMMS_LIVE_OWNER_TENANT_SLUG;
  const email = process.env.K_COMMS_LIVE_OWNER_EMAIL;
  const password = process.env.K_COMMS_LIVE_OWNER_PASSWORD;
  if (!tenantSlug || !email || !password) {
    throw new Error("live whiteboard qualification credentials are incomplete");
  }
  return { tenantSlug, email, password };
}

async function signIn(
  request: APIRequestContext,
  credentials: Credentials,
  deviceName: string
): Promise<Session> {
  const response = await request.post("/api/v1/sessions", {
    data: {
      tenant_slug: credentials.tenantSlug,
      email: credentials.email,
      password: credentials.password,
      device: { name: deviceName, platform: "playwright" }
    }
  });
  expect(response.status()).toBe(200);
  return { ...(await response.json()), received_at: Date.now() } as Session;
}

async function memberContext(
  browser: Browser,
  session: Session,
  testInfo: TestInfo
): Promise<BrowserContext> {
  const context = await browser.newContext({
    baseURL: String(testInfo.project.use.baseURL)
  });
  await context.addInitScript((value) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value));
    localStorage.setItem(
      `k-comms:onboarding:${value.tenant.id}:${value.user.id}`,
      "dismissed"
    );
  }, session);
  return context;
}

function authorization(session: Session) {
  return { authorization: `Bearer ${session.access_token}` };
}

async function operationCount(
  request: APIRequestContext,
  conversationId: string,
  session: Session
): Promise<number> {
  const response = await request.get(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/whiteboard/operations`,
    { headers: authorization(session) }
  );
  if (response.status() !== 200) return -1;
  const body = (await response.json()) as { data: unknown[] };
  return body.data.length;
}
