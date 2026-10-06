import { expect, test } from "./fixtures";
import type { Locator, Page } from "@playwright/test";
import { conversationId, installWorkspace, messageId, userId } from "./mobile-ui-support";

const fileName = "Quarterly-financial-report.pdf";

async function installWorkflowFixtures(page: Page) {
  await installWorkspace(page);
  await page.route("**/api/v1/files?**", (route) => route.fulfill({ json: {
    data: [{
      id: "responsive-file-1", conversation_id: conversationId, message_id: messageId,
      conversation_sequence: 1, owner_user_id: userId, file_name: fileName,
      content_type: "application/pdf", byte_size: 1200, status: "ready", scan_status: "clean",
      safety_state: "available", downloadable: true, shared_at: "2026-10-03T12:00:00Z",
      uploaded_at: "2026-10-03T12:00:00Z", inserted_at: "2026-10-03T12:00:00Z",
      updated_at: "2026-10-03T12:00:00Z"
    }], page: { limit: 25, has_more: false, next_cursor: null }
  } }));
  await page.route("**/api/v1/calls?**", (route) => {
    const recent = new URL(route.request().url()).searchParams.get("scope") === "recent";
    return route.fulfill({ json: {
      data: [{
        id: "responsive-call-1", conversation_id: conversationId, started_by_user_id: userId,
        ended_by_user_id: recent ? userId : null, media_kind: "video", status: recent ? "ended" : "active",
        started_at: "2026-10-03T10:00:00Z", expires_at: "2099-01-01T00:00:00Z",
        ended_at: recent ? "2026-10-03T10:05:00Z" : null,
        end_reason: recent ? "ended_by_host" : null, duration_seconds: 300, can_end: true
      }], page: { limit: 25, has_more: false, next_cursor: null }
    } });
  });
  await page.route("**/api/v1/telephony/calls?**", (route) => route.fulfill({ json: {
    data: new URL(route.request().url()).searchParams.get("scope") === "active" ? [] : [{
      id: "responsive-phone-1", direction: "outbound", status: "ended", from_number: "+14155550123",
      to_number: "+14155550199", extension: "101", started_at: "2026-10-03T10:00:00Z",
      answered_at: "2026-10-03T10:00:05Z", ended_at: "2026-10-03T10:01:05Z", connected_seconds: 60,
      can_answer: false, can_join: false, can_end: false, active_on_this_device: false
    }], page: { limit: 30, has_more: false, next_cursor: null }
  } }));
}

async function expectContentToFit(page: Page, selector: string) {
  const geometry = await page.locator(selector).evaluate((content) => {
    const bounds = content.getBoundingClientRect();
    const visible = Array.from(content.querySelectorAll("*"))
      .filter((element) => element instanceof HTMLElement)
      .filter((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        const screenReaderOnly = rect.width <= 1 && rect.height <= 1 && (style.clip !== "auto" || style.clipPath !== "none");
        return element.checkVisibility() && rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden" && !screenReaderOnly;
      });
    const overflow = visible
      // Screen-reader copy and filename ellipsis do not hide workflow controls.
      .filter((element) => !element.classList.contains("sr-only") && getComputedStyle(element).textOverflow !== "ellipsis")
      .filter((element) => element.scrollWidth > element.clientWidth + 1)
      .map((element) => ({ element: element.className || element.tagName, client: element.clientWidth, scroll: element.scrollWidth }));
    const clippedControls = visible
      .filter((element) => element.matches("button, input, select, a[href]"))
      .filter((element) => {
        const rect = element.getBoundingClientRect();
        return rect.left < bounds.left - 1 || rect.right > bounds.right + 1;
      })
      .map((element) => element.getAttribute("aria-label") || element.textContent?.trim() || element.tagName);
    return {
      viewport: document.documentElement.clientWidth,
      documentScroll: document.documentElement.scrollWidth,
      bodyScroll: document.body.scrollWidth,
      client: content.clientWidth,
      scroll: content.scrollWidth,
      overflow,
      clippedControls
    };
  });
  expect(geometry.documentScroll).toBeLessThanOrEqual(geometry.viewport + 1);
  expect(geometry.bodyScroll).toBeLessThanOrEqual(geometry.viewport + 1);
  expect(geometry.scroll, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.client + 1);
  expect(geometry.overflow).toEqual([]);
  expect(geometry.clippedControls).toEqual([]);
}

