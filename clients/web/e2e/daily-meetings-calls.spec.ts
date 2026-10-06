import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { conversationId, tenantId, userId, installWorkspace, installDeterministicMediaDevices, expectNoDocumentOverflow } from "./mobile-ui-support";
import type { Meeting } from "../src/types/meetings";

// Synthetic HTTP journeys verify the rendered workflow, not provider or media qualification.
for (const viewport of [{ name: "desktop", width: 1440, height: 900 }, { name: "mobile", width: 390, height: 844 }]) {
  test(`upcoming agenda crosses months and retains explicit meeting identity (${viewport.name})`, async ({ page }, info) => {
    await page.setViewportSize(viewport);
    await page.clock.setFixedTime(new Date("2026-10-31T23:55:00Z"));
    const workspace = await installWorkspace(page, { sessionReceivedAt: Date.parse("2026-10-31T23:55:00Z") });
    const meeting: Meeting = { id: "11111111-1111-4111-8111-111111111111", conversation_id: conversationId, host_user_id: userId,
      title: "November planning", timezone: "UTC", local_start: "2026-11-01T09:00", duration_minutes: 30,
      recurrence: { frequency: "none", interval: 1, count: 1 }, reminder_minutes: 15,
      host_policy: { allow_guests: false, join_before_host: false }, version: 1, status: "scheduled", can_manage: true,
      occurrences: [{ id: "22222222-2222-4222-8222-222222222222", starts_at: "2026-11-01T09:00:00Z", ends_at: "2026-11-01T09:30:00Z", status: "scheduled" }] };
    const requests: URL[] = [];
    await page.route("**/api/v1/meetings?**", route => {
      const url = new URL(route.request().url()); requests.push(url);
      const start = Date.parse(meeting.occurrences[0]!.starts_at);
      const matches = start >= Date.parse(url.searchParams.get("from")!) && start < Date.parse(url.searchParams.get("to")!);
      return route.fulfill({ json: { data: matches ? [meeting] : [], meta: { truncated: false } } });
    });
    await page.goto("/app/meetings");
    await expect(page.getByRole("heading", { name: "November planning", exact: true })).toBeVisible();
    await expect(page.getByLabel("Agenda range")).toHaveValue("upcoming");
    await expect(page.getByText("Join as", { exact: false })).toContainText("Ada Lovelace");
    expect(Date.parse(requests[0]!.searchParams.get("to")!)).toBe(Date.parse("2027-01-29T23:55:00Z"));
    await expect(page.getByRole("button", { name: "Start meeting", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Copy meeting link", exact: true })).toBeEnabled();
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") await page.screenshot({ path: info.outputPath(`upcoming-agenda-${viewport.name}.png`), fullPage: true });
    await page.getByLabel("Agenda range").selectOption("month");
    await expect(page.getByText("No meetings scheduled this month.", { exact: true })).toBeVisible();
    await page.getByLabel("Month", { exact: true }).fill("2026-11");
    await expect(page.getByRole("heading", { name: "November planning", exact: true })).toBeVisible();
    await expectNoDocumentOverflow(page);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    expect(workspace.unexpectedRequests).toEqual([]);
  });

  test(`recent calls use server history filters and directory recipients reach prejoin (${viewport.name})`, async ({ page }, info) => {
    await page.setViewportSize(viewport);
    await installDeterministicMediaDevices(page);
    const workspace = await installWorkspace(page);
    const requests: URL[] = [];
    await page.route("**/api/v1/calls?**", route => {
      requests.push(new URL(route.request().url()));
      return route.fulfill({ json: { data: [], page: { limit: 25, has_more: false, next_cursor: null } } });
    });
    const person = { id: "33333333-3333-4333-8333-333333333333", display_name: "Katherine Johnson" };
    await page.route("**/api/v1/directory/users?**", route => route.fulfill({ json: { data: [person], page: { next_cursor: null } } }));
    let recipient: string | undefined;
    await page.route("**/api/v1/direct-conversations", route => {
      recipient = (route.request().postDataJSON() as { user_id: string }).user_id;
      return route.fulfill({ json: { data: { id: conversationId, tenant_id: tenantId, kind: "direct", title: null,
        counterpart_user_id: person.id, counterpart_display_name: person.display_name, visibility: "private", latest_sequence: 0,
        inserted_at: "2026-10-06T12:00:00Z", updated_at: "2026-10-06T12:00:00Z" }, meta: { created: true } } });
    });
    await page.goto("/app/calls");
    await expect(page.getByText("No recent call rooms", { exact: true })).toBeVisible();
    expect(requests[0]!.searchParams.get("scope")).toBe("recent");
    const history = page.getByRole("region", { name: "Call history" });
    await history.getByText("Filter call history", { exact: true }).click();
    await history.getByRole("combobox", { name: "Conversation", exact: true }).selectOption(conversationId);
    await history.getByRole("combobox", { name: "Started by", exact: true }).selectOption(userId);
    await history.getByLabel("From", { exact: true }).fill("2026-10-01");
    await history.getByLabel("Through", { exact: true }).fill("2026-10-06");
    await expect.poll(() => requests.at(-1)?.searchParams.get("before")).toBeTruthy();
    expect(requests.at(-1)!.searchParams.get("conversation_id")).toBe(conversationId);
    expect(requests.at(-1)!.searchParams.get("started_by_user_id")).toBe(userId);
    await expect(history.getByText("No calls match these filters", { exact: true })).toBeVisible();
    await expectNoDocumentOverflow(page);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") await page.screenshot({ path: info.outputPath(`filtered-calls-${viewport.name}.png`), fullPage: true });
    await history.getByRole("button", { name: "Clear history filters" }).click();
    await expect.poll(() => requests.at(-1)?.searchParams.get("conversation_id")).toBeNull();
    await page.getByRole("button", { name: "Start call", exact: true }).click();
    await page.getByRole("searchbox", { name: "Find a conversation to call" }).fill("Katherine");
    await page.getByRole("button", { name: "Audio call Katherine Johnson" }).click();
    await expect(page.getByRole("dialog", { name: "Start an audio call" })).toBeVisible();
    expect(recipient).toBe(person.id);
    await page.getByRole("dialog", { name: "Start an audio call" }).getByRole("button", { name: "Cancel", exact: true }).click();
    expect(workspace.unexpectedRequests).toEqual([]);
  });
}
