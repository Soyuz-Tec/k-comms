const memberPaths = new Set([
  "/app/", "/app/calls", "/app/calls/phone", "/app/directory",
  "/app/files", "/app/whiteboard", "/app/private", "/app/you", "/app/settings", "/app/meetings", "/app/artifacts", "/app/saved", "/admin", "/ops"
]);
const returnParameters = new Set([
  "conversation", "message", "search_message", "search_sequence", "call", "file",
  "focus_elements", "whiteboard_elements", "whiteboard_sequence", "whiteboard_label",
  "section", "tab", "search", "query", "compose", "q", "meeting", "occurrence", "artifact", "room"
]);

export interface AuthenticationReturnState {
  returnTo: string;
  guestToken?: string;
  guestShareUrl?: string;
}

/** Only known application routes and non-credential navigation fields survive login. */
export function safeMemberReturnTarget(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 4096 || !value.startsWith("/") ||
      value.startsWith("//") || value.includes("\\") ||
      [...value].some((character) => character.charCodeAt(0) <= 32 || character.charCodeAt(0) === 127)) return null;
  const url = new URL(value, "https://navigation.invalid");
  const path = url.pathname === "/app" ? "/app/" : url.pathname.replace(/\/$/, "");
  const canonicalPath = path === "/app" ? "/app/" : path;
  // Reject normalized traversal as well as unrecognized/encoded route paths.
  if ((value.split(/[?#]/, 1)[0] || "").replace(/\/$/, "") !== url.pathname.replace(/\/$/, "") ||
      !memberPaths.has(canonicalPath)) return null;
  const query = new URLSearchParams();
  for (const [name, parameter] of url.searchParams) {
    if (returnParameters.has(name) && parameter.length <= 512 &&
        ![...parameter].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)) query.set(name, parameter);
  }
  const fragment = /^#[a-z][a-z0-9-]{0,80}$/i.test(url.hash) ? url.hash : "";
  return `${canonicalPath}${query.size ? `?${query}` : ""}${fragment}`;
}

export function guestContinuationState(value: unknown): AuthenticationReturnState | undefined {
  if (!value || typeof value !== "object" || !("returnTo" in value) || value.returnTo !== "/join") return;
  const token = "guestToken" in value && typeof value.guestToken === "string" &&
    /^[A-Za-z0-9._~-]{1,512}$/.test(value.guestToken) ? value.guestToken : undefined;
  let shareUrl: string | undefined;
  if (token && "guestShareUrl" in value && typeof value.guestShareUrl === "string" && value.guestShareUrl.length <= 4096) {
    try {
      const url = new URL(value.guestShareUrl);
      if (url.origin === window.location.origin && url.pathname.replace(/\/$/, "") === "/join" &&
          !url.username && !url.password && !url.searchParams.has("token") &&
          new URLSearchParams(url.hash.slice(1)).get("guest") === token) shareUrl = value.guestShareUrl;
    } catch { /* An invalid handoff never becomes a navigation URL. */ }
  }
  return { returnTo: "/join", ...(token ? { guestToken: token } : {}), ...(shareUrl ? { guestShareUrl: shareUrl } : {}) };
}

export function authenticationReturnTarget(search: string, state?: unknown): string {
  if (guestContinuationState(state)) return "/join";
  const stateTarget = state && typeof state === "object" && "returnTo" in state
    ? safeMemberReturnTarget(state.returnTo) : null;
  const source = new URLSearchParams(search);
  return stateTarget || safeMemberReturnTarget(source.get("return_to")) ||
    safeMemberReturnTarget(`/app/${search}`) || "/app/";
}

export function authenticationReturnState(search: string, state?: unknown): AuthenticationReturnState {
  return guestContinuationState(state) || { returnTo: authenticationReturnTarget(search, state) };
}
