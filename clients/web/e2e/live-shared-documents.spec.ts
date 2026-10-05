import { expect, test, type APIRequestContext, type BrowserContext } from "@playwright/test";
import type { Session } from "../src/types";
const enabled = process.env.K_COMMS_LIVE_DOCUMENTS_E2E === "true";
test.describe("actual shared document collaboration", () => {
  test.skip(!enabled, "requires an isolated disposable qualification tenant and actual backend");
  test("two independent device sessions converge Unicode edits, reconnect replay and exact duplicate receipts", async ({ browser, request }, testInfo) => {
    test.setTimeout(120_000);
    test.skip(testInfo.project.name !== "chromium", "one desktop journey owns the actual disposable document");
    const first = await signIn(request, "Document editor one"), second = await signIn(request, "Document editor two");
    const conversations = await request.get("/api/v1/conversations", { headers: bearer(first) });
    expect(conversations.status()).toBe(200);
    const conversationId = (await conversations.json()).data[0].id as string;
    const created = await request.post(`/api/v1/conversations/${conversationId}/documents`, { headers: bearer(first), data: { title: "Actual collaborative notes", client_document_id: crypto.randomUUID() } });
    expect(created.status()).toBe(201);
    const document = (await created.json()).data;
    const contexts: BrowserContext[] = [];
    try {
      for (const session of [first, second]) {
        const context = await browser.newContext({ baseURL: String(testInfo.project.use.baseURL) });
        contexts.push(context);
        await context.addInitScript(value => sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value)), session);
      }
      const firstPage = await contexts[0]!.newPage(), secondPage = await contexts[1]!.newPage();
      const route = `/app/documents?conversation=${conversationId}&document=${document.id}`;
      await Promise.all([firstPage.goto(route), secondPage.goto(route)]);
      const editorOne = firstPage.getByRole("textbox", { name: "Shared document content" }), editorTwo = secondPage.getByRole("textbox", { name: "Shared document content" });
      await expect(editorOne).toBeVisible(); await expect(editorTwo).toBeVisible();
      await expect(firstPage.getByText(/All changes synced/)).toBeVisible(); await expect(secondPage.getByText(/All changes synced/)).toBeVisible();
      await editorOne.click(); await firstPage.keyboard.insertText("A😀é");
      await expect(editorTwo).toHaveText("A😀é");
      await Promise.all([editorOne.click().then(() => firstPage.keyboard.insertText("ONE")), editorTwo.click().then(() => secondPage.keyboard.insertText("TWO"))]);
      await expect.poll(async () => {
        const [left, right] = await Promise.all([editorOne.textContent(), editorTwo.textContent()]);
        return left === right && left?.includes("ONE") && left?.includes("TWO");
      }).toBe(true);
      const committedText = await editorOne.textContent();
      await secondPage.reload();
      await expect(editorTwo).toHaveText(committedText || "");
      const before = await request.get(`/api/v1/documents/${document.id}`, { headers: bearer(first) });
      const state = (await before.json()).data;
      const input = { client_operation_id: crypto.randomUUID(), generation: state.generation, base_version: state.version, kind: "edit",
        changes: [{ after_id: null, delete_ids: [], insert: "EXACT-ONCE " }] };
      const receipt = await request.post(`/api/v1/documents/${document.id}/operations`, { headers: bearer(first), data: input });
      const duplicate = await request.post(`/api/v1/documents/${document.id}/operations`, { headers: bearer(first), data: input });
      expect(receipt.status()).toBe(201); expect(duplicate.status()).toBe(200); expect(await duplicate.json()).toEqual(await receipt.json());
      await expect(editorOne).toContainText("EXACT-ONCE "); await expect(editorTwo).toContainText("EXACT-ONCE ");
      const snapshot = await request.get(`/api/v1/documents/${document.id}`, { headers: bearer(second) });
      expect((await snapshot.json()).data.content.match(/EXACT-ONCE/g)).toHaveLength(1);
      await firstPage.screenshot({ path: testInfo.outputPath("shared-documents-two-device.png"), fullPage: true });
    } finally { await Promise.all(contexts.map(context => context.close())); }
  });
});
async function signIn(request: APIRequestContext, name: string): Promise<Session> {
  const tenant_slug = process.env.K_COMMS_LIVE_OWNER_TENANT_SLUG, email = process.env.K_COMMS_LIVE_OWNER_EMAIL, password = process.env.K_COMMS_LIVE_OWNER_PASSWORD;
  if (!tenant_slug || !email || !password) throw new Error("Actual document qualification credentials are incomplete");
  const response = await request.post("/api/v1/sessions", { data: { tenant_slug, email, password, device: { name, platform: "playwright" } } });
  expect(response.status()).toBe(200); return { ...(await response.json()), received_at: Date.now() };
}
function bearer(session: Session) { return { authorization: `Bearer ${session.access_token}` }; }
