import { expect, test } from "./fixtures";
import { installWorkspace, userId } from "./mobile-ui-support";
import type { PhoneCall } from "../src/features/telephony/types";

const number = { id: "line-1", phone_number: "+14155550123", extension: "101", user_id: userId };
const incoming: PhoneCall = { id: "phone-1", direction: "inbound", status: "ringing", from_number: "+14155550199", to_number: number.phone_number, extension: number.extension, started_at: "2026-10-03T12:00:00Z", answered_at: null, ended_at: null, connected_seconds: 0, can_answer: true, can_join: false, can_end: false, active_on_this_device: false };
const phonePage = (calls: PhoneCall[]) => ({ data: calls, page: { limit: 30, has_more: false, next_cursor: null } });

for (const viewport of [
  { name: "desktop", width: 1440, height: 900 },
  { name: "mobile", width: 390, height: 844 }
]) {
  test.describe(viewport.name, () => {
    test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: viewport.width, height: viewport.height }); });

test("Phone explains carrier setup and preserves the five mobile destinations", async ({ page }) => {
  await installWorkspace(page);
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: false, configured: false, provider: "livekit_sip", number: null, can_manage: true } } }));
  await page.goto("/app/calls");
  await page.getByRole("link", { name: "Phone", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/calls\/phone$/);
  await expect(page.getByRole("heading", { name: "Phone", exact: true })).toBeVisible();
  await expect(page.getByText("Phone calling is disabled for this service.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Call number" })).toBeDisabled();
  await expect(page.getByRole("link", { name: "Set up a phone line" })).toHaveAttribute("href", "/admin?section=phone");
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("incoming phone controls persist across routes and reject without microphone access", async ({ page }) => {
  await installWorkspace(page);
  let ringing = true;
  let rejected = false;
  await page.addInitScript(() => {
    if (!navigator.mediaDevices) return;
    navigator.mediaDevices.getUserMedia = async () => { throw new Error("Incoming notification requested microphone before consent"); };
  });
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: true, configured: true, provider: "livekit_sip", number, can_manage: true } } }));
  await page.route("**/api/v1/telephony/calls?**", (route) => route.fulfill({ json: phonePage(ringing ? [incoming] : []) }));
  await page.route(`**/api/v1/telephony/calls/${incoming.id}/reject`, (route) => { ringing = false; rejected = true; return route.fulfill({ json: { data: { ...incoming, status: "declined", can_answer: false } } }); });
  await page.goto("/app/calls");
  await expect(page.getByRole("region", { name: `Incoming call from ${incoming.from_number}` })).toBeVisible();
  await page.getByRole("link", { name: "Phone", exact: true }).click();
  await expect(page.getByRole("region", { name: `Incoming call from ${incoming.from_number}` })).toBeVisible();
  await page.getByRole("button", { name: "Reject", exact: true }).click();
  await expect.poll(() => rejected).toBe(true);
  await expect(page.getByRole("region", { name: `Incoming call from ${incoming.from_number}` })).toHaveCount(0);
  await expect(page.getByText(/requested microphone before consent/)).toHaveCount(0);
});

test("missed history queries the server and includes calls missed while busy", async ({ page }) => {
  await installWorkspace(page);
  let missedRequested = false;
  const busy: PhoneCall = { ...incoming, status: "busy", can_answer: false, ended_at: "2026-10-03T12:00:30Z" };
  const completed: PhoneCall = { ...busy, id: "ended-2", status: "ended", connected_seconds: 48 };
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: true, configured: true, provider: "livekit_sip", number, can_manage: true } } }));
  await page.route("**/api/v1/telephony/calls?**", (route) => {
    const scope = new URL(route.request().url()).searchParams.get("scope");
    if (scope === "active") return route.fulfill({ json: phonePage([]) });
    if (scope === "missed") { missedRequested = true; return route.fulfill({ json: phonePage([busy]) }); }
    return route.fulfill({ json: phonePage([busy, completed]) });
  });
  await page.goto("/app/calls/phone");
  await expect(page.getByText("48s connected")).toBeVisible();
  await page.getByLabel("Show calls").selectOption("missed");
  await expect.poll(() => missedRequested).toBe(true);
  await expect(page.getByText("Incoming · Missed (busy)")).toBeVisible();
  await expect(page.getByText("48s connected")).toHaveCount(0);
});

