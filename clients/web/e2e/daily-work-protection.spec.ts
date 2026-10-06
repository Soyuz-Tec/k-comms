import type { Page, TestInfo } from "@playwright/test";
import { expect, mockServiceStatus, test } from "./fixtures";
import { conversationId, installWorkspace } from "./mobile-ui-support";

const documentId = "11111111-1111-4111-8111-111111111111";
const snapshot = { id: documentId, conversation_id: conversationId, title: "Project notes", content: "", atoms: [],
  generation: 1, version: 1, readonly: false, updated_at: "2026-10-06T12:00:00Z" };
async function capture(page: Page, info: TestInfo, name: string) {
  if (process.env.K_COMMS_VISUAL_CAPTURE !== "1") return;
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: info.outputPath(`${name}.png`), animations: "disabled" });
}
test.beforeEach(async ({ page }, info) => {
  test.skip(!["chromium", "webkit"].includes(info.project.name), "History and readiness qualification runs once per desktop engine");
  await page.setViewportSize({ width: 1440, height: 900 });
});

test("unsent document edits survive Stay and require discard for browser Back", async ({ page }, info) => {
  const state = await installWorkspace(page);
  await page.route(`**/api/v1/conversations/${conversationId}/documents*`, route => route.fulfill({ json: { data: [{ ...snapshot, excerpt: "Shared project plan" }] } }));
  await page.route(`**/api/v1/documents/${documentId}`, route => route.fulfill({ json: { data: snapshot } }));
  await page.route(`**/api/v1/documents/${documentId}/operations?**`, route => route.fulfill({ json: {
    data: [], page: { generation: 1, through_version: 1, has_more: false, next_after_version: 1 }
  } }));
  let finishWrite: (() => void) | undefined;
  await page.route(`**/api/v1/documents/${documentId}/operations`, async route => {
    await new Promise<void>(resolve => { finishWrite = resolve; });
    await route.fulfill({ status: 503, json: { error: { code: "unavailable", detail: "Synthetic connection interrupted" } } });
  });
  await page.route("**/api/v1/socket-tickets", route => route.fulfill({ json: { data: { ticket: "synthetic-document-ticket", expires_in: 60 } } }));
  await page.routeWebSocket(/\/socket\/websocket(?:\?|$)/, socket => socket.onMessage(message => {
    const [joinRef, reference, topic, event] = JSON.parse(String(message)) as [string | null, string, string, string, unknown];
    if (["phx_join", "phx_leave", "heartbeat"].includes(event)) socket.send(JSON.stringify([joinRef, reference, topic, "phx_reply", { status: "ok", response: {} }]));
  }));
  await page.goto("/app/content");
  await page.getByRole("navigation", { name: "Browse content", exact: true }).getByRole("link", { name: /^Shared documents\b/ }).click();
  await page.getByRole("button", { name: /^Project notes/ }).click();
  await expect(page.getByText(/All changes synced/)).toBeVisible();
  const editor = page.getByRole("textbox", { name: "Shared document content", exact: true });
  await editor.fill("Unsent review notes");
  await expect(page.getByText(/1 unsent edit/)).toBeVisible();
  await page.locator("#main-content").getByRole("link", { name: "Content", exact: true }).click();
  const dialog = page.getByRole("alertdialog", { name: "Leave unfinished work?", exact: true });
  await expect(dialog).toBeVisible();
  await capture(page, info, "document-unsent-navigation");
  await dialog.getByRole("button", { name: "Stay here", exact: true }).click();
  await expect(editor).toHaveText("Unsent review notes");
  finishWrite?.();
  await expect(page.getByText(/Offline · 1 unsent edit/)).toBeVisible();
  await expect(page.getByText("Live presence is unavailable while disconnected.")).toBeVisible();
  // A real browser POP must restore the address and mounted editor until consent.
  await page.evaluate(() => window.history.back());
  await expect(dialog).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`document=${documentId}`));
  await dialog.getByRole("button", { name: "Leave and discard", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Choose a document to continue", exact: true })).toBeVisible();
  await page.goForward();
  await expect(page.getByText(/All changes synced/)).toBeVisible();
  await expect(editor).toBeEmpty();
  expect(state.unexpectedRequests).toEqual([]);
});

test("private-room setup waits for known availability and can retry a disabled service", async ({ page }, info) => {
  const state = await installWorkspace(page);
  await page.route("**/api/v1/directory/users*", route => route.fulfill({ json: { data: [], page: { has_more: false, next_cursor: null } } }));
  await page.route("**/api/v1/socket-tickets", route => route.fulfill({ json: { data: { ticket: "synthetic-inbox-ticket", expires_in: 60 } } }));
  await page.routeWebSocket(/\/socket\/websocket(?:\?|$)/, socket => socket.onMessage(message => {
    const [joinRef, reference, topic, event] = JSON.parse(String(message)) as [string | null, string, string, string, unknown];
    if (["phx_join", "phx_leave", "heartbeat"].includes(event)) socket.send(JSON.stringify([joinRef, reference, topic, "phx_reply", { status: "ok", response: {} }]));
  }));
  let enabled = false, cryptoRequests = 0;
  await page.route("**/api/v1/status", route => route.fulfill({ json: mockServiceStatus({ private_rooms: enabled }) }));
  await page.route("**/api/v1/private-rooms", route => route.fulfill({ json: { data: [] } }));
  await page.route("**/api/v1/me/matrix/session", route => { cryptoRequests++; return route.fulfill({ status: 503, json: { error: { code: "unavailable", detail: "No live provider in UI fixture" } } }); });
  await page.goto("/app/private");
  await expect(page.getByRole("heading", { name: "Private rooms are not enabled", exact: true })).toBeVisible();
  await expect(page.getByLabel("Local crypto-store password", { exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Unlock encrypted device", exact: true })).toBeDisabled();
  await capture(page, info, "private-rooms-unavailable");
  enabled = true;
  await page.getByRole("button", { name: "Check again", exact: true }).click();
  await expect(page.getByRole("button", { name: "Unlock encrypted device", exact: true })).toBeEnabled();
  await expect(page.getByText("Private rooms are enabled. Unlocking checks the encrypted service connection and your device access.")).toBeVisible();
  expect(cryptoRequests).toBe(0);
  expect(state.unexpectedRequests).toEqual([]);
});
