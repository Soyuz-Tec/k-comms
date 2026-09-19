import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";
import { conversationId, expectNoDocumentOverflow, installWorkspace, messageId, userId } from "./mobile-ui-support";
import type { FileSummary } from "../src/types";

test("filtered files can reach an older image without claiming the whole library is empty", async ({ page }, info) => {
  await installWorkspace(page);
  const document: FileSummary = {
    id: "new-document", conversation_id: conversationId, message_id: messageId,
    conversation_sequence: 1, owner_user_id: userId, file_name: "plan.pdf",
    content_type: "application/pdf", byte_size: 1200, status: "ready",
    scan_status: "clean", safety_state: "available", downloadable: true,
    uploaded_at: "2026-09-01T12:00:00Z", shared_at: "2026-09-01T12:00:00Z",
    inserted_at: "2026-09-01T12:00:00Z", updated_at: "2026-09-01T12:00:00Z"
  };
  const cursors: Array<string | null> = [];
  await page.route("**/api/v1/files?**", (route) => {
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    cursors.push(cursor);
    return route.fulfill({ json: {
      data: [cursor ? { ...document, id: "older-image", file_name: "older-plan.png", content_type: "image/png" } : document],
      page: { limit: 25, has_more: !cursor, next_cursor: cursor ? null : "older-page" }
    } });
  });
  await page.goto("/app/files");
  await page.getByRole("button", { name: "Images", exact: true }).click();
  await expect(page.getByText("No images in loaded files", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Load more files" }).click();
  await expect(page.getByText("older-plan.png", { exact: true })).toBeVisible();
  await expect(page.getByText("No images in loaded files", { exact: true })).toHaveCount(0);
  // StrictMode may repeat the initial fetch; the continuation must use its cursor.
  expect(cursors[0]).toBeNull();
  expect(cursors.filter((cursor) => cursor !== null)).toEqual(["older-page"]);
  await expectNoDocumentOverflow(page);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  if (process.env.K_COMMS_VISUAL_CAPTURE === "1") {
    await page.screenshot({ path: info.outputPath("older-file.png"), animations: "disabled" });
  }
});

test("navigation preserves drafts with reachable phone and desktop controls", async ({ page, isMobile }) => {
  await installWorkspace(page);
  await page.route("**/api/v1/files?**", (route) => route.fulfill({ json: {
    data: [], page: { limit: 25, has_more: false, next_cursor: null }
  } }));
  await page.goto(`/app/?conversation=${conversationId}`);
  const composer = page.getByRole("textbox", { name: "Message", exact: true });
  await composer.fill("Draft before switching screens");
  if (isMobile) {
    await page.getByRole("button", { name: "Back to conversations" }).tap();
    const navigation = page.getByRole("navigation", { name: "Primary navigation" });
    await navigation.getByRole("link", { name: "Files", exact: true }).tap();
    await expect(page.getByRole("heading", { name: "Files", exact: true })).toBeVisible();
    await navigation.getByRole("link", { name: "Inbox", exact: true }).tap();
    await page.getByRole("navigation", { name: "Conversation list" }).getByRole("button", { name: /^General / }).tap();
  } else {
    const trigger = page.getByRole("button", { name: "Switch conversation or screen" });
    if (!await trigger.isVisible()) await page.getByRole("button", { name: "Show workspace navigation" }).click();
    await trigger.click();
    const dialog = page.getByRole("dialog", { name: "Go to…", exact: true });
    await expect(dialog.getByRole("combobox", { name: "Find a conversation or screen" })).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(trigger).toBeFocused();
  }
  await expect(composer).toHaveValue("Draft before switching screens");
  await page.reload();
  await expect(composer).toHaveValue("Draft before switching screens");
  await expectNoDocumentOverflow(page);
});
