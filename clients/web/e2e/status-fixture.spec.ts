import { expect, mockServiceStatus, test } from "./fixtures";

test("mocked E2E defaults to a resolved secure transport policy", async ({ page }) => {
  await page.goto("/sign-in");

  const status = await page.evaluate(() =>
    fetch("/api/v1/status").then((response) => response.json())
  );

  expect(status).toEqual(mockServiceStatus());
});

test("an explicit status route overrides the shared default", async ({ page }) => {
  await page.route("**/api/v1/status", (route) =>
    route.fulfill({
      json: mockServiceStatus({
        secure_account_actions: false,
        secure_media_actions: false
      })
    })
  );
  await page.goto("/sign-in");

  const status = await page.evaluate(() =>
    fetch("/api/v1/status").then((response) => response.json())
  );

  expect(status.capabilities).toMatchObject({
    secure_account_actions: false,
    secure_media_actions: false
  });
});
