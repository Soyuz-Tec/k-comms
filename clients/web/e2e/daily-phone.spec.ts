import { expect, test } from "./fixtures";
import type { PhoneCall } from "../src/features/telephony/types";
import { installWorkspace, userId } from "./mobile-ui-support";

const line = { id: "daily-line", phone_number: "+14155550123", extension: "101", user_id: userId };
const call: PhoneCall = { id: "daily-missed", direction: "inbound", status: "no_answer", from_number: "+14155550999", to_number: line.phone_number, extension: "101", started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: "2026-10-03T12:00:30Z", connected_seconds: 0, can_answer: false, can_join: false, can_end: false, active_on_this_device: false };
const pageOf = (data: PhoneCall[], next: string | null = null) => ({ data, page: { limit: 30, has_more: Boolean(next), next_cursor: next } });

for (const width of [1440, 390, 320]) {
  test(`daily phone review and retained history work at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 900 });
    await installWorkspace(page);
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: async () => new MediaStream() } });
    });
    await page.route("**/api/v1/telephony/config", route => route.fulfill({ json: { data: { enabled: true, configured: true, provider_ready: true, line_assigned: true, provider: "livekit_sip", number: line, can_manage: false } } }));
    await page.route("**/api/v1/telephony/agent-state", route => route.fulfill({ status: 404, json: { error: { code: "telephony_agent_not_assigned", detail: "No queue assignment" } } }));
    await page.route("**/api/v1/telephony/voicemails?**", route => route.fulfill({ json: { data: [{ id: "daily-voicemail", call_id: call.id, caller_number: call.from_number, status: "available", duration_seconds: 24, inserted_at: call.started_at, available_at: call.started_at, retention_expires_at: "2026-11-03T12:00:00Z", read_at: null }], configured: true, page: { limit: 30, has_more: false, next_cursor: null } } }));
    const historyRequests: URLSearchParams[] = [];
    await page.route("**/api/v1/telephony/calls?**", route => {
      const query = new URL(route.request().url()).searchParams;
      if (query.get("scope") === "active") return route.fulfill({ json: pageOf([]) });
      historyRequests.push(query);
      if (query.get("q") === "0999") {
        if (query.get("cursor") === "matched-older") return route.fulfill({ json: pageOf([{ ...call, id: "daily-older", started_at: "2026-10-02T12:00:00Z" }]) });
        return route.fulfill({ json: pageOf([call], "matched-older") });
      }
      return route.fulfill({ json: pageOf([{ ...call, id: "other-number", from_number: "+14155550888" }]) });
    });
    const destinations: string[] = [];
    await page.route("**/api/v1/telephony/calls", route => {
      destinations.push((route.request().postDataJSON() as { destination: string }).destination);
      return route.fulfill({ status: 503, json: { error: { code: "telephony_provider_unavailable", detail: "Synthetic provider unavailable" } } });
    });
    await page.goto("/app/calls/phone");
    await expect(page.getByRole("heading", { name: "Phone", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Return call", exact: true })).toBeVisible();
    expect(destinations).toEqual([]);
    await page.getByRole("button", { name: "Return call", exact: true }).click();
    await expect(page.getByLabel("Phone number", { exact: true })).toHaveValue(call.from_number);
    await expect(page.getByLabel("Phone number", { exact: true })).toBeFocused();
    expect(destinations).toEqual([]);
    await page.getByRole("searchbox", { name: "Search phone history", exact: true }).fill("0999");
    await page.getByText("Date and direction", { exact: true }).click();
    await page.getByRole("combobox", { name: "Direction", exact: true }).selectOption("inbound");
    await page.getByLabel("From (UTC)").fill("2026-10-01");
    await page.getByLabel("To (UTC)").fill("2026-10-05");
    await page.getByRole("button", { name: "Search history", exact: true }).click();
    await expect(page.getByRole("button", { name: "Load more phone calls", exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Load more phone calls", exact: true }).click();
    await expect(page.locator(".phone-history-list").first().getByRole("listitem")).toHaveCount(2);
    const request = historyRequests.at(-1)!;
    expect(Object.fromEntries(request)).toMatchObject({ q: "0999", direction: "inbound", from: "2026-10-01", to: "2026-10-05", cursor: "matched-older" });
    await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.getByLabel("Phone number", { exact: true }).fill("+1 (415) 555-0999 ext 101");
    await expect(page.getByRole("button", { name: "Call number", exact: true })).toBeDisabled();
    await page.getByLabel("Phone number", { exact: true }).fill("+1 (415) 555-0999");
    await expect(page.getByRole("button", { name: "Call number", exact: true })).toBeEnabled();
    if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
      await page.evaluate(() => document.fonts.ready);
      await page.getByRole("heading", { name: "Phone", exact: true }).scrollIntoViewIfNeeded();
      await page.screenshot({ path: info.outputPath(`phone-daily-${width}.png`), animations: "disabled" });
      await page.getByRole("heading", { name: "Voicemail", exact: true }).scrollIntoViewIfNeeded();
      await page.screenshot({ path: info.outputPath(`phone-voicemail-${width}.png`), animations: "disabled" });
    }
    expect(destinations).toEqual([]);
    await page.getByRole("button", { name: "Call number", exact: true }).click();
    await expect.poll(() => destinations).toEqual([call.from_number]);
    await expect(page.getByRole("alert")).toContainText("Synthetic provider unavailable");
    await expect(page.getByRole("button", { name: "Call number", exact: true })).toBeEnabled();
  });
}
