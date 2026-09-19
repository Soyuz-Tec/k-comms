import AxeBuilder from "@axe-core/playwright";
import type { Page, TestInfo } from "@playwright/test";
import type { Session } from "../src/types";
import { expect, test } from "./fixtures";
import {
  conversationId,
  expectNoDocumentOverflow,
  installWorkspace
} from "./mobile-ui-support";

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Explicit desktop and phone viewports run once per engine");
  await page.setViewportSize({ width: 1440, height: 900 });
});

async function revealNavigation(page: Page) {
  const reveal = page.getByRole("button", { name: "Show workspace navigation" });
  if (await reveal.isVisible()) await reveal.click();
  await expect(page.getByRole("button", { name: "Switch conversation or screen" })).toBeVisible();
}

async function capture(page: Page, info: TestInfo, name: string) {
  if (process.env.K_COMMS_VISUAL_CAPTURE !== "1") return;
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: info.outputPath(`${name}.png`), animations: "disabled" });
}

test("workspace switcher remains reachable after navigation hides and restores button focus", async ({ page }, info) => {
  const state = await installWorkspace(page);
  await page.clock.install();
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  await page.mouse.move(700, 250);
  await page.clock.fastForward(8_300);
  await expect(page.locator("#workspace-navigation")).toBeHidden();
  await revealNavigation(page);
  const trigger = page.getByRole("button", { name: "Switch conversation or screen" });
  await trigger.click();
  await page.clock.runFor(30);

  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  const search = dialog.getByRole("combobox", { name: "Find a conversation or screen" });
  await expect(dialog).toBeVisible();
  await expect(search).toBeFocused();
  await expect(dialog.getByRole("option", { name: /Workspace administration/ })).toBeVisible();
  await expect(dialog.getByRole("option", { name: /Service operations/ })).toBeVisible();
  await capture(page, info, "workspace-switcher");
  const accessibility = await new AxeBuilder({ page }).include(".workspace-switcher").analyze();
  expect(accessibility.violations).toEqual([]);

  await search.fill("no-such-destination-987654");
  await expect(dialog.getByRole("option")).toHaveCount(0);
  await expect(dialog.getByRole("status")).toContainText("No matching destination");
  await search.press("Enter");
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await page.clock.runFor(30);
  await expect(dialog).toHaveCount(0);
  await expect(trigger).toBeFocused();
  expect(state.unexpectedRequests).toEqual([]);
});

test("Ctrl K filters an existing conversation and opens it without a search API", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await page.getByRole("heading", { name: "Inbox", exact: true }).click();
  await page.keyboard.press("Control+k");
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  const search = dialog.getByRole("combobox", { name: "Find a conversation or screen" });
  await expect(search).toBeFocused();
  await search.fill("gEnErAl");
  await expect(dialog.getByRole("option")).toHaveCount(1);
  await expect(dialog.getByRole("option", { name: /General Channel/ })).toHaveAttribute("aria-selected", "true");
  await search.press("Enter");
  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL(`/app/?conversation=${conversationId}`);
  await expect(page.getByText("Mobile-ready message body", { exact: true })).toBeVisible();
  expect(state.unexpectedRequests).toEqual([]);
});

