import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";

const conversationId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

async function mockWhiteboardWorkspace(page: Page) {
  const session = {
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    expires_in: 3_600,
    received_at: Date.now(),
    tenant: {
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      name: "Acme Workspace",
      slug: "acme",
      status: "active"
    },
    user: {
      id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      tenant_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      display_name: "Ada Lovelace",
      email: "ada@example.test",
      account_type: "human",
      role: "owner",
      platform_role: null,
      status: "active",
      version: 1
    },
    device: {
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      user_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      name: "Browser",
      platform: "web"
    }
  };
  const conversation = {
    id: conversationId,
    tenant_id: session.tenant.id,
    kind: "group",
    title: "Product planning",
    visibility: "private",
    latest_sequence: 0,
    last_read_sequence: 0,
    unread_count: 0,
    archived_at: null,
    version: 1,
    inserted_at: "2026-08-01T12:00:00Z",
    updated_at: "2026-08-01T12:00:00Z"
  };
  const operations: unknown[] = [];
  const writes: Array<{ kind: string; payload: { elements?: unknown[] } }> = [];
  const sentMessages: Array<Record<string, unknown>> = [];

  await page.addInitScript((value) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value));
    localStorage.setItem(
      `k-comms:onboarding:${value.tenant.id}:${value.user.id}`,
      "dismissed"
    );
  }, session);
  await page.route("**/api/v1/me", (route) =>
    route.fulfill({
      json: {
        tenant: session.tenant,
        user: session.user,
        device: session.device,
        capabilities: {
          allow_audio_calls: true,
          allow_video_calls: true,
          allow_public_channels: true,
          message_edit_window_seconds: 900,
          max_attachment_bytes: 25_000_000
        }
      }
    })
  );
  await page.route("**/api/v1/users", (route) =>
    route.fulfill({ json: { data: [session.user] } })
  );
  await page.route("**/api/v1/conversations", (route) =>
    route.fulfill({ json: { data: [conversation] } })
  );
  await page.route("**/api/v1/in-app-notifications?limit=50", (route) =>
    route.fulfill({
      json: {
        data: [],
        page: { limit: 50, has_more: false, next_cursor: null },
        meta: { unread_count: 0 }
      }
    })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/members`, (route) =>
    route.fulfill({ json: { data: [] } })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/messages**`, async (route) => {
    if (route.request().method() === "POST") {
      const body = route.request().postDataJSON() as Record<string, unknown>;
      sentMessages.push(body);
      await route.fulfill({
        status: 201,
        json: {
          data: {
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            tenant_id: session.tenant.id,
            conversation_id: conversationId,
            sender_user_id: session.user.id,
            sender_device_id: session.device.id,
            client_message_id: body.client_message_id,
            conversation_sequence: 1,
            body: body.body,
            metadata: body.metadata,
            status: "active",
            thread_root_message_id: null,
            thread_reply_count: 0,
            mentioned_user_ids: [],
            inserted_at: "2026-08-01T12:01:00Z",
            attachments: [],
            reactions: []
          }
        }
      });
      return;
    }
    await route.fulfill({
      json: { data: [], page: { has_more: false, next_after_sequence: null, reset_required: false } }
    });
  });
  await page.route(`**/api/v1/conversations/${conversationId}/delivery-cursors`, (route) =>
    route.fulfill({ json: { data: [] } })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/delivery-cursor`, (route) =>
    route.fulfill({ json: { data: { recipient_user_id: session.user.id, device_ref: "test-device", delivered_sequence: 1, read_sequence: 0, delivered_at: "2026-08-01T12:01:00Z", read_at: null } } })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/read-cursor`, (route) =>
    route.fulfill({ status: 204 })
  );
  await page.route(`**/api/v1/conversations/${conversationId}/call`, (route) =>
    route.fulfill({ json: { data: null } })
  );
  await page.route(
    `**/api/v1/conversations/${conversationId}/whiteboard/operations**`,
    async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          json: {
            data: operations,
            page: {
              has_more: false,
              next_after_sequence: operations.length
            }
          }
        });
        return;
      }

      const request = route.request();
      const body = request.postDataJSON() as {
        kind: "scene.update" | "board.clear";
        base_sequence?: number;
        payload: { elements?: unknown[] };
      };
      writes.push(body);
      const operation = {
        id: crypto.randomUUID(),
        whiteboard_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        tenant_id: session.tenant.id,
        conversation_id: conversationId,
        actor_user_id: session.user.id,
        client_operation_id: request.headers()["idempotency-key"],
        sequence: operations.length + 1,
        kind: body.kind,
        payload: body.payload,
        inserted_at: new Date().toISOString()
      };
      operations.push(operation);
      await route.fulfill({ status: 201, json: { data: operation } });
    }
  );

  return { operations, sentMessages, writes };
}

