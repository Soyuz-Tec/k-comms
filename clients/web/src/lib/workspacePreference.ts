const LAST_WORKSPACE_SLUG_KEY = "k-comms.last-workspace-slug.v1";
const WORKSPACE_SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export function readRememberedWorkspaceSlug(): string {
  try {
    const value = window.localStorage.getItem(LAST_WORKSPACE_SLUG_KEY)?.trim() || "";
    return validWorkspaceSlug(value) ? value : "";
  } catch {
    return "";
  }
}

export function rememberWorkspaceSlug(value: string): void {
  const slug = value.trim().toLowerCase();
  if (!validWorkspaceSlug(slug)) return;
  try {
    window.localStorage.setItem(LAST_WORKSPACE_SLUG_KEY, slug);
  } catch {
    // Remembering a non-secret convenience value must not block authentication.
  }
}

export function validWorkspaceSlug(value: string): boolean {
  return value.length >= 2 && value.length <= 80 && WORKSPACE_SLUG_PATTERN.test(value);
}
