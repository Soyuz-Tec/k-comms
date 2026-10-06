import { expect, test as base } from "@playwright/test";
import type { Page } from "@playwright/test";
import type { ServiceStatus } from "../src/types";

type ServiceCapabilities =
  NonNullable<ServiceStatus["capabilities"]>;

const secureCapabilities: ServiceCapabilities = {
  administration: true,
  attachment_scanning: true,
  audio_calls: true,
  bootstrap: false,
  guest_links: true,
  instant_rooms: true,
  notifications: true,
  push_notifications: true,
  realtime: false,
  secure_account_actions: true,
  secure_media_actions: true,
  video_calls: true,
  whiteboards: true,
  webhooks: true
};

export function mockServiceStatus(
  capabilities: Partial<ServiceCapabilities> = {}
): ServiceStatus {
  return {
    service: "k-comms",
    version: "0.3.0",
    status: "operational",
    node: "playwright@node",
    capabilities: {
      ...secureCapabilities,
      ...capabilities
    }
  };
}

export const test = base.extend({
  page: async ({ page }, use) => {
    // The persistent account control reads availability on every member route.
    // Specs that exercise policy changes install their own stateful handler.
    await page.route("**/api/v1/me/availability", (route) => route.request().method() === "GET"
      ? route.fulfill({ json: { data: { status: "available", presence_state: "available", presence_expires_at: null,
        dnd_until: null, dnd_schedule: {}, dnd_active: false, retry_at: null, timezone: "Etc/UTC" } } })
      : route.fallback());
    await page.route("**/api/v1/me/workspace", (route) => route.request().method() === "GET"
      ? route.fulfill({ json: { data: { version: 0, contacts: [], groups: [],
        onboarding: { dismissed_at: "2026-10-05T00:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: false },
        limits: { contacts: 500, groups: 20, members_per_group: 50 }, observed_at: "2026-10-05T00:00:00Z" } } })
      : route.fallback());
    await page.route("**/api/v1/telephony/config", (route) =>
      route.fulfill({ json: { data: { enabled: false, configured: false, provider: "livekit_sip", number: null, can_manage: false } } })
    );
    await page.route("**/api/v1/status", (route) =>
      route.fulfill({ json: mockServiceStatus() })
    );
    /*
     * The inbox polls for rooms with a call running so it can flag them.
     * Default to none; specs that care register their own route afterwards,
     * which Playwright matches first.
     */
    await page.route("**/api/v1/calls?**", (route) =>
      route.fulfill({
        json: { data: [], page: { limit: 100, has_more: false, next_cursor: null } }
      })
    );
    await use(page);
  }
});

export { expect };

/** Explicit transport for HTTP-mocked UI journeys against either Vite or dist.
 * This qualifies rendering and navigation only, never backend realtime delivery.
 * Install after a fixture's catch-all API route so tickets cannot fall through.
 */
export async function installSyntheticRealtime(page: Page) {
  await page.route("**/api/v1/socket-tickets", route => {
    expect(route.request().method()).toBe("POST");
    return route.fulfill({ json: { data: { ticket: "synthetic-ui-ticket", expires_in: 60 } } });
  });
  await page.routeWebSocket(/\/socket\/websocket(?:\?|$)/, socket => socket.onMessage(message => {
    const [joinRef, reference, topic, event] = JSON.parse(String(message)) as [string | null, string, string, string];
    if (["phx_join", "phx_leave", "heartbeat"].includes(event)) {
      socket.send(JSON.stringify([joinRef, reference, topic, "phx_reply", { status: "ok", response: {} }]));
    }
  }));
}
