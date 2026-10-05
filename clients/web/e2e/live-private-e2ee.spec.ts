import { test, expect, type Browser, type BrowserContext, type Page, type APIRequestContext, type TestInfo } from "@playwright/test";

const enabled = process.env.K_COMMS_LIVE_PRIVATE_E2EE === "true";
// Recovery and authentication secrets must never enter trace/video artifacts.
test.use({ trace: "off", video: "off" });
test.describe("maintained Matrix Rust private-room protocol", () => {
  test.skip(!enabled, "Requires qualified disposable Synapse, a zero-device control principal and two fresh enrolled humans over HTTPS");
  test("real Rust encryption, SAS trust, unknown ACK, recovery, removal and poisoned control refusal", async ({ browser, request }, info) => {
    test.setTimeout(240_000);
    test.skip(info.project.name !== "chromium", "One serialized native protocol qualification owns the disposable identities");
    const ownerCredentials = credentials("OWNER"); const peerCredentials = credentials("PEER");
    const owner = await signIn(request, ownerCredentials, "Private owner device");
    const peer = await signIn(request, peerCredentials, "Private peer device");
    expect(peer.user.id).not.toBe(owner.user.id); expect(peer.tenant.id).toBe(owner.tenant.id);
    let ownerContext: BrowserContext | undefined; let peerContext: BrowserContext | undefined; let recoveredContext: BrowserContext | undefined;
    try {
      ownerContext = await context(browser, owner, info); peerContext = await context(browser, peer, info);
      const a = await ownerContext.newPage(); const b = await peerContext.newPage();
      const wire: Array<Record<string, unknown>> = []; let realZeroControlQuery = false;
      a.on("request", (sent) => { if (/\/private-rooms\/[^/]+\/events$/.test(new URL(sent.url()).pathname) && sent.method() === "POST") wire.push(sent.postDataJSON() as Record<string, unknown>); });
      const clientResponse = await request.post("/api/v1/me/matrix/session", { headers: auth(owner) }); expect(clientResponse.status()).toBe(200);
      const matrixSession = (await clientResponse.json()).data as { control_matrix_user_id: string };
      a.on("response", async (response) => {
        if (new URL(response.url()).pathname.endsWith("/keys/query") && response.ok()) {
          const keys = await response.json() as { device_keys?: Record<string, object>; master_keys?: Record<string, object> };
          if (Object.keys(keys.device_keys?.[matrixSession.control_matrix_user_id] || {}).length === 0 && !keys.master_keys?.[matrixSession.control_matrix_user_id]) realZeroControlQuery = true;
        }
      });
      const [ownerRecovery] = await Promise.all([setupIdentity(a, ownerCredentials.password), setupIdentity(b, peerCredentials.password)]);
      const roomId = crypto.randomUUID();
      const create = await request.post("/api/v1/private-rooms", { headers: auth(owner), data: { id: roomId, title: "Native private protocol gate", member_ids: [peer.user.id] } }); expect(create.status()).toBe(200);
      await Promise.all([choose(a, roomId), choose(b, roomId)]);
      await a.getByLabel("Encrypted message", { exact: true }).fill("SAS must precede room-key sharing"); await a.getByRole("button", { name: "Send encrypted message", exact: true }).click();
      await expect(a.getByRole("alert")).toContainText(/matching SAS|verified|Verify every/);
      expect(wire.length).toBe(0);
      await verifyPeers(a,b);
      await a.getByRole("button", { name: "Retry the same encrypted send" }).click();
      await expect(b.getByRole("listitem").filter({ hasText: "SAS must precede room-key sharing" })).toHaveCount(1, { timeout: 30_000 });
      await expect.poll(() => realZeroControlQuery).toBe(true);
      expect(JSON.stringify(wire)).not.toContain("SAS must precede room-key sharing"); expect(wire[0]?.content).toMatchObject({ algorithm: "m.megolm.v1.aes-sha2" });
      // Lose the successful real server ACK once, then retry exact ciphertext.
      let lostAck = false;
      await a.route("**/private-rooms/*/events", async (route) => {
        if (route.request().method() === "POST" && !lostAck) { const response = await route.fetch(); expect(response.status()).toBe(200); lostAck = true; await route.abort("failed"); } else await route.continue();
      });
      await a.getByLabel("Encrypted message", { exact: true }).fill("Unknown ACK stays idempotent"); await a.getByRole("button", { name: "Send encrypted message", exact: true }).click();
      await expect(a.getByRole("button", { name: "Retry the same encrypted send" })).toBeVisible(); await a.getByRole("button", { name: "Retry the same encrypted send" }).click();
      await expect(b.getByRole("listitem").filter({ hasText: "Unknown ACK stays idempotent" })).toHaveCount(1, { timeout: 30_000 });
      const retries = wire.filter((item) => item.transaction_id === wire.at(-1)?.transaction_id); expect(retries.length).toBeGreaterThan(1); expect(retries.every((item) => JSON.stringify(item.content) === JSON.stringify(retries[0]?.content))).toBe(true);
      await a.unroute("**/private-rooms/*/events");
      // New Matrix device restores the same public identity, never resets it.
      const recovered = await signIn(request,ownerCredentials,"Private recovered owner device"); recoveredContext = await context(browser,recovered,info); const recoveryPage = await recoveredContext.newPage();
      await unlock(recoveryPage); await recoveryPage.getByText("Set up or recover encryption", { exact: true }).click(); await recoveryPage.getByLabel("Existing recovery key", { exact: true }).fill(ownerRecovery); await recoveryPage.getByRole("button", { name: "Recover this identity and history" }).click();
      await choose(recoveryPage,roomId); await recoveryPage.getByRole("button",{name:"Load earlier encrypted history"}).click();
      await expect(recoveryPage.getByRole("listitem").filter({hasText:"Unknown ACK stays idempotent"})).toHaveCount(1,{timeout:30_000});
      // This injects a bad native keys response into the actual maintained SDK
      // boundary, rather than replacing SDK trust with a fake DTO implementation.
      await a.route("**/_matrix/client/v3/keys/query", async (route) => {
        const response = await route.fetch(); const payload = await response.json() as { device_keys?: Record<string, object> }; payload.device_keys ||= {}; payload.device_keys[matrixSession.control_matrix_user_id] = { maliciousControlDevice: {} }; await route.fulfill({ response, json: payload });
      });
      await a.getByLabel("Encrypted message", { exact: true }).fill("Control poisoning must block fresh send"); await a.getByRole("button", { name: "Send encrypted message", exact: true }).click();
      await expect(a.getByRole("alert")).toContainText(/Server control crypto identity appeared/,{timeout:30_000});
      await expect(a.getByRole("listitem")).toHaveCount(0); await expect(a.getByRole("button",{name:"Unlock encrypted device"})).toBeVisible();
      await a.unroute("**/_matrix/client/v3/keys/query");
      // Exact owner native ban excludes removed K/Matrix participant. Earlier
      // keys cannot be retracted; only future sends rotate the group session.
      const removal = await request.delete(`/api/v1/private-rooms/${roomId}/members/${peer.user.id}`,{headers:auth(owner),data:{membership_epoch:1}}); expect(removal.status()).toBe(200);
      const forbidden = await request.get(`/api/v1/private-rooms/${roomId}`,{headers:auth(peer)}); expect(forbidden.status()).toBe(403);
      await expect(b.getByRole("listitem")).toHaveCount(0,{timeout:30_000});
    } finally { await Promise.allSettled([ownerContext?.close(),peerContext?.close(),recoveredContext?.close()]); }
  });
});

