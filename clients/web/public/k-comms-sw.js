/* global self, URL */

const APP_ROOT = "/app/";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
