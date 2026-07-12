import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

async function openPublicRoute(page: Page, path: string) {
  await page.route("**/api/v1/status", (route) => route.fulfill({ json: { service: "k-comms", version: "0.3.0", status: "operational", capabilities: { bootstrap: false } } }));
  await page.goto("/app/");
  await page.evaluate((nextPath) => {
    window.history.pushState({}, "", nextPath);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }, path);
}

test("forgot-password request remains non-enumerating and keyboard usable", async ({ page }) => {
  let requestBody: unknown;
  await page.route("**/api/v1/password-recovery/requests", async (route) => {
    requestBody = route.request().postDataJSON();
    await route.fulfill({ status: 202 });
  });
  await openPublicRoute(page, "/forgot-password");

  await expect(page.getByLabel("Workspace slug")).toBeFocused();
  await page.getByLabel("Workspace slug").fill("acme");
  await page.getByLabel("Email address").fill("unknown@example.test");
  await page.getByLabel("Email address").press("Enter");

  await expect(page.getByRole("heading", { name: "Check your email" })).toBeVisible();
  await expect(page.getByText(/If an account matches those details/)).toBeVisible();
  await expect(page.getByText("unknown@example.test")).toHaveCount(0);
  expect(requestBody).toEqual({ tenant_slug: "acme", email: "unknown@example.test" });
});

test("reset token is scrubbed before interaction and never persisted", async ({ page }) => {
  let resetBody: unknown;
  await page.route("**/api/v1/password-recovery/resets", async (route) => {
    resetBody = route.request().postDataJSON();
    await route.fulfill({ status: 204 });
  });
  await openPublicRoute(page, "/reset-password?utm_source=email#token=single-use-secret&campaign=spring");

  await expect(page).toHaveURL(/utm_source=email/);
  await expect(page).not.toHaveURL(/token=/);
  await expect(page).toHaveURL(/campaign=spring/);
  await expect(page.getByLabel("New password", { exact: true })).toBeFocused();
  await page.getByLabel("New password", { exact: true }).fill("correct horse battery staple");
  await page.getByLabel("Confirm new password", { exact: true }).fill("correct horse battery staple");
  await page.getByRole("button", { name: "Update password" }).click();

  await expect(page.getByRole("heading", { name: "Password updated" })).toBeVisible();
  expect(resetBody).toEqual({ token: "single-use-secret", new_password: "correct horse battery staple" });
  const storage = await page.evaluate(() => ({
    local: Object.values(localStorage),
    session: Object.values(sessionStorage)
  }));
  expect(JSON.stringify(storage)).not.toContain("single-use-secret");
});

test("server password-policy errors are safe and actionable", async ({ page }) => {
  await page.route("**/api/v1/password-recovery/resets", (route) => route.fulfill({
    status: 422,
    contentType: "application/json",
    json: { error: { code: "weak_password", detail: "do not render this server detail" } }
  }));
  await openPublicRoute(page, "/reset-password?token=never-display-this");
  await page.getByLabel("New password", { exact: true }).fill("twelve-characters");
  await page.getByLabel("Confirm new password", { exact: true }).fill("twelve-characters");
  await page.getByRole("button", { name: "Update password" }).click();

  await expect(page.getByRole("alert")).toContainText("server's password policy");
  await expect(page.locator("body")).not.toContainText("never-display-this");
  await expect(page.locator("body")).not.toContainText("do not render this server detail");
});
