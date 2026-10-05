import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";
import { usageFixture } from "../src/features/admin/usageReports.testSupport";

// These stock cases qualify route-mocked interaction and layout only. Real
// database owner projections and native authenticated journeys are separate.
for (const variant of [{ width: 390, colorScheme: "dark" as const }, { width: 1024, colorScheme: "light" as const }]) {
  test(`retained usage ${variant.width}px ${variant.colorScheme} keeps UTC exports applied and unavailable metrics unknown`, async ({ page }) => {
    await page.setViewportSize({ width: variant.width, height: 900 }); await page.emulateMedia({ colorScheme: variant.colorScheme });
    const fixture = await installWorkspace(page);
    const report = usageFixture();
    let fresh = false;
    const exports: Array<{ from: string | null; through: string | null }> = [];
    await page.route("**/api/v1/**", async (route) => {
      const url = new URL(route.request().url());
      if (url.pathname === "/api/v1/me/step-up" && route.request().method() === "POST") {
        fresh = true;
        return route.fulfill({ json: { data: { step_up_at: "2000-01-03T12:00:00Z" } } });
      }
      if (url.pathname === "/api/v1/admin/usage" || url.pathname === "/api/v1/admin/usage/export") {
        if (!fresh) return route.fulfill({ status: 428, json: { error: { code: "step_up_required", detail: "Synthetic verification required" } } });
        if (url.pathname.endsWith("/export")) {
          exports.push({ from: url.searchParams.get("from"), through: url.searchParams.get("through") });
          return route.fulfill({ contentType: "text/csv", body: "source,status,metric,value\r\nidentity,available,active_humans,2\r\n", headers: {
            "content-disposition": 'attachment; filename="usage-2000-01-01-2000-01-02.csv"',
            "x-usage-from": "2000-01-01", "x-usage-through": "2000-01-02", "x-usage-time-zone": "UTC",
            "x-usage-observed-at": "2000-01-03T13:00:00Z", "x-usage-unavailable-sources": "2"
          } });
        }
        return route.fulfill({ json: { data: report } });
      }
      return route.fallback();
    });
    await page.goto("/admin?section=usage");
    const initialVerification = await page.getByRole("dialog", { name: "Confirm it is you" });
    await initialVerification.getByLabel("Current password").fill("synthetic-current-password");
    await initialVerification.getByRole("button", { name: "Continue" }).click();
    await expect(page.getByRole("region", { name: "Accounts usage" })).toBeVisible();
    await expect(page.getByText("4 of 6 sources reported")).toBeVisible();
    const attachments = page.getByRole("region", { name: "Attachments usage" });
    await expect(attachments).toContainText("Source unavailable");
    await expect(attachments).toContainText("Current totals and daily metrics are unknown.");
    await expect(attachments.getByText("0", { exact: true })).toHaveCount(0);
    const calls = page.getByRole("region", { name: "Meeting calls usage" });
    await calls.getByText("Daily retained records for meeting calls").click();
    await calls.getByLabel("Daily meeting calls metric").selectOption("observed_room_seconds");
    await expect(calls.getByRole("cell", { name: "120", exact: true })).toBeVisible();
    await expectNoDocumentOverflow(page);
    const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"]).analyze();
    expect(results.violations.map(({ id, nodes }) => ({ id, targets: nodes.map(({ target }) => target) }))).toEqual([]);
    await page.getByLabel("From (UTC)").fill("2000-01-02");
    fresh = false;
    const downloaded = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export applied usage CSV" }).click();
    const exportVerification = await page.getByRole("dialog", { name: "Confirm it is you" });
    await exportVerification.getByLabel("Current password").fill("synthetic-current-password");
    await exportVerification.getByRole("button", { name: "Continue" }).click();
    expect((await downloaded).suggestedFilename()).toBe("usage-2000-01-01-2000-01-02.csv");
    await expect(page.getByRole("status")).toContainText("2 sources unavailable");
    expect(exports).toEqual([{ from: "2000-01-01", through: "2000-01-02" }]);
    expect(fixture.unexpectedRequests).toEqual([]);
  });
}
