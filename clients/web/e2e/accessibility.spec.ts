import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

const session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 3600,
  received_at: Date.now(),
  tenant: { id: "tenant-1", name: "Acme Workspace", slug: "acme", status: "active" },
  user: { id: "user-1", tenant_id: "tenant-1", display_name: "Ada Lovelace", email: "ada@example.test", role: "owner", status: "active" },
  device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
};

function seriousOrCritical(violations: Awaited<ReturnType<AxeBuilder["analyze"]>>["violations"]) {
  return violations
    .filter(({ impact }) => impact === "serious" || impact === "critical")
    .map(({ id, impact, nodes }) => ({ id, impact, targets: nodes.map((node) => node.target) }));
}

test("sign-in has no serious or critical accessibility violations", async ({ page }) => {
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();

  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});

test("authenticated messaging shell has no serious or critical accessibility violations", async ({ page }) => {
  await page.addInitScript((value) => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
  await page.route("**/api/v1/me", (route) => route.fulfill({ json: { tenant: session.tenant, user: session.user, device: session.device } }));
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) => route.fulfill({ json: { data: [], page: { limit: 50, has_more: false, next_cursor: null }, meta: { unread_count: 0 } } }));
  await page.route("**/api/v1/users", (route) => route.fulfill({ json: { data: [session.user] } }));
  await page.route("**/api/v1/conversations", (route) => route.fulfill({ json: { data: [] } }));

  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();

  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});

test("keyboard focus remains visible in forced-colors and reduced-motion modes", async ({ page }) => {
  await page.emulateMedia({ forcedColors: "active", reducedMotion: "reduce" });
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();

  await page.keyboard.press("Tab");
  const focused = page.locator(":focus");
  await expect(focused).toBeVisible();
  await expect(focused).not.toHaveCSS("outline-style", "none");

  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});
