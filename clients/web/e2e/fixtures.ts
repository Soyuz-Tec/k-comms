import { expect, test as base } from "@playwright/test";
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
