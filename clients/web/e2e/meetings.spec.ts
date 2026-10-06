import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { conversationId, expectNoDocumentOverflow, installWorkspace, userId } from "./mobile-ui-support";
import type { Meeting, MeetingInput } from "../src/types/meetings";

// Explicitly synthetic HTTP fixtures exercise rendered scheduling, not calendar-provider/media readiness.
for (const viewport of [{ name: "desktop", width: 1440, height: 900 }, { name: "mobile", width: 390, height: 844 }]) {
  test(`meeting scheduling, calendar, failed edit, cancellation and ICS download (${viewport.name})`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await page.clock.setFixedTime(new Date("2026-10-04T09:00:00Z"));
    const workspace = await installWorkspace(page);
    let meeting: Meeting | null = null;
    let createInput: MeetingInput | null = null;
    let failedEdits = 0;
    let cancelledVersion: number | null = null;
    await page.route("**/api/v1/meetings**", async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (route.request().method() === "GET" && path === "/api/v1/meetings") {
        return route.fulfill({ json: { data: meeting ? [meeting] : [], meta: { truncated: false, calendar: { ics: true, google: false, microsoft: false } } } });
      }
      if (path.endsWith("/calendar")) {
        return route.fulfill({ json: { data: { filename: "meeting-synthetic.ics", ics: `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:${meeting?.status === "cancelled" ? "CANCEL" : "PUBLISH"}\r\nEND:VCALENDAR\r\n` } } });
      }
      if (route.request().method() === "PATCH") {
        failedEdits += 1;
        return route.fulfill({ status: 409, json: { error: { code: "stale_version", detail: "Meeting changed; refresh before editing." } } });
      }
      if (path.endsWith("/cancel") && meeting) {
        cancelledVersion = (route.request().postDataJSON() as { expected_version: number }).expected_version;
        meeting = { ...meeting, status: "cancelled", version: meeting.version + 1,
          occurrences: meeting.occurrences.map((occurrence) => ({ ...occurrence, status: "cancelled" })) };
        return route.fulfill({ json: { data: meeting } });
      }
      return route.fulfill({ status: 422, json: { error: { code: "unexpected_fixture_request", detail: "Unexpected synthetic meeting request" } } });
    });
    await page.route(`**/api/v1/conversations/${conversationId}/meetings`, async (route) => {
      createInput = route.request().postDataJSON() as MeetingInput;
      meeting = { ...createInput, id: "synthetic-meeting", conversation_id: conversationId, host_user_id: userId,
        status: "scheduled", version: 1, can_manage: true,
        occurrences: [{ id: "synthetic-occurrence", starts_at: "2026-10-07T14:00:00Z", ends_at: "2026-10-07T14:30:00Z", status: "scheduled", call_id: null }] };
      return route.fulfill({ status: 201, json: { data: meeting } });
    });

    await page.goto("/app/meetings");
    await expect(page.getByRole("heading", { name: "Meetings", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Agenda", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("region", { name: /meeting calendar/ })).toHaveCount(0);
    await page.getByRole("button", { name: "Schedule meeting", exact: true }).click();
    const editor = page.getByRole("dialog", { name: "Schedule meeting" });
    await editor.getByLabel("Title", { exact: true }).fill("Planning review");
    await editor.getByLabel("Conversation", { exact: true }).selectOption(conversationId);
    await editor.getByLabel("Local start date and time").fill("2026-10-07T10:00");
    await editor.getByLabel("Time zone", { exact: true }).fill("America/New_York");
    await editor.getByLabel("Repeat", { exact: true }).selectOption("weekly");
    await editor.getByLabel("Number of occurrences").fill("3");
    await editor.getByRole("button", { name: "Schedule meeting", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Planning review", exact: true })).toBeVisible();
    await expect(page.getByRole("region", { name: "Meeting sharing" })).toContainText("Email invitations are not sent automatically.");
    await expect(page.getByRole("button", { name: "Copy member meeting link" })).toBeEnabled();
    expect(createInput).toMatchObject({ timezone: "America/New_York", local_start: "2026-10-07T10:00", recurrence: { frequency: "weekly", interval: 1, count: 3 }, reminder_minutes: 15 });
    await expect(page.getByRole("region", { name: "Up next" })).toHaveCount(0);
    await page.getByRole("button", { name: "Calendar", exact: true }).click();
    const next = page.getByRole("region", { name: "Up next" });
    await expect(next).toContainText("Planning review");
    await next.getByRole("button", { name: "View next meeting" }).click();
    await expect(page.getByRole("button", { name: "Agenda", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("region", { name: /meeting calendar/ })).toHaveCount(0);
    await expect(page.locator("#meeting-synthetic-occurrence")).toBeFocused();
    await expect(page.getByRole("button", { name: "Start meeting", exact: true })).toBeDisabled();
    await page.getByRole("button", { name: "Calendar", exact: true }).click();
    await expect(page.getByRole("region", { name: "2026-10 meeting calendar" })).toBeVisible();
    await page.getByRole("button", { name: "2026-10-07, 1 meetings", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Meetings on 2026-10-07" })).toBeVisible();
    await page.getByRole("button", { name: "Edit series", exact: true }).click();
    const edit = page.getByRole("dialog", { name: "Edit meeting" });
    await edit.getByLabel("Title", { exact: true }).fill("Retained local draft");
    await edit.getByRole("button", { name: "Save changes" }).click();
    await expect(edit.getByRole("alert")).toContainText("Meeting changed");
    await expect(edit.getByLabel("Title", { exact: true })).toHaveValue("Retained local draft");
    expect(failedEdits).toBe(1);
    await edit.getByRole("button", { name: "Close", exact: true }).click();
    await page.getByRole("button", { name: "Cancel series", exact: true }).click();
    await page.getByRole("alertdialog", { name: "Cancel meeting?" }).getByRole("button", { name: "Cancel meeting", exact: true }).click();
    await expect(page.getByText("Cancelled", { exact: true })).toBeVisible();
    expect(cancelledVersion).toBe(1);
    await page.getByRole("button", { name: "Agenda", exact: true }).click();
    await expect(page.getByRole("region", { name: "Up next" })).toHaveCount(0);
    const download = page.waitForEvent("download");
    await page.getByRole("button", { name: "Download invitation", exact: true }).click();
    expect((await download).suggestedFilename()).toBe("meeting-synthetic-meeting.ics");
    await expect(page.getByRole("button", { name: "Start meeting", exact: true })).toHaveCount(0);
    await expectNoDocumentOverflow(page);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    expect(workspace.unexpectedRequests).toEqual([]);
  });
}
