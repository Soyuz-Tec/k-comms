export function buildGuestJoinUrl(
  token: string,
  origin = window.location.origin
): string {
  const url = new URL("/join", origin);
  url.hash = new URLSearchParams({ guest: token }).toString();
  return url.toString();
}

export function guestTokenFromFragment(
  location: Location = window.location
): string | null {
  const fragment = location.hash.startsWith("#")
    ? location.hash.slice(1)
    : location.hash;
  return new URLSearchParams(fragment).get("guest")?.trim() || null;
}

export function scrubGuestTokenFragment(
  location: Location = window.location,
  history: History = window.history
): void {
  const fragment = location.hash.startsWith("#")
    ? location.hash.slice(1)
    : location.hash;
  if (!new URLSearchParams(fragment).has("guest")) return;

  history.replaceState(
    history.state,
    "",
    `${location.pathname}${location.search}`
  );
}

export async function copyGuestUrl(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const field = document.createElement("textarea");
  field.value = value;
  field.readOnly = true;
  field.setAttribute("aria-hidden", "true");
  field.style.position = "fixed";
  field.style.opacity = "0";
  document.body.append(field);
  field.select();
  try {
    if (!document.execCommand("copy")) {
      throw new Error("Copy was not accepted by this browser.");
    }
  } finally {
    field.remove();
  }
}

export async function shareGuestUrl(value: string): Promise<"shared" | "copied" | "cancelled"> {
  if (navigator.share) {
    try {
      await navigator.share({
        title: "Join me on K-Comms",
        text: "Open this private K-Comms guest room link.",
        url: value
      });
      return "shared";
    } catch (reason: unknown) {
      if (reason instanceof DOMException && reason.name === "AbortError") {
        return "cancelled";
      }
      // A platform share sheet can fail after feature detection. Copying keeps
      // the user's single action useful without exposing the token elsewhere.
    }
  }

  await copyGuestUrl(value);
  return "copied";
}
