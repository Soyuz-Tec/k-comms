import AxeBuilder from "@axe-core/playwright";
import { expect, mockServiceStatus, test } from "./fixtures";
import { expectMinimumTargets, expectNoDocumentOverflow, installWorkspace } from "./mobile-ui-support";
import type { WorkspaceDomainClaim } from "../src/types/workspaceDiscovery";

const claim: WorkspaceDomainClaim = {
  id: "ffffffff-ffff-4fff-8fff-ffffffffffff", domain: "team.example.org", version: 1, status: "pending", discovery_enabled: false,
  challenge_name: "_k-comms.team.example.org.", challenge_value: `k-comms-domain=synthetic-public-${"a".repeat(43)}`,
  challenge_expires_at: "2099-01-01T00:00:00Z", verified_at: null, proof_expires_at: null
};

for (const palette of ["light", "dark"] as const) {
  test(`explicit public discovery hands off only a workspace address on a phone in ${palette}`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 }); await page.emulateMedia({ colorScheme: palette });
    const requests: Array<{ path: string; body: unknown; authorization: string | undefined; origin: string | undefined }> = [];
    const unexpected: string[] = [];
    await page.route("**/api/v1/**", async (route) => {
      const request = route.request(); const path = new URL(request.url()).pathname;
      if (path === "/api/v1/status" && request.method() === "GET") return route.fulfill({ json: mockServiceStatus() });
      if (path === "/api/v1/telephony/config" && request.method() === "GET") return route.fulfill({ json: { data: { enabled: false, configured: false, provider: "livekit_sip", number: null, can_manage: false } } });
      if (path === "/api/v1/workspaces/discover" && request.method() === "POST") {
        requests.push({ path, body: request.postDataJSON(), authorization: request.headers().authorization, origin: request.headers().origin });
        return route.fulfill({ json: { data: { available: true, sign_in_path: "/sign-in?tenant_slug=example" } } });
      }
      unexpected.push(`${request.method()} ${path}`); return route.fulfill({ status: 501, json: { error: { code: "unmocked_endpoint", detail: "Unexpected endpoint" } } });
    });
    await page.goto("/sign-in?return_to=%2Fapp%2Ffiles");
    await page.getByLabel("Workspace address", { exact: true }).fill("old-workspace");
    await page.getByLabel("Email address", { exact: true }).fill("member@example.org");
    await page.getByLabel("Password", { exact: true }).fill("previous workspace password");
    await page.getByText("Find workspace by domain", { exact: true }).click();
    await page.getByLabel("Workspace domain", { exact: true }).fill("TEAM.EXAMPLE.ORG.");
    expect(requests).toHaveLength(0);
    await page.getByRole("button", { name: "Find workspace", exact: true }).click();
    await expect(page.getByRole("button", { name: "Use this workspace address" })).toBeVisible();
    await expect(page).toHaveURL(/\/sign-in\?return_to=/);
    await expectMinimumTargets(page.locator(".workspace-discovery button"), "Discovery actions");
    await page.getByRole("button", { name: "Use this workspace address" }).click();
    await expect(page).toHaveURL("/sign-in?tenant_slug=example");
    await expect(page.getByLabel("Password", { exact: true })).toHaveValue("");
    await expect(page.getByText(/discovery does not grant access/)).toBeVisible();
    expect(requests).toEqual([{ path: "/api/v1/workspaces/discover", body: { domain: "team.example.org" }, authorization: undefined, origin: new URL(page.url()).origin }]);
    await expectNoDocumentOverflow(page);
    expect((await new AxeBuilder({ page }).include(".workspace-discovery").analyze()).violations).toEqual([]);
    expect(unexpected).toEqual([]);
  });
}