type Credentials = { tenant_slug: string; email: string; password: string };
type Session = { access_token: string; tenant: { id: string }; user: { id: string }; device: { id: string }; received_at: number };
function credentials(kind: "OWNER"|"PEER"): Credentials {
  const tenant_slug=process.env.K_COMMS_LIVE_OWNER_TENANT_SLUG; const email=process.env[`K_COMMS_LIVE_PRIVATE_${kind}_EMAIL`]; const password=process.env[`K_COMMS_LIVE_PRIVATE_${kind}_PASSWORD`];
  if (!tenant_slug || !email || !password) throw new Error("Private native qualification requires two disposable actor credentials"); return {tenant_slug,email,password};
}
async function signIn(request:APIRequestContext,who:Credentials,name:string):Promise<Session>{const response=await request.post("/api/v1/sessions",{data:{...who,device:{name,platform:"playwright"}}});expect(response.status()).toBe(200);return {...await response.json(),received_at:Date.now()} as Session;}
function auth(s:Session){return {authorization:`Bearer ${s.access_token}`};}
async function context(browser:Browser,s:Session,info:TestInfo){const ctx=await browser.newContext({baseURL:String(info.project.use.baseURL)});await ctx.addInitScript((value)=>{sessionStorage.setItem("k-comms.session.v1",JSON.stringify(value));localStorage.setItem(`k-comms:onboarding:${value.tenant.id}:${value.user.id}`,"dismissed");},s);return ctx;}
async function unlock(page:Page){await page.goto("/app/private");await page.getByLabel("Local crypto-store password",{exact:true}).fill("disposable-store-password-2026");await page.getByRole("button",{name:"Unlock encrypted device"}).click();await expect(page.getByRole("button",{name:"Lock device",exact:true})).toBeVisible({timeout:30_000});}
async function setupIdentity(page:Page,password:string){await unlock(page);await page.getByText("Set up or recover encryption",{exact:true}).click();await page.getByRole("button",{name:"Set up a new identity and recovery key"}).click();const recovery=await page.getByLabel("Save this recovery key securely",{exact:true}).inputValue();expect(recovery.length).toBeGreaterThan(40);await page.getByRole("button",{name:"I saved the key; finish setup"}).click();await expect(page.getByRole("dialog",{name:"Confirm it is you"})).toBeVisible();await page.getByLabel("Current password",{exact:true}).fill(password);await page.getByRole("button",{name:"Continue",exact:true}).click();await expect(page.getByLabel("Save this recovery key securely",{exact:true})).toHaveCount(0,{timeout:30_000});return recovery;}
async function choose(page:Page,room:string){await page.goto(`/app/private?room=${room}`);await expect(page.getByRole("button",{name:/Native private protocol gate/})).toBeVisible();await page.getByLabel("Local crypto-store password",{exact:true}).fill("disposable-store-password-2026");await page.getByRole("button",{name:"Unlock encrypted device"}).click();await expect(page.getByLabel("Encrypted message",{exact:true})).toBeVisible({timeout:30_000});}
async function verifyPeers(a:Page,b:Page){await a.getByText("Verify participants and other devices",{exact:true}).click();await a.getByLabel("Participant",{exact:true}).selectOption((await b.locator('section[aria-label="Encrypted device"] code').first().textContent())!);await expect(a.getByLabel("Device",{exact:true}).locator("option")).not.toHaveCount(0);await a.getByRole("button",{name:"Request SAS verification"}).click();await expect(b.getByRole("dialog",{name:"Verify encryption identity"})).toBeVisible({timeout:30_000});await Promise.all([a.getByRole("button",{name:"Accept and show SAS"}).click(),b.getByRole("button",{name:"Accept and show SAS"}).click()]);await expect(a.locator(".private-sas")).toBeVisible({timeout:30_000});await expect(b.locator(".private-sas")).toBeVisible({timeout:30_000});expect(await a.locator(".private-sas").textContent()).toBe(await b.locator(".private-sas").textContent());await Promise.all([a.getByRole("button",{name:"Both devices show the same SAS"}).click(),b.getByRole("button",{name:"Both devices show the same SAS"}).click()]);await expect(a.getByRole("dialog",{name:"Verify encryption identity"})).toHaveCount(0,{timeout:30_000});}
