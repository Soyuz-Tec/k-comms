import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";
import { conversationId, expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";

test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "Desktop shell workflows run in both desktop engines");
  await page.setViewportSize({ width: 1440, height: 900 });
});

async function openWorkspace(page: Page, path = "/app/") {
  await page.addInitScript(() => localStorage.setItem("k-comms.workspace-sidebar-collapsed.v1", "true"));
  const state = await installWorkspace(page, { tenantName: "Example Workspace" });
  await page.route(/\/api\/v1\/directory\/users(?:\?.*)?$/, (route) => route.fulfill({ json: {
    data: [], page: { next_cursor: null }
  } }));
  await page.route(/\/api\/v1\/files(?:\?.*)?$/, (route) => route.fulfill({ json: {
    data: [], page: { limit: 25, has_more: false, next_cursor: null }
  } }));
  await page.route(`**/api/v1/conversations/${conversationId}/documents*`, (route) => route.fulfill({ json: { data: [] } }));
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(path);
  await expect(page.getByRole("heading", { name: path.startsWith("/app/documents") ? "Shared documents" : "Inbox", exact: true })).toBeVisible();
  await expect(page.locator(".desktop-shell-header")).toBeVisible();
  return { state, errors };
}

test("browser shell offers named real shortcuts without native-only controls", async ({ page }) => {
  const { state, errors } = await openWorkspace(page);
  const header = page.locator(".desktop-shell-header");
  const rail = page.getByRole("navigation", { name: "Workspace shortcuts" });
  expect(await header.boundingBox()).toMatchObject({ x: 0, y: 0, width: 1440, height: 44 });
  expect(await rail.boundingBox()).toMatchObject({ x: 0, y: 44, width: 52 });
  expect(await page.locator(".workspace-grid").boundingBox()).toMatchObject({ x: 292, y: 44, width: 1148 });
  const menubar = page.getByRole("menubar", { name: "Application menu" });
  await expect(menubar.getByRole("menuitem")).toHaveText(["File", "View", "Help"]);
  await expect(menubar.getByRole("menuitem", { name: "Edit", exact: true })).toHaveCount(0);
  await expect(header.getByRole("button", { name: /^(Minimize window|Maximize window|Close window)$/ })).toHaveCount(0);
  for (const link of await rail.getByRole("link").all()) {
    const box = await link.boundingBox();
    expect(box!.width).toBeGreaterThanOrEqual(44);
    expect(box!.height).toBeGreaterThanOrEqual(44);
  }
  await rail.getByRole("link", { name: "Open Calls", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Calls", exact: true })).toBeVisible();
  await expect(rail.getByRole("link", { name: "Open Calls", exact: true })).toHaveAttribute("aria-current", "page");
  await expect(rail.getByRole("link", { name: "Open Inbox", exact: true })).not.toHaveAttribute("aria-current");
  const accessibility = await new AxeBuilder({ page }).include(".desktop-shell-header").include(".desktop-activity-rail").analyze();
  expect(accessibility.violations).toEqual([]);
  await expectNoDocumentOverflow(page);
  expect(state.unexpectedRequests).toEqual([]);
  expect(errors).toEqual([]);
});

test("header history follows known workspace routes and discards a replaced forward branch", async ({ page }) => {
  const { state, errors } = await openWorkspace(page);
  const back = page.getByRole("button", { name: "Go back", exact: true });
  const forward = page.getByRole("button", { name: "Go forward", exact: true });
  const rail = page.getByRole("navigation", { name: "Workspace shortcuts" });
  await expect(back).toBeDisabled();
  await expect(forward).toBeDisabled();
  await rail.getByRole("link", { name: "Open Calls", exact: true }).click();
  await expect(page).toHaveURL("/app/calls");
  await expect(back).toBeEnabled();
  await expect(forward).toBeDisabled();
  await rail.getByRole("link", { name: "Open Directory", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Directory", exact: true })).toBeVisible();
  await back.click();
  await expect(page).toHaveURL("/app/calls");
  await expect(forward).toBeEnabled();
  await forward.click();
  await expect(page).toHaveURL("/app/directory");
  await expect(forward).toBeDisabled();
  await back.click();
  await expect(page).toHaveURL("/app/calls");
  await rail.getByRole("link", { name: "Open Files", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
  await expect(forward).toBeDisabled();
  expect(state.unexpectedRequests).toEqual([]);
  expect(errors).toEqual([]);
});

test("File and View actions open the actual workspace switcher and settings", async ({ page }) => {
  const { state, errors } = await openWorkspace(page);
  const menubar = page.getByRole("menubar", { name: "Application menu" });
  await menubar.getByRole("menuitem", { name: "File", exact: true }).click();
  await page.getByRole("menu", { name: "File", exact: true }).getByRole("menuitem", { name: "Go to a conversation or screen…", exact: true }).click();
  const switcher = page.getByRole("dialog", { name: "Go to…", exact: true });
  await expect(switcher).toBeVisible();
  await switcher.getByRole("combobox", { name: "Find a conversation or screen" }).fill("Calls");
  await switcher.getByRole("option", { name: "Calls Workspace", exact: true }).click();
  await expect(page).toHaveURL("/app/calls");
  await expect(page.getByRole("heading", { name: "Calls", exact: true })).toBeVisible();
  await expect(switcher).toHaveCount(0);
  await menubar.getByRole("menuitem", { name: "View", exact: true }).click();
  await page.getByRole("menu", { name: "View", exact: true }).getByRole("menuitem", { name: "Search workspace…", exact: true }).click();
  await expect(switcher).toBeVisible();
  await expect(switcher.getByRole("combobox", { name: "Find a conversation or screen" })).toBeFocused();
  await switcher.getByRole("button", { name: "Close workspace switcher", exact: true }).click();
  await expect(menubar.getByRole("menuitem", { name: "View", exact: true })).toBeFocused();
  await menubar.getByRole("menuitem", { name: "View", exact: true }).click();
  await page.getByRole("menu", { name: "View", exact: true }).getByRole("menuitem", { name: "Your settings", exact: true }).click();
  await expect(page).toHaveURL("/app/you");
  await expect(page.getByRole("link", { name: "Open You (Ada Lovelace)", exact: true })).toHaveAttribute("aria-current", "page");
  expect(state.unexpectedRequests).toEqual([]);
  expect(errors).toEqual([]);
});

test("menu keyboard navigation and Help retain focus while shortcut guards protect editing and dialogs", async ({ page }) => {
  const { state, errors } = await openWorkspace(page);
  const menubar = page.getByRole("menubar", { name: "Application menu" });
  const file = menubar.getByRole("menuitem", { name: "File", exact: true });
  const view = menubar.getByRole("menuitem", { name: "View", exact: true });
  const help = menubar.getByRole("menuitem", { name: "Help", exact: true });
  await file.focus();
  await file.press("ArrowDown");
  await expect(page.getByRole("menuitem", { name: "New instant room", exact: true })).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("menuitem", { name: "Use compact navigation", exact: true })).toBeFocused();
  await page.keyboard.press("End");
  await expect(page.getByRole("menuitem", { name: "Your settings", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
  await expect(view).toBeFocused();

  const inboxSearch = page.getByPlaceholder("Filter conversation titles", { exact: true });
  await inboxSearch.fill("General");
  await inboxSearch.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await expect(inboxSearch).toHaveValue("General");
  await expect(inboxSearch).toBeFocused();
  await help.focus();
  await help.press("ArrowDown");
  await page.getByRole("menuitem", { name: "About K-Comms", exact: true }).press("Enter");
  const about = page.getByRole("dialog", { name: "K-Comms", exact: true });
  await expect(about).toBeVisible();
  const close = about.getByRole("button", { name: "Close", exact: true });
  await expect(close).toBeFocused();
  await close.press("Control+k");
  await expect(about).toBeVisible();
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  await close.click();
  await expect(about).toHaveCount(0);
  await expect(help).toBeFocused();
  await page.getByRole("heading", { name: "Inbox", exact: true }).click();
  await page.keyboard.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog", { name: "Go to…", exact: true })).toHaveCount(0);
  expect(state.unexpectedRequests).toEqual([]);
  expect(errors).toEqual([]);
});

test("Shared documents shortcut preserves a deep-linked conversation", async ({ page }) => {
  const path = `/app/documents?conversation=${conversationId}`;
  const { state, errors } = await openWorkspace(page, path);
  const documents = page.getByRole("navigation", { name: "Workspace shortcuts" }).getByRole("link", { name: "Open Shared documents", exact: true });
  await expect(documents).toHaveAttribute("aria-current", "page");
  await expect(documents).toHaveAttribute("href", path);
  await documents.click();
  await expect(page).toHaveURL(path);
  await expect(page.getByRole("heading", { name: "Shared documents", exact: true })).toBeVisible();
  expect(state.unexpectedRequests).toEqual([]);
  expect(errors).toEqual([]);
});