test("conversation whiteboard renders a usable white-labeled drawing workspace", async ({
  page
}) => {
  await mockWhiteboardWorkspace(page);
  await page.goto(`/app/whiteboard?conversation=${conversationId}`);

  await expect(page.getByRole("heading", { name: "Whiteboard" })).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Conversation" })).toHaveValue(conversationId);
  await expect(page.getByRole("link", { name: "Open conversation" })).toHaveAttribute(
    "href",
    `/app/?conversation=${conversationId}`
  );
  await expect(page.getByText("Offline editing", { exact: true })).toBeVisible();
  await expect(page.getByText("Saved", { exact: true })).toBeVisible();
  await expect(page.getByTestId("toolbar-rectangle")).toBeVisible();

  const drawingSurface = page.getByTestId("k-comms-drawing-surface");
  await expect(drawingSurface).not.toContainText(/Excalidraw/i);
  await expect(
    drawingSurface.locator(
      'a[href*="excalidraw"], a[href*="discord.gg/UexuTaE"]'
    )
  ).toHaveCount(0);

  const canvas = page.locator("canvas.excalidraw__canvas.interactive");
  await expect(canvas).toHaveCount(1);
  const pageBounds = await page.locator(".whiteboard-page").boundingBox();
  const room = page.getByRole("region", {
    name: "Whiteboard for Product planning"
  });
  const roomBounds = await room.boundingBox();
  const bounds = await canvas.boundingBox();
  expect(pageBounds).not.toBeNull();
  expect(roomBounds).not.toBeNull();
  expect(Math.abs((roomBounds?.x ?? 0) - (pageBounds?.x ?? 0))).toBeLessThanOrEqual(1);
  expect(Math.abs((roomBounds?.width ?? 0) - (pageBounds?.width ?? 0))).toBeLessThanOrEqual(1);
  expect(
    Math.abs(
      ((roomBounds?.y ?? 0) + (roomBounds?.height ?? 0)) -
        ((pageBounds?.y ?? 0) + (pageBounds?.height ?? 0))
    )
  ).toBeLessThanOrEqual(1);
  await expect(room).toHaveCSS("border-top-width", "0px");
  await expect(room).toHaveCSS("border-radius", "0px");
  await expect(room).toHaveCSS("box-shadow", "none");
  expect(bounds?.width).toBeGreaterThan(250);
  expect(bounds?.height).toBeGreaterThan(500);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth)
  ).toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth));
});

test("draw, durable replay, and clear-for-everyone complete in order", async ({
  page
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium", "one deterministic desktop workflow is sufficient");
  const fixture = await mockWhiteboardWorkspace(page);
  await page.goto(`/app/whiteboard?conversation=${conversationId}`);

  const rectangleTool = page.getByTestId("toolbar-rectangle");
  await expect(rectangleTool).toBeVisible();
  await page.getByTitle("Rectangle — R or 2").click();
  await expect(rectangleTool).toBeChecked();
  const canvas = page.locator("canvas.excalidraw__canvas.interactive");
  const bounds = await canvas.boundingBox();
  if (!bounds) throw new Error("whiteboard canvas has no render bounds");
  await page.mouse.move(bounds.x + 420, bounds.y + 210);
  await page.mouse.down();
  await page.mouse.move(bounds.x + 620, bounds.y + 350, { steps: 6 });
  await page.mouse.up();

  await expect.poll(() => fixture.writes.length).toBe(1);
  expect(fixture.writes[0].kind).toBe("scene.update");
  expect(fixture.writes[0].base_sequence).toBe(0);
  expect(fixture.writes[0].payload.elements).toEqual([
    expect.objectContaining({ type: "rectangle", isDeleted: false })
  ]);
  await expect(page.getByText("Saved", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Open canvas controls" }).click();
  const messageSelection = page.getByRole("button", { name: "Message selection" });
  await expect(messageSelection).toBeEnabled();
  await messageSelection.click();
  await expect(page.getByText("Whiteboard object", { exact: true })).toBeVisible();
  await page.getByRole("textbox", { name: "Message", exact: true }).fill("Review this shape");
  await page.getByRole("button", { name: /^Send/ }).click();

  await expect.poll(() => fixture.sentMessages.length).toBe(1);
  expect(fixture.sentMessages[0]).toMatchObject({
    body: "Review this shape",
    metadata: {
      whiteboard_reference: {
        board_sequence: 1,
        element_ids: [expect.any(String)],
        label: "Whiteboard object"
      }
    }
  });
  await expect(page).not.toHaveURL(/whiteboard_elements=/);

  await page.goto(`/app/whiteboard?conversation=${conversationId}`);
  await expect(page.getByTestId("toolbar-rectangle")).toBeVisible();
  expect(fixture.operations).toHaveLength(1);

  await page.getByRole("button", { name: "Open canvas controls" }).click();
  await page.getByRole("button", { name: "Clear canvas" }).click();
  const dialog = page.getByRole("alertdialog", {
    name: "Clear this canvas?"
  });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Clear canvas" }).click();

  await expect.poll(() => fixture.writes.length).toBe(2);
  expect(fixture.writes[1]).toEqual({ kind: "board.clear", payload: {} });
  await expect(page.getByText("Saved", { exact: true })).toBeVisible();
});