test("answering an incoming call requests consent and leaves it unclaimed when microphone permission fails", async ({ page }) => {
  await installWorkspace(page);
  let claims = 0;
  await page.addInitScript(() => {
    if (navigator.mediaDevices) navigator.mediaDevices.getUserMedia = async () => { throw new DOMException("Synthetic microphone permission denied", "NotAllowedError"); };
  });
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: true, configured: true, provider: "livekit_sip", number, can_manage: true } } }));
  await page.route("**/api/v1/telephony/calls?**", (route) => route.fulfill({ json: phonePage([incoming]) }));
  await page.route(`**/api/v1/telephony/calls/${incoming.id}/answer`, (route) => { claims += 1; return route.fulfill({ status: 409, json: { error: { code: "test_unexpected_claim", detail: "Consent must precede claiming the call" } } }); });
  await page.goto("/app/calls");
  await page.getByRole("button", { name: "Answer", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Synthetic microphone permission denied");
  expect(claims).toBe(0);
  await expect(page.getByRole("region", { name: `Incoming call from ${incoming.from_number}` })).toBeVisible();
  await expect(page.getByRole("button", { name: "Answer", exact: true })).toBeEnabled();
});


test("an administrator provisions a phone line only after step-up, preserving the audit reason", async ({ page }) => {
  await installWorkspace(page);
  let verified = false;
  let saves = 0;
  let submitted: Record<string, unknown> | null = null;
  let savedNumber: typeof number & { inbound_trunk_id: string; outbound_trunk_id: string } | null = null;
  const configuration = () => ({ enabled: false, configured: false, provider: "livekit_sip", number: savedNumber, can_manage: true });
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: false, configured: false, provider: "livekit_sip", number: null, can_manage: true } } }));
  await page.route("**/api/v1/admin/telephony", (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: { data: configuration() } });
    saves += 1;
    if (!verified) return route.fulfill({ status: 403, json: { error: { code: "step_up_required", detail: "Confirm it is you" } } });
    submitted = route.request().postDataJSON() as Record<string, unknown>;
    savedNumber = { ...number, inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out" };
    return route.fulfill({ json: { data: configuration() } });
  });
  await page.route("**/api/v1/me/step-up", (route) => {
    expect(route.request().postDataJSON()).toEqual({ current_password: "synthetic test password" });
    verified = true;
    return route.fulfill({ json: { data: { step_up_at: "2026-10-03T12:00:00Z" } } });
  });
  await page.goto("/admin?section=phone");
  await page.getByLabel("Phone number").fill(number.phone_number);
  await page.getByLabel("Extension", { exact: true }).fill(number.extension);
  await page.getByLabel("Assigned member").selectOption(userId);
  await page.getByLabel("Inbound SIP trunk ID").fill("ST_in");
  await page.getByLabel("Outbound SIP trunk ID").fill("ST_out");
  await page.getByLabel("Reason for this change").fill("Synthetic phone pilot");
  await page.getByRole("button", { name: "Save phone line" }).click();
  await expect(page.getByRole("dialog", { name: "Confirm it is you" })).toBeVisible();
  expect(submitted).toBeNull();
  await page.getByLabel("Current password").fill("synthetic test password");
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByText("Phone line saved.")).toBeVisible();
  expect(saves).toBe(2);
  expect(submitted).toEqual({ phone_number: number.phone_number, extension: number.extension, user_id: userId, inbound_trunk_id: "ST_in", outbound_trunk_id: "ST_out", reason: "Synthetic phone pilot" });
  await page.reload();
  await expect(page.getByLabel("Phone number")).toHaveValue(number.phone_number);
  await expect(page.getByLabel("Extension", { exact: true })).toHaveValue(number.extension);
  await expect(page.getByLabel("Assigned member")).toHaveValue(userId);
  await expect(page.getByLabel("Inbound SIP trunk ID")).toHaveValue("ST_in");
  await expect(page.getByLabel("Outbound SIP trunk ID")).toHaveValue("ST_out");
});
  });
}
