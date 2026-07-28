/* global self, URL, caches, fetch, Request, Response */

const APP_ROOT = "/app/";
const CACHE_PREFIX = "k-comms-pwa-";
const RELEASE_REVISION = "__K_COMMS_RELEASE_REVISION__";
const CACHE_NAME = `${CACHE_PREFIX}${RELEASE_REVISION}`;
const OFFLINE_URL = `${APP_ROOT}offline.html`;
const FIXED_OFFLINE_ASSETS = new Set([
  OFFLINE_URL,
  `${APP_ROOT}offline.css`,
  `${APP_ROOT}manifest.webmanifest`,
  `${APP_ROOT}icons/pwa-192.png`,
  `${APP_ROOT}icons/pwa-512.png`,
  `${APP_ROOT}icons/pwa-maskable-512.png`,
  `${APP_ROOT}icons/apple-touch-icon.png`
]);
const SENSITIVE_PATH_SEGMENTS = new Set([
  "api",
  "socket",
  "messages",
  "files",
  "attachments",
  "invites",
  "call",
  "calls"
]);
const SIGNED_QUERY_NAMES = new Set([
  "credential",
  "expires",
  "key-pair-id",
  "policy",
  "sig",
  "signature",
  "token"
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASHED_APP_ASSET = /^\/app\/assets\/[^/]+-[A-Za-z0-9_-]{8,}\.[A-Za-z0-9]+$/;
const STATIC_CONTENT_TYPES = new Map([
  [".avif", new Set(["image/avif"])],
  [".css", new Set(["text/css"])],
  [".gif", new Set(["image/gif"])],
  [".ico", new Set(["image/x-icon", "image/vnd.microsoft.icon"])],
  [".jpeg", new Set(["image/jpeg"])],
  [".jpg", new Set(["image/jpeg"])],
  [".js", new Set(["application/javascript", "text/javascript"])],
  [".json", new Set(["application/json"])],
  [".mjs", new Set(["application/javascript", "text/javascript"])],
  [".png", new Set(["image/png"])],
  [".svg", new Set(["image/svg+xml"])],
  [".wasm", new Set(["application/wasm"])],
  [".webp", new Set(["image/webp"])],
  [".woff", new Set(["application/font-woff", "font/woff"])],
  [".woff2", new Set(["font/woff2"])]
]);

export function classifyRequestStrategy(request, origin) {
  const method = typeof request === "string" ? "GET" : String(request?.method || "GET").toUpperCase();
  if (method !== "GET" || hasAuthorization(request)) return "network-only";

  let url;
  try {
    const candidate = typeof request === "string" ? request : request?.url;
    url = new URL(candidate, origin);
  } catch {
    return "network-only";
  }

  if (url.origin !== origin || hasSignedQuery(url.searchParams)) {
    return "network-only";
  }

  if (isAppNavigation(request, url)) return "navigation-network-first";
  if (hasSensitivePath(url.pathname)) return "network-only";
  if (
    url.search === "" &&
    (FIXED_OFFLINE_ASSETS.has(url.pathname) || isSupportedHashedAsset(url.pathname))
  ) {
    return "cache-first";
  }

  return "network-only";
}

function hasAuthorization(request) {
  if (typeof request === "string" || !request?.headers) return false;

  if (typeof request.headers.get === "function") {
    return Boolean(request.headers.get("authorization"));
  }

  return Object.entries(request.headers).some(
    ([name, value]) => name.toLowerCase() === "authorization" && Boolean(value)
  );
}

function hasSensitivePath(pathname) {
  return pathname
    .toLowerCase()
    .split("/")
    .filter(Boolean)
    .some((segment) => SENSITIVE_PATH_SEGMENTS.has(segment));
}

function hasSignedQuery(searchParams) {
  for (const name of searchParams.keys()) {
    const normalized = name.toLowerCase();
    if (
      SIGNED_QUERY_NAMES.has(normalized) ||
      normalized.endsWith("_token") ||
      normalized.endsWith("-token") ||
      normalized.startsWith("x-amz-") ||
      normalized.startsWith("x-goog-")
    ) {
      return true;
    }
  }
  return false;
}

function isAppNavigation(request, url) {
  if (!url.pathname.startsWith(APP_ROOT)) return false;
  if (typeof request === "string") return false;

  const accept = typeof request?.headers?.get === "function"
    ? request.headers.get("accept") || ""
    : "";
  return request?.mode === "navigate" || request?.destination === "document" || accept.includes("text/html");
}

function isSupportedHashedAsset(pathname) {
  return HASHED_APP_ASSET.test(pathname) && expectedContentTypes(pathname) !== null;
}

function expectedContentTypes(pathname) {
  if (pathname === OFFLINE_URL) return new Set(["text/html"]);
  if (pathname === `${APP_ROOT}offline.css`) return new Set(["text/css"]);
  if (pathname === `${APP_ROOT}manifest.webmanifest`) {
    return new Set(["application/manifest+json"]);
  }
  if (pathname.startsWith(`${APP_ROOT}icons/`) && pathname.endsWith(".png")) {
    return new Set(["image/png"]);
  }

  const extension = pathname.slice(pathname.lastIndexOf(".")).toLowerCase();
  return STATIC_CONTENT_TYPES.get(extension) || null;
}

export function isCacheableResponse(request, response, origin) {
  if (!response || response.status !== 200 || response.type === "opaque") {
    return false;
  }

  let url;
  try {
    url = new URL(typeof request === "string" ? request : request?.url, origin);
  } catch {
    return false;
  }

  if (
    classifyRequestStrategy(request, origin) !== "cache-first" ||
    url.origin !== origin
  ) {
    return false;
  }

  const allowed = expectedContentTypes(url.pathname);
  const actual = response.headers?.get?.("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    ?.toLowerCase();
  return Boolean(allowed && actual && allowed.has(actual));
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  if (cached && isCacheableResponse(request, cached, self.location.origin)) {
    return cached;
  }
  if (cached) await cache.delete(request);

  const response = await fetch(request);
  if (isCacheableResponse(request, response, self.location.origin)) {
    await cache.put(request, response.clone());
  }
  return response;
}

async function navigationNetworkFirst(request) {
  try {
    return await fetch(request);
  } catch {
    const cache = await caches.open(CACHE_NAME);
    const offline = await cache.match(OFFLINE_URL);
    if (offline) return offline;
    return new Response(
      "<!doctype html><html lang=\"en\"><title>Offline</title><main><h1>You are offline</h1><p>Reconnect and try again.</p></main>",
      { headers: { "Content-Type": "text/html; charset=utf-8" }, status: 503 }
    );
  }
}

async function precacheOfflineAssets() {
  const cache = await caches.open(CACHE_NAME);

  try {
    for (const asset of FIXED_OFFLINE_ASSETS) {
      const request = new Request(new URL(asset, self.location.origin), {
        cache: "no-store",
        credentials: "same-origin"
      });
      const response = await fetch(request);
      if (!isCacheableResponse(request, response, self.location.origin)) {
        throw new Error(`Refusing to precache invalid PWA asset: ${asset}`);
      }
      await cache.put(request, response.clone());
    }
  } catch (error) {
    await caches.delete(CACHE_NAME);
    throw error;
  }
}

export function safeActionUrl(candidate, origin) {
  const fallback = new URL(APP_ROOT, origin).toString();

  if (typeof candidate !== "string" || candidate.length === 0 || candidate.length > 2_048) {
    return fallback;
  }

  try {
    const url = new URL(candidate, origin);
    if (url.origin !== origin || !url.pathname.startsWith(APP_ROOT)) return fallback;
    url.username = "";
    url.password = "";
    url.hash = "";
    return url.toString();
  } catch {
    return fallback;
  }
}

export function safeNotificationPayload(value, origin) {
  const input = value && typeof value === "object" ? value : {};
  const conversationId = typeof input.conversation_id === "string" && UUID.test(input.conversation_id) ? input.conversation_id : null;
  const messageId = typeof input.message_id === "string" && UUID.test(input.message_id) ? input.message_id : null;
  const generatedAction = conversationId ? `${APP_ROOT}?conversation=${encodeURIComponent(conversationId)}${messageId ? `&message=${encodeURIComponent(messageId)}` : ""}` : APP_ROOT;

  return {
    title: safeText(input.title, "K-Comms", 120),
    body: safeText(input.body, "You have a new notification.", 500),
    actionUrl: safeActionUrl(typeof input.action_url === "string" ? input.action_url : generatedAction, origin),
    tag: messageId ? `message:${messageId}` : undefined
  };
}

function safeText(value, fallback, maxLength) {
  if (typeof value !== "string") return fallback;
  const normalized = Array.from(value, (character) => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127 ? " " : character;
  }).join("").trim();
  return normalized ? normalized.slice(0, maxLength) : fallback;
}

if (typeof self !== "undefined" && typeof self.addEventListener === "function") {
  self.addEventListener("install", (event) => {
    event.waitUntil(precacheOfflineAssets());
  });

  self.addEventListener("activate", (event) => {
    event.waitUntil(
      caches.keys()
        .then((names) => Promise.all(
          names
            .filter((name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
            .map((name) => caches.delete(name))
        ))
        .then(() => self.clients.claim())
    );
  });

  self.addEventListener("message", (event) => {
    if (event.data?.type === "SKIP_WAITING") {
      event.waitUntil(self.skipWaiting());
    }
  });

  self.addEventListener("fetch", (event) => {
    const strategy = classifyRequestStrategy(event.request, self.location.origin);
    if (strategy === "cache-first") {
      event.respondWith(cacheFirst(event.request));
    } else if (strategy === "navigation-network-first") {
      event.respondWith(navigationNetworkFirst(event.request));
    }
  });

  self.addEventListener("push", (event) => {
    let raw;
    try {
      raw = event.data ? event.data.json() : {};
    } catch {
      raw = {};
    }

    const payload = safeNotificationPayload(raw, self.location.origin);
    event.waitUntil(
      self.registration.showNotification(payload.title, {
        body: payload.body,
        data: { actionUrl: payload.actionUrl },
        tag: payload.tag
      })
    );
  });

  self.addEventListener("notificationclick", (event) => {
    event.notification.close();
    const actionUrl = safeActionUrl(event.notification.data && event.notification.data.actionUrl, self.location.origin);

    event.waitUntil(
      self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (windows) => {
        const existing = windows.find((client) => {
          try {
            return new URL(client.url).origin === self.location.origin;
          } catch {
            return false;
          }
        });

        if (existing) {
          if (typeof existing.navigate === "function") await existing.navigate(actionUrl);
          return existing.focus();
        }

        return self.clients.openWindow(actionUrl);
      })
    );
  });
}
