import { expect, test } from "@playwright/test";

test("production capability status hides workspace bootstrap", async ({ page }) => {
  await page.route("**/api/v1/status", (route) => route.fulfill({
    json: {
      service: "k-comms",
      version: "0.3.0",
      status: "operational",
      capabilities: {
        administration: true,
        attachment_scanning: true,
        bootstrap: false,
        notifications: true,
        realtime: true,
        webhooks: true
      }
    }
  }));
  await page.goto("/app/");
  await expect(page.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();
  await expect(page.getByRole("tab", { name: "Create workspace" })).toHaveCount(0);
});

test("invitation token is loaded into the form and scrubbed from browser history", async ({ page }) => {
  await page.route("**/api/v1/status", (route) => route.fulfill({ json: { service: "k-comms", version: "0.3.0", status: "operational", capabilities: { bootstrap: false } } }));
  await page.goto("/app/?invitation_token=single-use-token");
  await expect(page.getByLabel("Invitation token")).toHaveValue("single-use-token");
  await expect(page).not.toHaveURL(/invitation_token/);
});
