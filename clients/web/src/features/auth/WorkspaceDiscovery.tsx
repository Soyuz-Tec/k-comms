import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import { useSession } from "../../app/session";
import { Field } from "../../components/Field";
import { canonicalWorkspaceDomain, discoveredWorkspaceSlug } from "../../lib/workspaceDiscovery";
import type { WorkspaceDiscoveryResult } from "../../types/workspaceDiscovery";
import "./WorkspaceDiscovery.css";

export function WorkspaceDiscovery({ api, disabled, onSelect }: {
  api: Pick<ApiClient, "discoverWorkspace">;
  disabled: boolean;
  onSelect: (path: string, slug: string) => void;
}) {
  const { session } = useSession();
  const scope = `${session?.tenant.id || ""}:${session?.user.id || ""}:${session?.device?.id || ""}:${session?.access_token || ""}`;
  const identity = useRef({ scope, serial: 0 });
  if (identity.current.scope !== scope) identity.current = { scope, serial: identity.current.serial + 1 };
  return <DiscoveryForm key={identity.current.serial} api={api} disabled={disabled} onSelect={onSelect} />;
}

function DiscoveryForm({ api, disabled, onSelect }: {
  api: Pick<ApiClient, "discoverWorkspace">; disabled: boolean; onSelect: (path: string, slug: string) => void;
}) {
  const [domain, setDomain] = useState("");
  const [result, setResult] = useState<WorkspaceDiscoveryResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const generation = useRef(0);
  const inFlight = useRef(false);
  useEffect(() => () => { generation.current += 1; }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (disabled || inFlight.current) return;
    const canonical = canonicalWorkspaceDomain(domain);
    if (!canonical) { setResult(null); setError("Enter an exact ASCII domain, such as team.example.org. Use a domain, not an email address or URL."); return; }
    const request = ++generation.current;
    inFlight.current = true; setBusy(true); setError(null); setResult(null);
    try {
      const value = await api.discoverWorkspace(canonical);
      if (request !== generation.current) return;
      if (value.available && !discoveredWorkspaceSlug(value.sign_in_path)) throw new Error("Untrusted sign-in route");
      setResult(value);
    } catch (reason: unknown) {
      if (request !== generation.current) return;
      setError(reason instanceof ApiError && reason.status === 429
        ? "Discovery is temporarily limited. Try later or use the workspace address from your invitation."
        : "Workspace discovery could not be checked right now. Use the workspace address from your invitation or try again.");
    } finally { if (request === generation.current) { inFlight.current = false; setBusy(false); } }
  }

  return <details className="workspace-discovery"><summary>Find workspace by domain</summary>
    <p>This finds an opted-in workspace sign-in hint. It does not check whether you have an account, enroll you or choose single sign-on.</p>
    <form aria-label="Find workspace by domain" onSubmit={(event) => void submit(event)} noValidate>
      <Field label="Workspace domain" name="workspace_domain" value={domain} maxLength={254} autoComplete="off" autoCapitalize="none" spellCheck={false} disabled={disabled}
        hint="Enter the exact domain. Subdomains are checked separately."
        onChange={(event) => { generation.current += 1; inFlight.current = false; setBusy(false); setResult(null); setError(null); setDomain(event.target.value); }} />
      <button type="submit" className="button secondary full" disabled={disabled || busy}>{busy ? "Checking domain…" : "Find workspace"}</button>
    </form>
    {error && <p role="alert">{error}</p>}
    {result && <div role="status">{result.available ? <>
      <p>A workspace sign-in hint is available. You still need your own authorized account.</p>
      <button type="button" className="button secondary full" disabled={disabled} onClick={() => {
        const slug = discoveredWorkspaceSlug(result.sign_in_path);
        if (slug) onSelect(result.sign_in_path, slug);
      }}>Use this workspace address</button>
    </> : <p>No sign-in hint is available. Use the workspace address from your invitation or ask an administrator.</p>}</div>}
  </details>;
}
