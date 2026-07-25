import { expect, test } from "@playwright/test";
import type { Page, Route } from "@playwright/test";

test("production capability keeps the default page focused on sign-in", async ({ page }) => {
  await page.route("**/api/v1/status", (route) => route.fulfill({
    json: serviceStatus(false)
  }));
  await page.goto("/sign-in");

  const heading = page.getByRole("heading", { name: "Sign in to your workspace" });
  await expect(heading).toBeVisible();
  await expect(heading).toBeFocused();
  await expect.poll(() => heading.evaluate((element) =>
    window.getComputedStyle(element).outlineStyle
  )).toBe("none");
  await expect(page.getByRole("tablist")).toHaveCount(0);
  await expect(page.getByRole("group", { name: "Other ways to continue" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Use invitation code" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Create workspace" })).toHaveCount(0);

  await page.keyboard.press("Tab");
  const workspace = page.getByLabel("Workspace address");
  await expect(workspace).toBeFocused();
  await expect.poll(() => workspace.evaluate((element) => {
    const style = window.getComputedStyle(element);
    return style.outlineStyle !== "none" && Number.parseFloat(style.outlineWidth) > 0;
  })).toBe(true);

  await page.goto("/app/?setup=workspace");
  await expect(
    page.getByText("Workspace creation is not available on this deployment.")
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Create workspace" })).toHaveCount(0);
});

test("returning member signs in with one submitted form and reaches Inbox", async ({ page }) => {
  const fixture = await installAuthApi(page);
  await page.addInitScript(() => {
    localStorage.setItem("k-comms.last-workspace-slug.v1", "acme");
  });
  await page.goto("/sign-in");

  await expect(page.getByText("acme", { exact: true })).toBeVisible();
  await page.getByLabel("Email address").fill("taylor@example.test");
  await page.getByLabel("Password", { exact: true }).fill("correct horse battery staple");
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
  await expect.poll(() =>
    page.evaluate(() => localStorage.getItem("k-comms.last-workspace-slug.v1"))
  ).toBe("acme");
  expect(fixture.loginRequests).toEqual([{
    tenant_slug: "acme",
    email: "taylor@example.test",
    password: "correct horse battery staple",
    device: expect.objectContaining({ platform: "web" })
  }]);
  expect(fixture.unexpectedRequests).toEqual([]);
});

test("invited member uses two fields and one submit to reach Inbox", async ({ page }) => {
  const fixture = await installAuthApi(page);
  await page.goto("/app/#invitation_token=single-use-token&tenant_slug=acme");

  await expect(page.getByRole("heading", { name: "Join your workspace" })).toBeVisible();
  await expect(page.getByLabel("Invitation code")).toHaveCount(0);
  await expect(page.getByLabel("Confirm password")).toHaveCount(0);
  await expect(page).not.toHaveURL(/invitation_token/);
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain("single-use-token");

  await page.getByLabel("Your name").fill("Taylor Member");
  await page.getByLabel("Create password", { exact: true }).fill("correct horse battery staple");
  await page.getByRole("button", { name: "Join workspace" }).click();

  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
  expect(fixture.invitationRequests).toEqual([{
    token: "single-use-token",
    display_name: "Taylor Member",
    password: "correct horse battery staple"
  }]);
  expect(fixture.loginRequests).toHaveLength(1);
  expect(fixture.unexpectedRequests).toEqual([]);
});

test("authorized setup derives the workspace address and enters the app in one form", async ({ page }) => {
  const fixture = await installAuthApi(page, { bootstrapEnabled: true, role: "owner" });
  await page.goto("/app/?setup=workspace");

  await expect(page.getByRole("heading", { name: "Create your workspace" })).toBeVisible();
  await page.getByLabel("Workspace name").fill("North Star Team");
  await expect(page.getByLabel("Workspace address")).toHaveValue("north-star-team");
  await page.getByText("Customize workspace address").click();
  await page.getByLabel("Workspace address").fill("north-star-ops");
  await page.getByLabel("Your name").fill("Taylor Owner");
  await page.getByLabel("Work email").fill("owner@example.test");
  await page.getByLabel("Create password", { exact: true }).fill("correct horse battery staple");
  await page.getByRole("button", { name: "Create workspace" }).click();

  await expect(page.getByRole("heading", { name: "Inbox" })).toBeVisible();
  expect(fixture.bootstrapRequests).toEqual([{
    tenant_name: "North Star Team",
    tenant_slug: "north-star-ops",
    display_name: "Taylor Owner",
    email: "owner@example.test",
    password: "correct horse battery staple",
    device_name: expect.any(String),
    device_platform: "web"
  }]);
  expect(fixture.unexpectedRequests).toEqual([]);
});

async function installAuthApi(
  page: Page,
  options: { bootstrapEnabled?: boolean; role?: "member" | "owner" } = {}
) {
  const role = options.role || "member";
  const tenant = {
    id: "11111111-1111-4111-8111-111111111111",
    name: "Acme",
    slug: "acme",
    status: "active"
  };
  const user = {
    id: "22222222-2222-4222-8222-222222222222",
    tenant_id: tenant.id,
    display_name: role === "owner" ? "Taylor Owner" : "Taylor Member",
    email: role === "owner" ? "owner@example.test" : "taylor@example.test",
    account_type: "human",
    role,
    status: "active",
    version: 1
  };
  const device = {
    id: "33333333-3333-4333-8333-333333333333",
    user_id: user.id,
    name: "Browser",
    platform: "web"
  };
  const capabilities = {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_public_channels: true,
    message_edit_window_seconds: 900,
    max_attachment_bytes: 25_000_000
  };
  const general = {
    id: "44444444-4444-4444-8444-444444444444",
    tenant_id: tenant.id,
    kind: "channel",
    title: "General",
    counterpart_display_name: null,
    visibility: "tenant",
    latest_sequence: 0,
    unread_count: 0,
    last_read_sequence: 0,
    version: 1,
    inserted_at: "2026-07-24T00:00:00Z",
    updated_at: "2026-07-24T00:00:00Z"
  };
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 900,
    tenant,
    user,
    device
  };
  const state = {
    loginRequests: [] as unknown[],
    invitationRequests: [] as unknown[],
    bootstrapRequests: [] as unknown[],
    unexpectedRequests: [] as string[]
  };

  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (method === "GET" && path === "/api/v1/status") {
      return json(route, serviceStatus(options.bootstrapEnabled === true));
    }
    if (method === "POST" && path === "/api/v1/sessions") {
      state.loginRequests.push(request.postDataJSON());
      return json(route, session, 201);
    }
    if (method === "POST" && path === "/api/v1/invitations/accept") {
      state.invitationRequests.push(request.postDataJSON());
      return json(route, { data: user }, 201);
    }
    if (method === "POST" && path === "/api/v1/bootstrap") {
      state.bootstrapRequests.push(request.postDataJSON());
      return json(route, { ...session, conversation: general }, 201);
    }
    if (method === "GET" && path === "/api/v1/me") {
      return json(route, { tenant, user, device, capabilities });
    }
    if (method === "GET" && path === "/api/v1/users") {
      return json(route, { data: [user] });
    }
    if (method === "GET" && path === "/api/v1/conversations") {
      return json(route, { data: [general] });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/members$/.test(path)) {
      return json(route, {
        data: [{
          id: "55555555-5555-4555-8555-555555555555",
          role: "owner",
          joined_at: "2026-07-24T00:00:00Z",
          last_read_sequence: 0,
          user
        }]
      });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/messages$/.test(path)) {
      return json(route, {
        data: [],
        page: { has_more: false, next_after_sequence: null, reset_required: false }
      });
    }
    if (method === "GET" && /^\/api\/v1\/conversations\/[^/]+\/call$/.test(path)) {
      return json(route, { data: null });
    }
    if (method === "PUT" && /^\/api\/v1\/conversations\/[^/]+\/read-cursor$/.test(path)) {
      return route.fulfill({ status: 204 });
    }
    if (method === "GET" && path === "/api/v1/in-app-notifications") {
      return json(route, {
        data: [],
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: 0 }
      });
    }

    state.unexpectedRequests.push(`${method} ${path}`);
    return json(route, { error: { code: "unexpected_request", detail: `${method} ${path}` } }, 501);
  });

  return state;
}

function serviceStatus(bootstrap: boolean) {
  return {
    service: "k-comms",
    version: "0.3.0",
    status: "operational",
    capabilities: {
      administration: true,
      attachment_scanning: true,
      audio_calls: true,
      bootstrap,
      notifications: true,
      realtime: false,
      video_calls: true,
      webhooks: true
    }
  };
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body)
  });
}
