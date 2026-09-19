import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { conversationId, installWorkspace } from "./mobile-ui-support";

test("a failed route module keeps the shell usable and reloads only on request", async ({ page }) => {
  await installWorkspace(page);
  await page.route("**/api/v1/files?**", (route) => route.fulfill({ json: {
    data: [], page: { limit: 25, has_more: false, next_cursor: null }
  } }));
  const failedModule = /\/src\/features\/files\/FilesPage\.tsx(?:\?.*)?$/;
  let failures = 0;
  await page.route(failedModule, (route) => { failures += 1; return route.abort(); });
  await page.goto("/app/files");
  const recovery = page.getByRole("heading", { name: "This page could not open" });
  await expect(recovery).toBeFocused();
  await expect(page.locator(".app-shell")).toBeVisible();
  await expect(page.getByText(/Before reloading, finish any active call/)).toBeVisible();
  expect(failures).toBe(1);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.unroute(failedModule);
  await page.getByRole("button", { name: "Reload K-Comms" }).click();
  await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
  await expect(page.getByText("No shared files")).toBeVisible();
});

test("blocked draft storage produces a truthful session-only status", async ({ page }) => {
  await installWorkspace(page);
  await page.addInitScript(() => {
    const setItem = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === window.localStorage && key.startsWith("k-comms.draft.")) {
        throw new DOMException("Synthetic full storage", "QuotaExceededError");
      }
      return setItem.call(this, key, value);
    };
  });
  await page.goto(`/app/?conversation=${conversationId}`);
  await page.getByRole("textbox", { name: "Message", exact: true }).fill("Keep this tab draft");
  await expect(page.getByText("Kept in this tab only. Send before reloading or closing.")).toBeVisible();
  await expect(page.getByText("Saved on this device", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveValue("Keep this tab draft");
});
