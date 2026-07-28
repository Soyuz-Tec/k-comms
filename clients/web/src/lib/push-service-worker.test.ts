import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
// @ts-expect-error The static module is shipped verbatim as the browser service worker.
import { classifyRequestStrategy, isCacheableResponse, safeActionUrl, safeNotificationPayload } from "../../public/k-comms-sw.js";

describe("push service worker safety", () => {
  const origin = "https://comms.example.test";

  it("allows only same-origin application click-through targets", () => {
    expect(safeActionUrl("/app/?conversation=123", origin)).toBe(`${origin}/app/?conversation=123`);
    expect(safeActionUrl("https://evil.example/phish", origin)).toBe(`${origin}/app/`);
    expect(safeActionUrl("/admin", origin)).toBe(`${origin}/app/`);
    expect(safeActionUrl("javascript:alert(1)", origin)).toBe(`${origin}/app/`);
  });

  it("sanitizes provider copy and derives a safe message action", () => {
    const payload = safeNotificationPayload({
      title: " New\u0000mention ",
      body: "Open K-Comms",
      conversation_id: "2d228e4d-b3c7-4ccf-a6bd-cc39c1d44d40",
      message_id: "61087b18-14d3-446a-a208-5912d7ba72f4"
    }, origin);

    expect(payload.title).toBe("New mention");
    expect(payload.actionUrl).toBe(
      `${origin}/app/?conversation=2d228e4d-b3c7-4ccf-a6bd-cc39c1d44d40&message=61087b18-14d3-446a-a208-5912d7ba72f4`
    );
  });
});

describe("PWA request cache boundaries", () => {
  const origin = "https://comms.example.test";

  it("caches only the fixed offline shell and immutable same-origin bundles", () => {
    expect(classifyRequestStrategy(`${origin}/app/offline.html`, origin)).toBe("cache-first");
    expect(classifyRequestStrategy(`${origin}/app/manifest.webmanifest`, origin)).toBe("cache-first");
    expect(classifyRequestStrategy(`${origin}/app/icons/pwa-192.png`, origin)).toBe("cache-first");
    expect(classifyRequestStrategy(`${origin}/app/assets/index-A1b2C3d4.js`, origin)).toBe("cache-first");
    expect(classifyRequestStrategy(`${origin}/app/assets/index.js`, origin)).toBe("network-only");
  });

  it("uses network-first only for same-origin application navigations", () => {
    const navigation = {
      method: "GET",
      mode: "navigate",
      headers: new Headers({ accept: "text/html" }),
      url: `${origin}/app/you`
    };

    expect(classifyRequestStrategy(navigation, origin)).toBe("navigation-network-first");
    expect(
      classifyRequestStrategy(
        { ...navigation, url: `${origin}/app/files` },
        origin
      )
    ).toBe("navigation-network-first");
    expect(
      classifyRequestStrategy(
        { ...navigation, url: `${origin}/app/calls` },
        origin
      )
    ).toBe("navigation-network-first");
    expect(classifyRequestStrategy({ ...navigation, url: `${origin}/sign-in` }, origin)).toBe("network-only");
  });

  it.each([
    ["non-GET", { method: "POST", url: `${origin}/app/assets/index-A1b2C3d4.js` }],
    ["authorization", {
      method: "GET",
      headers: new Headers({ authorization: "Bearer secret" }),
      url: `${origin}/app/assets/index-A1b2C3d4.js`
    }],
    ["cross-origin", { method: "GET", url: "https://cdn.example.test/app/assets/index-A1b2C3d4.js" }],
    ["API", { method: "GET", url: `${origin}/api/v1/conversations` }],
    ["socket", { method: "GET", url: `${origin}/socket/websocket` }],
    ["messages", { method: "GET", url: `${origin}/app/messages/123` }],
    ["files", { method: "GET", url: `${origin}/app/files/123` }],
    ["attachments", { method: "GET", url: `${origin}/app/attachments/123` }],
    ["invites", { method: "GET", url: `${origin}/app/invites/123` }],
    ["calls", { method: "GET", url: `${origin}/app/calls/123` }],
    ["signed URL", { method: "GET", url: `${origin}/app/assets/index-A1b2C3d4.js?X-Amz-Signature=secret` }],
    ["access token", { method: "GET", url: `${origin}/app/assets/index-A1b2C3d4.js?access_token=secret` }],
    ["refresh token", { method: "GET", url: `${origin}/app/icons/pwa-192.png?refresh_token=secret` }],
    ["unknown query", { method: "GET", url: `${origin}/app/assets/index-A1b2C3d4.js?trace=123` }]
  ])("keeps %s requests network-only", (_label, request) => {
    expect(classifyRequestStrategy(request, origin)).toBe("network-only");
  });

  it("admits only exact successful static media types to Cache Storage", () => {
    const script = `${origin}/app/assets/index-A1b2C3d4.js`;
    const icon = `${origin}/app/icons/pwa-192.png`;

    expect(
      isCacheableResponse(
        script,
        new Response("export {}", {
          headers: { "content-type": "text/javascript; charset=utf-8" },
          status: 200
        }),
        origin
      )
    ).toBe(true);
    expect(
      isCacheableResponse(
        icon,
        new Response("", {
          headers: { "content-type": "image/png" },
          status: 200
        }),
        origin
      )
    ).toBe(true);
    expect(
      isCacheableResponse(
        script,
        new Response("<!doctype html>", {
          headers: { "content-type": "text/html" },
          status: 200
        }),
        origin
      )
    ).toBe(false);
    expect(
      isCacheableResponse(
        script,
        new Response("", {
          headers: { "content-type": "text/javascript" },
          status: 404
        }),
        origin
      )
    ).toBe(false);
    expect(
      isCacheableResponse(
        `${script}?access_token=secret`,
        new Response("", {
          headers: { "content-type": "text/javascript" },
          status: 200
        }),
        origin
      )
    ).toBe(false);
    expect(
      isCacheableResponse(
        script,
        {
          headers: new Headers({ "content-type": "text/javascript" }),
          status: 200,
          type: "opaque"
        },
        origin
      )
    ).toBe(false);
  });
});