test("workspace switcher opens a screen with pointer selection", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  await revealNavigation(page);
  await page.getByRole("button", { name: "Switch conversation or screen" }).click();
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  await dialog.getByRole("combobox", { name: "Find a conversation or screen" }).fill("Calls");
  await dialog.getByRole("option", { name: "Calls Workspace", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL("/app/calls");
  await expect(page.getByRole("heading", { name: "Calls", exact: true })).toBeVisible();
  await expectNoDocumentOverflow(page);
  expect(state.unexpectedRequests).toEqual([]);
});

test("browser history dismisses the switcher instead of leaving a modal over the previous screen", async ({ page }) => {
  await installWorkspace(page);
  await page.goto(`/app/?conversation=${conversationId}`);
  await page.getByRole("link", { name: "Calls", exact: true }).click();
  await expect(page).toHaveURL("/app/calls");
  await revealNavigation(page);
  await page.getByRole("button", { name: "Switch conversation or screen" }).click();
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toBeVisible();
  await page.goBack();
  // Desktop selects the first conversation in the URL; assert the actual
  // prior location instead of assuming the inbox keeps an empty query.
  await expect(page).toHaveURL(`/app/?conversation=${conversationId}`);
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
});

test("password controls remain aligned when field text grows", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/sign-in");
  const password = page.getByLabel("Password", { exact: true });
  const toggle = page.getByRole("button", { name: "Show password", exact: true });
  await expect(password).toBeVisible();
  // The status response enables the form and removes its transport warning.
  // Measure the usable form after that reflow and the self-hosted font swap.
  await expect(password).toBeEnabled();
  await page.evaluate(() => document.fonts.ready);
  for (const enlarged of [false, true]) {
    if (enlarged) await page.addStyleTag({ content: "html { font-size: 20px !important; } .field label { line-height: 1.5 !important; letter-spacing: .12em !important; word-spacing: .16em !important; }" });
    // Both rectangles must describe the same layout; separate browser calls
    // can straddle a reflow and report a false alignment difference.
    const { inputBox, toggleBox } = await password.evaluate((input) => {
      const button = input.parentElement?.querySelector("button");
      if (!button) throw new Error("Password visibility control is missing");
      const inputRect = input.getBoundingClientRect();
      const toggleRect = button.getBoundingClientRect();
      return {
        inputBox: { y: inputRect.y, height: inputRect.height },
        toggleBox: { y: toggleRect.y, height: toggleRect.height }
      };
    });
    expect(Math.abs(inputBox.y - toggleBox.y)).toBeLessThanOrEqual(1);
    expect(Math.abs(inputBox.height - toggleBox.height)).toBeLessThanOrEqual(1);
    expect(toggleBox.height).toBeGreaterThanOrEqual(44);
    await expectNoDocumentOverflow(page);
  }
  await password.fill("synthetic-password-only");
  await toggle.click();
  await expect(password).toHaveAttribute("type", "text");
  await page.getByRole("button", { name: "Hide password", exact: true }).click();
  await expect(password).toHaveAttribute("type", "password");
  await capture(page, info, "password-control-large-text");
});

test("Ctrl K preserves text inputs and an existing modal", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  const inboxSearch = page.getByPlaceholder("Search inbox", { exact: true });
  await inboxSearch.fill("General");
  await inboxSearch.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(inboxSearch).toBeFocused();
  await expect(inboxSearch).toHaveValue("General");

  await revealNavigation(page);
  await page.getByRole("button", { name: /^Notifications/ }).click();
  const notifications = page.getByRole("dialog", { name: "Notifications", exact: true });
  await expect(notifications).toBeVisible();
  const close = notifications.getByRole("button", { name: /Close/ }).first();
  await close.focus();
  await close.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(notifications).toBeVisible();
  await expect(close).toBeFocused();
  expect(state.unexpectedRequests).toEqual([]);
});

test("a member's switcher omits privileged tools after the authorized session refreshes", async ({ page }) => {
  const state = await installWorkspace(page);
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  const session = await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!) as Session);
  const member = { ...session.user, role: "member", platform_role: null, platform_role_expires_at: null };
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: {
    tenant: session.tenant, user: member, device: session.device,
    capabilities: { allow_audio_calls: true, allow_video_calls: true, allow_public_channels: true, message_edit_window_seconds: 900, max_attachment_bytes: 25_000_000 }
  } }));
  await page.reload();
  await expect.poll(() => page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1")!).user.role)).toBe("member");
  await page.getByRole("heading", { name: "Inbox", exact: true }).click();
  await page.keyboard.press("Control+k");
  const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("option", { name: /General Channel/ })).toBeVisible();
  await expect(dialog.getByRole("option", { name: /Workspace administration|Service operations/ })).toHaveCount(0);
  expect(state.unexpectedRequests).toEqual([]);
});

for (const width of [320, 390]) {
  test(`${width}px administration exposes working content without a tall introduction`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 844 });
    const state = await installWorkspace(page, { tenantName: "InternationalWorkspace".repeat(8) });
    await page.goto("/admin?section=people");
    const people = page.getByRole("region", { name: "People, roles and sessions", exact: true });
    await expect(people).toBeVisible();
    const content = await people.boundingBox();
    expect(content).not.toBeNull();
    expect(content!.y, "The first administration task must begin within 320px of the viewport top").toBeLessThanOrEqual(320);
    await expectNoDocumentOverflow(page);
    await capture(page, info, `administration-content-${width}`);
    expect(state.unexpectedRequests).toEqual([]);
  });
}
