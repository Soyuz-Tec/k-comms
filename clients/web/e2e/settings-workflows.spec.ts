import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";

test("device settings require explicit capture and release late permission responses on navigation", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.addInitScript(() => {
    const mediaTest = { requests: 0, stopped: 0, complete: () => {} };
    Object.assign(window, { mediaTest });
    const getUserMedia = () => {
      mediaTest.requests += 1;
      return new Promise<MediaStream>((resolve) => {
        mediaTest.complete = () => {
          const stream = new MediaStream();
          Object.defineProperty(stream, "getTracks", { value: () => [{ stop: () => { mediaTest.stopped += 1; } }] });
          resolve(stream);
        };
      });
    };
    // WebKit may expose a fresh native MediaDevices object on each access.
    // Install one synthetic facade so the test never opens actual capture.
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia, enumerateDevices: () => Promise.resolve([]) }
    });
  });
  await page.goto("/app/you?section=audio-video");
  await expect(page.getByRole("heading", { name: "Audio & video", exact: true })).toBeVisible();
  await expect(page.getByText("Microphone is not capturing.", { exact: true })).toBeVisible();
  await expect(page.getByText("Camera preview is off.", { exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { mediaTest: { requests: number } }).mediaTest.requests)).toBe(0);
  await page.getByRole("button", { name: "Test microphone", exact: true }).click();
  expect(await page.evaluate(() => (window as unknown as { mediaTest: { requests: number } }).mediaTest.requests)).toBe(1);
  await expect(page.getByRole("button", { name: "Stop microphone test", exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "Profile", exact: true }).click();
  await expect(page).toHaveURL(/section=profile/);
  await expect(page.getByRole("heading", { name: "Profile", exact: true })).toBeVisible();
  await page.evaluate(() => (window as unknown as { mediaTest: { complete: () => void } }).mediaTest.complete());
  await expect.poll(() => page.evaluate(() => (window as unknown as { mediaTest: { stopped: number } }).mediaTest.stopped)).toBe(1);
  await page.goBack();
  await expect(page.getByRole("heading", { name: "Audio & video", exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { mediaTest: { requests: number } }).mediaTest.requests)).toBe(1);
  await expectNoDocumentOverflow(page);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  expect(state.unexpectedRequests).toEqual([]);
});

test("default desktop navigation reserves space and account settings opens the selected section", async ({ page, isMobile }) => {
  test.skip(isMobile, "Default pinned navigation is a desktop preference.");
  await installWorkspace(page);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto("/app/you?section=profile");
  const navigation = page.getByRole("navigation", { name: "Member areas" });
  await expect(navigation.getByRole("link", { name: "Inbox", exact: true })).toBeVisible();
  await expect(navigation.getByRole("link", { name: "Files", exact: true })).toBeVisible();
  const rail = await page.locator(".workspace-sidebar").boundingBox();
  const content = await page.locator("#main-content").boundingBox();
  expect(rail).not.toBeNull();
  expect(content).not.toBeNull();
  expect(content!.x).toBeGreaterThanOrEqual(rail!.x + rail!.width - 1);
  await page.getByRole("tab", { name: "Security", exact: true }).click();
  await expect(page).toHaveURL(/section=security/);
  await expect(page.getByRole("heading", { name: "Sessions", exact: true })).toBeVisible();
  await page.goBack();
  await expect(page.getByRole("heading", { name: "Profile", exact: true })).toBeVisible();
  await expectNoDocumentOverflow(page);
});
