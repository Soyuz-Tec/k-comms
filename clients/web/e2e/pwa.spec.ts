import { expect, test } from "./fixtures";

test.use({ serviceWorkers: "allow" });

test.describe("installable PWA runtime", () => {
  test("registers the app-scoped worker and exposes only the fixed offline shell", async ({
    browserName,
    context,
    page
  }) => {
    test.skip(browserName !== "chromium", "Cache Storage and offline worker proof runs once in Chromium");

    await page.addInitScript(() => {
      Object.defineProperty(window, "__notificationPermissionRequests", {
        configurable: true,
        value: 0,
        writable: true
      });
      if ("Notification" in window) {
        Object.defineProperty(Notification, "requestPermission", {
          configurable: true,
          value: () => {
            const state = window as typeof window & {
              __notificationPermissionRequests: number;
            };
            state.__notificationPermissionRequests += 1;
            return Promise.resolve("denied" as NotificationPermission);
          }
        });
      }
    });

    await page.goto("/app/");
    await expect(page.locator('link[rel="manifest"]')).toHaveAttribute(
      "href",
      "/app/manifest.webmanifest"
    );
    const manifest = await page.evaluate(async () =>
      fetch("/app/manifest.webmanifest").then((response) => response.json())
    );
    expect(manifest.display).toBe("standalone");
    expect(manifest.display_override).toEqual([
      "window-controls-overlay",
      "standalone"
    ]);

    const registration = await page.evaluate(async () => {
      const ready = await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) {
        await new Promise<void>((resolve) => {
          navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), {
            once: true
          });
        });
      }
      return {
        scope: ready.scope,
        scriptURL: ready.active?.scriptURL || ""
      };
    });

    expect(registration.scope).toBe(new URL("/app/", page.url()).toString());
    expect(registration.scriptURL).toContain(
      "/app/k-comms-sw.js?revision=development"
    );
    await expect
      .poll(() =>
        page.evaluate(
          () =>
            (window as typeof window & {
              __notificationPermissionRequests: number;
            }).__notificationPermissionRequests
        )
      )
      .toBe(0);

    const cacheSnapshot = await page.evaluate(async () => {
      const names = (await caches.keys()).filter((name) =>
        name.startsWith("k-comms-pwa-")
      );
      const urls = (
        await Promise.all(
          names.map(async (name) => {
            const cache = await caches.open(name);
            return (await cache.keys()).map((request) => request.url);
          })
        )
      ).flat();
      return { names, urls };
    });

    expect(cacheSnapshot.names).toEqual(["k-comms-pwa-__K_COMMS_RELEASE_REVISION__"]);
    expect(cacheSnapshot.urls).toHaveLength(7);
    for (const url of cacheSnapshot.urls) {
      const path = new URL(url).pathname;
      expect([
        "/app/offline.html",
        "/app/offline.css",
        "/app/manifest.webmanifest",
        "/app/icons/pwa-192.png",
        "/app/icons/pwa-512.png",
        "/app/icons/pwa-maskable-512.png",
        "/app/icons/apple-touch-icon.png"
      ]).toContain(path);
      expect(path).not.toMatch(/api|socket|message|file|attachment|invite|call/i);
    }

    await context.setOffline(true);
    await page.goto("/app/offline-proof");
    await expect(page.getByRole("heading", { name: "You are offline" })).toBeVisible();
    await expect(page.getByText("Messages and calls stay online-only.")).toBeVisible();
    await expect(page.locator("script")).toHaveCount(0);
    await context.setOffline(false);
  });
});