async function expectControlToFit(control: Locator) {
  await expect(control).toBeVisible();
  const clips = await control.evaluate((element) => {
    const rect = element.getBoundingClientRect();
    const clips: string[] = [];
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      if (!["hidden", "clip", "auto", "scroll"].includes(style.overflowX)) continue;
      const bounds = parent.getBoundingClientRect();
      if (rect.left < bounds.left - 1 || rect.right > bounds.right + 1) clips.push(parent.className || parent.tagName);
    }
    return clips;
  });
  expect(clips).toEqual([]);
}

for (const width of [761, 1024, 1280, 390]) {
  test(`Files, Calls, and Phone keep required controls within content at ${width}px`, async ({ page }, testInfo) => {
    test.skip(testInfo.project.name.startsWith("mobile-"), "The explicit viewport matrix runs in desktop browser engines.");
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    await installWorkflowFixtures(page);

    await page.goto("/app/files");
    await expectControlToFit(page.getByRole("button", { name: `File details for ${fileName}` }));
    await expectControlToFit(page.getByRole("button", { name: "Share a file" }));
    if (width > 760) await expect(page.locator(".app-shell")).toHaveClass(/workspace-navigation-pinned/);
    await expectContentToFit(page, ".files-page");
    await page.getByLabel("Advanced file filters", { exact: true }).click();
    await expect(page.getByRole("combobox", { name: "Conversation", exact: true })).toBeVisible();
    await expectContentToFit(page, ".files-page");
    await expectControlToFit(page.getByRole("combobox", { name: "Conversation", exact: true }));
    await page.getByLabel("Advanced file filters", { exact: true }).click();

    await page.goto("/app/calls");
    await expect(page.getByRole("button", { name: "Recent", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("button", { name: "Start video call for General" })).toBeVisible();
    if (width === 390) {
      const launcher = page.getByRole("button", { name: "Start call", exact: true });
      await expect(launcher).toHaveAttribute("aria-expanded", "false");
      await launcher.click();
      await expect(page.getByRole("searchbox", { name: "Find a conversation to call" })).toBeFocused();
    }
    for (const scope of ["Active", "Recent"]) {
      await page.getByRole("button", { name: scope, exact: true }).click();
      await expectControlToFit(page.getByRole("button", { name: `${scope === "Active" ? "Join" : "Start"} video call for General` }));
      await expectControlToFit(page.getByRole("link", { name: "Message General", exact: true }));
      await expectControlToFit(page.getByRole("link", { name: "Open chat for General", exact: true }));
      await expectContentToFit(page, ".calls-page");
    }
    if (width === 390) {
      await page.getByRole("button", { name: "Hide call launcher", exact: true }).click();
      await expect(page.locator("#calls-launcher")).toBeHidden();
    }

    await page.goto("/app/calls/phone");
    await expect(page.getByText("60s connected")).toBeVisible();
    await expectControlToFit(page.getByLabel("Show calls"));
    await expectControlToFit(page.getByRole("button", { name: "Refresh phone calls" }));
    await expectControlToFit(page.getByRole("button", { name: "Use number" }));
    await expectControlToFit(page.getByRole("button", { name: "Call number" }));
    await expectContentToFit(page, ".phone-page");
    const dialer = await page.getByRole("region", { name: "Dial a number", exact: true }).boundingBox();
    const history = await page.getByRole("region", { name: "Call history", exact: true }).boundingBox();
    // The activity rail and pinned sidebar reduce usable space at 1024px.
    // Verify the readable panel arrangement rather than assuming viewport
    // width alone determines the number of CSS grid tracks.
    if (width <= 1024) {
      expect(history!.y).toBeGreaterThanOrEqual(dialer!.y + dialer!.height);
      expect(Math.abs(history!.x - dialer!.x)).toBeLessThanOrEqual(1);
    } else {
      expect(history!.x).toBeGreaterThanOrEqual(dialer!.x + dialer!.width);
      expect(Math.abs(history!.y - dialer!.y)).toBeLessThanOrEqual(1);
    }
    expect(await page.getByLabel("Show calls").evaluate((element) => element.clientWidth)).toBeGreaterThan(160);
  });
}
