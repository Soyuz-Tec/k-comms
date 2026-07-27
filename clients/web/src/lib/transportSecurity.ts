type BrowserLocation = Pick<Location, "hostname" | "protocol">;

export function isLoopbackHostname(hostname: string): boolean {
  const normalized = hostname
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, "");

  return (
    normalized === "localhost" ||
    normalized === "::1" ||
    normalized.endsWith(".localhost") ||
    /^127(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

export function isInsecureNonLoopbackOrigin(
  location: BrowserLocation = window.location
): boolean {
  return (
    location.protocol !== "https:" &&
    !isLoopbackHostname(location.hostname)
  );
}

export function isEncryptedUrl(value: string): boolean {
  try {
    return new URL(value, window.location.href).protocol === "https:";
  } catch {
    return false;
  }
}