test("admin preserves a stale opt-in intent, reloads CAS, and applies only the reviewed current version", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await page.emulateMedia({ colorScheme: "dark" });
  const state = await installWorkspace(page); let current = claim; const writes: unknown[] = [];
  await page.route("**/api/v1/admin/workspace-domains**", async (route) => {
    const request = route.request(); const path = new URL(request.url()).pathname;
    if (request.method() === "GET" && path === "/api/v1/admin/workspace-domains") return route.fulfill({ json: { data: [current], limits: { domains: 8 } } });
    if (request.method() === "PATCH" && path === `/api/v1/admin/workspace-domains/${claim.id}`) {
      const input = request.postDataJSON(); writes.push(input);
      if (writes.length === 1) { current = { ...claim, version: 7 }; return route.fulfill({ status: 409, json: { error: { code: "stale_version", detail: "Changed elsewhere" } } }); }
      current = { ...current, version: 8, discovery_enabled: true }; return route.fulfill({ json: { data: current } });
    }
    state.unexpectedRequests.push(`${request.method()} ${path}`); return route.fulfill({ status: 501 });
  });
  await page.goto("/admin?section=domains");
  await expect(page.getByRole("button", { name: "Domains", exact: true })).toHaveAttribute("aria-current", "page");
  await page.getByText("DNS TXT instructions for team.example.org", { exact: true }).click();
  await expect(page.getByText(claim.challenge_value!, { exact: true })).toBeVisible();
  await expectMinimumTargets(page.locator(".workspace-domain-actions button"), "Domain row actions");
  await expectNoDocumentOverflow(page);
  expect((await new AxeBuilder({ page }).include(".workspace-domains").analyze()).violations).toEqual([]);
  await page.getByRole("button", { name: "Enable discovery for team.example.org" }).click();
  const dialog = page.getByRole("alertdialog");
  await dialog.getByRole("button", { name: "Apply discovery setting" }).click();
  await expect(dialog).toContainText("Current version 7");
  expect(writes).toEqual([{ version: 1, discovery_enabled: true }]);
  await dialog.getByRole("button", { name: "Apply discovery setting" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes).toEqual([{ version: 1, discovery_enabled: true }, { version: 7, discovery_enabled: true }]);
  await expect(page.getByText("Public discovery: Opted in; awaiting a current proof lease.", { exact: true })).toBeVisible();
  expect(state.unexpectedRequests).toEqual([]);
});

test("admin removes TXT from the page before a step-up retry that loses access", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const state = await installWorkspace(page); let challenged = 0;
  await page.route("**/api/v1/admin/workspace-domains**", (route) => {
    const request = route.request(); const path = new URL(request.url()).pathname;
    if (request.method() === "GET" && path === "/api/v1/admin/workspace-domains") return route.fulfill({ json: { data: [claim], limits: { domains: 8 } } });
    if (request.method() === "POST" && path === `/api/v1/admin/workspace-domains/${claim.id}/challenge`) {
      expect(request.postDataJSON()).toEqual({ version: 1 }); challenged += 1;
      return route.fulfill({ status: challenged === 1 ? 428 : 403, json: { error: { code: challenged === 1 ? "step_up_required" : "forbidden", detail: "Current access required" } } });
    }
    state.unexpectedRequests.push(`${request.method()} ${path}`); return route.fulfill({ status: 501 });
  });
  await page.route("**/api/v1/me/step-up", (route) => route.fulfill({ json: { data: { step_up_at: "2026-10-05T00:00:00Z" } } }));
  await page.goto("/admin?section=domains");
  await page.getByText("DNS TXT instructions for team.example.org", { exact: true }).click();
  await expect(page.getByText(claim.challenge_value!, { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "New challenge for team.example.org" }).click();
  await page.getByRole("button", { name: "Create new challenge" }).click();
  const identity = page.getByRole("dialog", { name: "Confirm it is you" });
  await expect(identity).toBeVisible();
  await expect(page.getByText(claim.challenge_value!, { exact: true })).toHaveCount(0);
  await identity.getByLabel("Current password").fill("synthetic password");
  await identity.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByRole("heading", { name: claim.domain, exact: true })).toHaveCount(0);
  await expect(page.getByLabel("Domain", { exact: true })).toHaveCount(0);
  await expect(page.getByText(/unavailable with your current access/)).toBeVisible();
  expect(challenged).toBe(2); expect(state.unexpectedRequests).toEqual([]);
});

