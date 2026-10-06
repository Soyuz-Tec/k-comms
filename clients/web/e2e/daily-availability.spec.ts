import AxeBuilder from "@axe-core/playwright";
import type { Page, TestInfo } from "@playwright/test";
import type { Availability, UpdateAvailability } from "../src/types/enterpriseIdentity";
import { expect, test } from "./fixtures";
import { expectMinimumTargets, expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Explicit desktop and mobile widths run once per engine.");
  await page.setViewportSize({ width: 1440, height: 900 });
});

async function workspace(page: Page) {
  const workspaceState = await installWorkspace(page);
  const state = {
    failNextSave: false,
    writes: [] as UpdateAvailability[],
    availability: { status: "available", presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: { days: [1], start: "22:00", end: "08:00" }, dnd_active: false, retry_at: null, timezone: "Etc/UTC" } as Availability
  };
  await page.route("**/api/v1/me/availability", async (route) => {
    if (route.request().method() === "PUT") {
      const input = route.request().postDataJSON() as UpdateAvailability;
      state.writes.push(input);
      if (state.failNextSave) {
        state.failNextSave = false;
        return route.fulfill({ status: 503, json: { error: { code: "unavailable", detail: "Availability could not be saved. Try again." } } });
      }
      state.availability = { ...state.availability, ...input, status: input.presence_state, dnd_active: input.presence_state === "dnd", retry_at: input.presence_state === "dnd" ? input.presence_expires_at : null };
    }
    return route.fulfill({ json: { data: state.availability } });
  });
  return { ...workspaceState, state };
}

async function capture(page: Page, info: TestInfo, name: string) {
  if (process.env.K_COMMS_VISUAL_CAPTURE !== "1") return;
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: info.outputPath(`${name}.png`), animations: "disabled" });
}

test("desktop account menu supports timed DND, keyboard dismissal and explicit clearing", async ({ page }, info) => {
  const { state, unexpectedRequests } = await workspace(page);
  await page.goto("/app/content");
  const trigger = page.getByRole("button", { name: /^Account menu for / });
  await trigger.focus();
  await trigger.press("Enter");
  const control = page.getByRole("region", { name: "Your availability", exact: true });
  await expect(control.getByRole("combobox", { name: "Set status" })).toHaveValue("available");
  await control.getByRole("combobox", { name: "Status duration" }).selectOption("30");
  const started = Date.now();
  const pause = control.getByRole("button", { name: "Pause notifications", exact: true });
  await pause.focus();
  await pause.press("Enter");
  await expect(control.getByRole("status")).toHaveText("Do not disturb saved.");
  expect(state.writes).toHaveLength(1);
  expect(state.writes[0]).toMatchObject({ presence_state: "dnd", dnd_schedule: { days: [1], start: "22:00", end: "08:00" } });
  expect(Date.parse(state.writes[0]!.presence_expires_at!) - started).toBeGreaterThanOrEqual(30 * 60_000);
  expect(Date.parse(state.writes[0]!.presence_expires_at!) - started).toBeLessThan(31 * 60_000);
  await expect(control.locator("time")).toBeVisible();
  await expectMinimumTargets(control.getByRole("button").or(control.getByRole("combobox")).or(control.getByRole("link")), "Quick availability controls");
  await expectNoDocumentOverflow(page);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await capture(page, info, "desktop-availability-dnd");
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();
  await expect(control).toBeHidden();
  await trigger.press("Enter");
  await control.getByRole("button", { name: "Clear manual status", exact: true }).click();
  await expect(control.getByRole("combobox", { name: "Set status" })).toHaveValue("available");
  expect(state.writes[1]).toEqual({ presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: { days: [1], start: "22:00", end: "08:00" } });
  expect(unexpectedRequests).toEqual([]);
});

test("failed quick status save preserves effective availability and supports retry", async ({ page }) => {
  const { state, unexpectedRequests } = await workspace(page);
  state.failNextSave = true;
  await page.goto("/app/content");
  await page.getByRole("button", { name: /^Account menu for / }).click();
  const control = page.getByRole("region", { name: "Your availability", exact: true });
  await control.getByRole("button", { name: "Pause notifications", exact: true }).click();
  await expect(control.getByRole("alert")).toContainText("Availability could not be saved. Try again.");
  await expect(control.getByRole("combobox", { name: "Set status" })).toHaveValue("available");
  await expect(control.getByText("Do not disturb saved.", { exact: true })).toHaveCount(0);
  await control.getByRole("button", { name: "Retry availability", exact: true }).click();
  await expect(control.getByRole("alert")).toHaveCount(0);
  await control.getByRole("button", { name: "Pause notifications", exact: true }).click();
  await expect(control.getByRole("status")).toHaveText("Do not disturb saved.");
  expect(state.writes).toHaveLength(2);
  expect(unexpectedRequests).toEqual([]);
});

for (const width of [320, 390]) {
  test(`${width}px You exposes quick status and opens the full schedule settings`, async ({ page }, info) => {
    const { state, unexpectedRequests } = await workspace(page);
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/app/you");
    const control = page.getByRole("region", { name: "Your availability", exact: true });
    await expect(control.getByRole("heading", { name: "Your availability", exact: true })).toBeInViewport();
    await control.getByRole("combobox", { name: "Status duration" }).selectOption("240");
    await control.getByRole("combobox", { name: "Set status" }).selectOption("busy");
    await expect(control.getByRole("status")).toHaveText("Busy saved.");
    expect(state.writes).toHaveLength(1);
    expect(state.writes[0]?.presence_state).toBe("busy");
    await expectMinimumTargets(control.getByRole("button").or(control.getByRole("combobox")).or(control.getByRole("link")), "Mobile quick availability controls");
    await expectNoDocumentOverflow(page);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    await capture(page, info, `mobile-you-availability-${width}`);
    await control.getByRole("link", { name: "Schedule and notification settings", exact: true }).click();
    await expect(page).toHaveURL("/app/you?section=notifications");
    await expect(page.getByRole("heading", { name: "Availability and do not disturb", exact: true })).toBeVisible();
    await expect(page.getByRole("combobox", { name: "Availability", exact: true })).toHaveValue("busy");
    await expect(page.getByRole("combobox", { name: "Duration", exact: true })).toHaveValue("keep");
    await page.getByRole("button", { name: "Save availability", exact: true }).click();
    await expect(page.getByText(/Availability saved\. Do not disturb pauses email and push/)).toBeVisible();
    expect(state.writes[1]?.presence_expires_at).toBe(state.writes[0]?.presence_expires_at);
    expect(unexpectedRequests).toEqual([]);
  });
}