describe("PWA manifest and launcher assets", () => {
  const publicPath = resolve(process.cwd(), "public");
  const manifest = JSON.parse(readFileSync(resolve(publicPath, "manifest.webmanifest"), "utf8")) as {
    id: string;
    start_url: string;
    scope: string;
    display: string;
    icons: Array<{ src: string; sizes: string; type: string; purpose: string }>;
    related_applications: unknown[];
    prefer_related_applications: boolean;
    screenshots?: unknown[];
  };

  it("installs directly from the web without related app-store listings", () => {
    expect(manifest).toMatchObject({
      id: "/",
      start_url: "/app/",
      scope: "/",
      display: "standalone",
      related_applications: [],
      prefer_related_applications: false
    });
    expect(manifest).not.toHaveProperty("screenshots");
  });

  it.each([
    ["/app/icons/pwa-192.png", 192, 192, "any"],
    ["/app/icons/pwa-512.png", 512, 512, "any"],
    ["/app/icons/pwa-maskable-512.png", 512, 512, "maskable"]
  ])("ships %s with exact manifest metadata and dimensions", (src, width, height, purpose) => {
    expect(manifest.icons).toContainEqual({
      src,
      sizes: `${width}x${height}`,
      type: "image/png",
      purpose
    });
    expect(pngDimensions(resolve(publicPath, src.replace("/app/", "")))).toEqual([width, height]);
  });

  it("ships the exact 180px Apple touch launcher asset", () => {
    expect(pngDimensions(resolve(publicPath, "icons/apple-touch-icon.png"))).toEqual([180, 180]);
  });
});

function pngDimensions(path: string): [number, number] {
  const image = readFileSync(path);
  expect(image.subarray(0, 8)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  return [image.readUInt32BE(16), image.readUInt32BE(20)];
}