test("privileged verification paints above its retained action while preserving the proof and CAS", async ({ page }) => {
  const state = await installWorkspace(page);
  let current = claim;
  let verified = false;
  const writes: unknown[] = [];
  const proofs: unknown[] = [];
  await page.route("**/api/v1/admin/workspace-domains**", (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (request.method() === "GET" && path === "/api/v1/admin/workspace-domains") {
      return route.fulfill({ json: { data: [current], limits: { domains: 8 } } });
    }
    if (request.method() === "POST" && path === `/api/v1/admin/workspace-domains/${claim.id}/challenge`) {
      const input = request.postDataJSON();
      expect(input).toEqual({ version: 1 });
      writes.push(input);
      if (!verified) return route.fulfill({ status: 428, json: { error: { code: "step_up_required", detail: "Confirm it is you" } } });
      current = { ...claim, version: 2, challenge_value: "k-comms-domain=synthetic-current-after-proof" };
      return route.fulfill({ json: { data: current } });
    }
    state.unexpectedRequests.push(`${request.method()} ${path}`);
    return route.fulfill({ status: 501 });
  });
  await page.route("**/api/v1/me/step-up", (route) => {
    expect(route.request().method()).toBe("POST");
    const input = route.request().postDataJSON();
    expect(input).toEqual({ current_password: "synthetic password" });
    proofs.push(input);
    verified = true;
    return route.fulfill({ json: { data: { step_up_at: "2026-10-05T00:00:00Z" } } });
  });

  await page.goto("/admin?section=domains");
  await page.getByText("DNS TXT instructions for team.example.org", { exact: true }).click();
  await expect(page.getByText(claim.challenge_value!, { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "New challenge for team.example.org" }).click();
  await page.getByRole("button", { name: "Create new challenge" }).click();
  const identity = page.getByRole("dialog", { name: "Confirm it is you", exact: true });
  const actionBackdrop = page.locator("body > .modal-backdrop[data-action-dialog-backdrop]");
  await expect(identity).toBeVisible();
  await expect(actionBackdrop).toHaveCount(1);
  await expect(actionBackdrop).toHaveAttribute("aria-hidden", "true");
  expect(await actionBackdrop.evaluate(node => (node as HTMLElement).inert)).toBe(true);
  await expect(identity.getByLabel("Current password", { exact: true })).toBeFocused();
  await expect(page.getByText(claim.challenge_value!, { exact: true })).toHaveCount(0);
  expect(writes).toEqual([{ version: 1 }]);
  expect(proofs).toEqual([]);

  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    const layers = await identity.evaluate(dialog => {
      const proof = dialog.closest<HTMLElement>(".modal-backdrop");
      const action = document.querySelector<HTMLElement>("body > .modal-backdrop[data-action-dialog-backdrop]");
      if (!proof || !action) throw new Error("Both the proof and retained action backdrops must exist");
      const proofStyle = getComputedStyle(proof);
      const actionStyle = getComputedStyle(action);
      return {
        proofBodyPortal: proof.parentElement === document.body,
        actionBodyPortal: action.parentElement === document.body,
        proofPosition: proofStyle.position,
        actionPosition: actionStyle.position,
        proofZ: Number(proofStyle.zIndex),
        actionZ: Number(actionStyle.zIndex),
        proofInert: proof.inert
      };
    });
    expect(layers.proofBodyPortal).toBe(true);
    expect(layers.actionBodyPortal).toBe(true);
    expect(layers.proofPosition).toBe("fixed");
    expect(layers.actionPosition).toBe("fixed");
    expect(Number.isFinite(layers.proofZ)).toBe(true);
    expect(Number.isFinite(layers.actionZ)).toBe(true);
    expect(layers.proofZ).toBeGreaterThan(layers.actionZ);
    expect(layers.proofInert).toBe(false);
    await expectNoDocumentOverflow(page);
  }

  await identity.getByLabel("Current password", { exact: true }).fill("synthetic password");
  await identity.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(identity).toHaveCount(0);
  await expect(actionBackdrop).toHaveCount(0);
  await expect(page.getByText("Status: Awaiting DNS verification · Version 2.", { exact: true })).toBeVisible();
  expect(proofs).toEqual([{ current_password: "synthetic password" }]);
  expect(writes).toEqual([{ version: 1 }, { version: 1 }]);
  expect(state.unexpectedRequests).toEqual([]);
});
