import { ApiError } from "../api/errors";
import { validWorkspaceSlug } from "./workspacePreference";
import type { WorkspaceDiscoveryResult } from "../types/workspaceDiscovery";

/** Only the exact canonical sign-in route supplied by this API is accepted. */
export function discoveredWorkspaceSlug(path: unknown): string | null {
  const prefix = "/sign-in?tenant_slug=";
  if (typeof path !== "string" || !path.startsWith(prefix)) return null;
  const slug = path.slice(prefix.length);
  return validWorkspaceSlug(slug) ? slug : null;
}

export function normalizeWorkspaceDiscovery(value: unknown): WorkspaceDiscoveryResult {
  if (value && typeof value === "object" && "available" in value && "sign_in_path" in value) {
    if (value.available === false && value.sign_in_path === null) return { available: false, sign_in_path: null };
    if (value.available === true && discoveredWorkspaceSlug(value.sign_in_path)) return { available: true, sign_in_path: value.sign_in_path as string };
  }
  throw new ApiError(502, "invalid_workspace_discovery", "Workspace discovery could not be verified. Enter the address from your invitation instead.");
}

/** Mirrors the advertised ASCII domain shape; the server owns DNS eligibility. */
export function canonicalWorkspaceDomain(value: string): string | null {
  if (value.length > 254) return null;
  const domain = value.toLowerCase().replace(/\.$/, "");
  const labels = domain.split(".");
  const last = labels.at(-1) || "";
  if (domain.length < 4 || domain.length > 253 || labels.length < 2 ||
      labels.some((label) => label.length < 1 || label.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)) ||
      !/^[a-z]{2,63}$|^xn--[a-z0-9-]{2,59}$/.test(last) ||
      ["local", "localhost", "invalid", "test", "example", "internal", "onion"].includes(last)) return null;
  return domain;
}
