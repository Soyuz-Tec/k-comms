import type { Session } from "../src/types";
import { expect, test } from "./fixtures";
import { expectNoDocumentOverflow, installWorkspace, tenantId, userId } from "./mobile-ui-support";

const verifiedSession: Session = {
  access_token: "synthetic-mfa-access", refresh_token: "synthetic-mfa-refresh", token_type: "Bearer", expires_in: 3600,
  tenant: { id: tenantId, name: "Acme Workspace", slug: "acme", status: "active" },
  user: { id: userId, tenant_id: tenantId, display_name: "Ada Lovelace", email: "ada@example.test", account_type: "human", role: "owner", status: "active", version: 1 },
  device: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", user_id: userId, name: "Browser", platform: "web" }
};

test("MFA sign-in keeps the browser signed out until an explicit proof succeeds", async ({ page }) => {
  const fixture = await installWorkspace(page);
  await page.addInitScript(() => sessionStorage.removeItem("k-comms.session.v1"));
  let passwordRequests = 0;
  const proofCodes: string[] = [];
  await page.route("**/api/v1/sessions", route => {
    passwordRequests += 1;
    expect(route.request().method()).toBe("POST");
    expect(route.request().headers()["authorization"]).toBeUndefined();
    return route.fulfill({ json: { mfa_required: true, challenge_token: "synthetic-memory-only-challenge", expires_in: 300 } });
  });
  await page.route("**/api/v1/auth/mfa", route => {
    const input = route.request().postDataJSON() as { challenge_token: string; code: string };
    expect(input.challenge_token).toBe("synthetic-memory-only-challenge");
    expect(route.request().headers()["authorization"]).toBeUndefined();
    proofCodes.push(input.code);
    return input.code === "654321"
      ? route.fulfill({ json: verifiedSession })
      : route.fulfill({ status: 401, json: { error: { code: "invalid_mfa_code", detail: "The authenticator code is invalid or already used." } } });
  });
  await page.goto("/sign-in");
  await page.getByLabel("Workspace address").fill("acme");
  await page.getByLabel("Email address").fill("ada@example.test");
  await page.getByLabel("Password", { exact: true }).fill("synthetic-password");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  const code = page.getByLabel("Authenticator or recovery code", { exact: true });
  await expect(code).toBeVisible();
  expect(await page.evaluate(() => sessionStorage.getItem("k-comms.session.v1"))).toBeNull();
  await expect(page.locator("body")).not.toContainText("synthetic-memory-only-challenge");
  await code.fill("111111");
  await page.getByRole("button", { name: "Verify and sign in" }).click();
  await expect(page.getByRole("alert")).toContainText("The authenticator code is invalid or already used.");
  expect(await page.evaluate(() => sessionStorage.getItem("k-comms.session.v1"))).toBeNull();
  await expect(page).toHaveURL(/\/sign-in$/);
  await code.fill("654321");
  await page.getByRole("button", { name: "Verify and sign in" }).click();
  await expect(page.getByRole("heading", { name: "Inbox", exact: true })).toBeVisible();
  expect(await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1") || "{}").access_token)).toBe("synthetic-mfa-access");
  expect(passwordRequests).toBe(1);
  expect(proofCodes).toEqual(["111111", "654321"]);
  expect(fixture.unexpectedRequests).toEqual([]);
});

test("a corporate step-up redirect preserves the current session and requires retrying the action after proof", async ({ page }) => {
  await installWorkspace(page);
  let sensitiveRequests = 0;
  await page.route("**/api/v1/admin/tenant", route => {
    if (route.request().method() !== "PATCH") return route.fallback();
    sensitiveRequests += 1;
    return route.fulfill({ status: 403, json: { error: { code: "step_up_required", detail: "Confirm it is you" } } });
  });
  await page.route("**/api/v1/me/oidc/step-up/start", route => {
    expect(route.request().postDataJSON()).toEqual({ tenant_slug: "acme", return_to: "/app/settings?section=security" });
    expect(route.request().headers()["authorization"]).toBe("Bearer access-token");
    return route.fulfill({ json: { authorization_url: "https://idp.example.test/authorize?state=synthetic-proof-state" } });
  });
  await page.route("https://idp.example.test/authorize?**", route => route.fulfill({ contentType: "text/html", body: "<!doctype html><title>Synthetic identity service</title><h1>Corporate verification requested</h1>" }));
  await page.goto("/admin?section=workspace");
  await page.getByLabel("Workspace name", { exact: true }).fill("Reviewed workspace name");
  await page.getByRole("button", { name: "Save workspace settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Confirm it is you" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText("After verification, return to this action and try again.")).toBeVisible();
  expect(sensitiveRequests).toBe(1);
  const existingAccessToken = await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1") || "{}").access_token);
  await dialog.getByRole("button", { name: "Verify with corporate sign in" }).click();
  await expect(page).toHaveURL("https://idp.example.test/authorize?state=synthetic-proof-state");
  await expect(page.getByRole("heading", { name: "Corporate verification requested" })).toBeVisible();
  // This origin cannot read the application's session. Return without an IdP
  // callback to prove a redirect itself did not replay the sensitive mutation.
  await page.goto("/admin?section=workspace");
  await expect(page.getByRole("heading", { name: "Workspace settings", exact: true })).toBeVisible();
  expect(sensitiveRequests).toBe(1);
  expect(await page.evaluate(() => JSON.parse(sessionStorage.getItem("k-comms.session.v1") || "{}").access_token)).toBe(existingAccessToken);
});

test("phone navigation reaches meetings and saved items through You while keeping five primary destinations", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const fixture = await installWorkspace(page);
  await page.goto("/app/");
  for (const destination of ["Meetings", "Saved items"]) {
    const primary = page.getByRole("navigation", { name: "Primary navigation" });
    await expect(primary.getByRole("link")).toHaveCount(5);
    await expect(primary.getByRole("link", { name: destination, exact: true })).toHaveCount(0);
    await primary.getByRole("link", { name: "You", exact: true }).click();
    await page.getByRole("navigation", { name: "Workspace", exact: true }).getByRole("link", { name: destination, exact: true }).click();
    await expect(page.getByRole("heading", { name: destination, exact: true })).toBeVisible();
    await expectNoDocumentOverflow(page);
  }
  expect(fixture.unexpectedRequests).toEqual([]);
});
