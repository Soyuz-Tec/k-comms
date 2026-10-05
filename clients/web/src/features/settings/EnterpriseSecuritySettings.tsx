import { useEffect, useState, type FormEvent } from "react";
import { useSession } from "../../app/session";
import { errorText } from "../../lib/format";
import type { IdentitySecurity, MfaEnrollment } from "../../types/enterpriseIdentity";

export function EnterpriseSecuritySettings() {
  const { api, session, transportPolicyReady, accountActionsAllowed } = useSession();
  const [security, setSecurity] = useState<IdentitySecurity | null>(null);
  const [enrollment, setEnrollment] = useState<MfaEnrollment | null>(null);
  const [codes, setCodes] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let current = true;
    if (typeof api.identitySecurity !== "function") return;
    api.identitySecurity().then((value) => current && setSecurity(value)).catch((reason: unknown) => current && setError(errorText(reason)));
    return () => { current = false; };
  }, [api]);
  async function action(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const submitter = (event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null;
    const operation = submitter?.value || "enroll";
    const password = String(data.get("verification_password") || "");
    const code = String(data.get("verification_code") || "").trim();
    if (!transportPolicyReady || !accountActionsAllowed) {
      setError("Use a secure connection before changing account security.");
      return;
    }
    setBusy(true); setError(null); setNotice(null); setCodes([]);
    try {
      if (operation === "confirm") {
        const result = await api.confirmMfa(code);
        setCodes(result.recovery_codes); setEnrollment(null);
        setNotice("Authenticator enabled. Other sessions were revoked. Store these recovery codes safely.");
      } else {
        if (security?.authentication_method !== "oidc") await api.stepUp(password, security?.mfa_enabled ? code : undefined);
        if (operation === "enroll") setEnrollment(await api.enrollMfa());
        if (operation === "disable") {
          // A distinct recovery code is required after step-up; a TOTP cannot be replayed.
          await api.disableMfa(String(data.get("action_code") || "").trim());
          setNotice("Authenticator disabled. Other sessions were revoked.");
        }
        if (operation === "recovery") {
          const result = await api.rotateMfaRecovery(String(data.get("action_code") || "").trim());
          setCodes(result.recovery_codes); setNotice("Recovery codes replaced. Previous codes and other sessions were revoked.");
        }
        if (operation === "link" && session) {
          const result = await api.linkOidc(session.tenant.slug);
          const url = corporateAuthorizationUrl(result.authorization_url);
          sessionStorage.setItem("kcomms:oidc-link", "1");
          window.location.assign(url.href);
        }
      }
      setSecurity(await api.identitySecurity());
      form.reset();
    } catch (reason: unknown) { setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  async function corporateStepUp() {
    if (!session) return;
    if (!transportPolicyReady || !accountActionsAllowed) {
      setError("Use a secure connection before verifying your corporate session.");
      return;
    }
    setBusy(true); setError(null);
    try {
      const result = await api.stepUpOidc(session.tenant.slug);
      const url = corporateAuthorizationUrl(result.authorization_url);
      sessionStorage.setItem("kcomms:oidc-link", "1");
      window.location.assign(url.href);
    } catch (reason: unknown) { setError(errorText(reason)); setBusy(false); }
  }
  return <section aria-labelledby="enterprise-security-title" className="settings-card enterprise-settings">
    <h2 id="enterprise-security-title">Authenticator and corporate sign in</h2>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    <p>{security?.mfa_enabled ? `Authenticator enabled · ${security.recovery_codes_remaining} recovery codes remaining` : "Use an authenticator app as an additional sign-in factor."}</p>
    {security?.authentication_method === "oidc" && <button className="button secondary" type="button" onClick={() => void corporateStepUp()} disabled={busy}>Verify corporate session</button>}
    <form onSubmit={action}>
      {!enrollment && security?.authentication_method !== "oidc" && <label className="field">Current password<input name="verification_password" type="password" autoComplete="current-password" required /></label>}
      {((security?.mfa_enabled && security?.authentication_method !== "oidc") || enrollment) && <label className="field">{enrollment ? "Authenticator code" : "Step-up authenticator or recovery code"}<input name="verification_code" autoComplete="one-time-code" required /></label>}
      {enrollment && <><p>Add this secret to your authenticator app:</p><code>{enrollment.secret}</code><p>Account: K-Comms ({session?.user.email})</p><button className="button primary" type="submit" value="confirm" disabled={busy}>Confirm authenticator</button></>}
      {!enrollment && !security?.mfa_enabled && <button className="button primary" type="submit" value="enroll" disabled={busy || !security}>Set up authenticator</button>}
      {!enrollment && security?.mfa_enabled && <>
        <label className="field">New authenticator or separate recovery code for the change<input name="action_code" autoComplete="off" /></label>
        <p>Use a different recovery code or wait for the next authenticator code after step-up.</p>
        <button className="button secondary" type="submit" value="recovery" disabled={busy}>Replace recovery codes</button>
        <button className="button secondary" type="submit" value="disable" disabled={busy}>Disable authenticator</button>
      </>}
      {!enrollment && <button className="button secondary" type="submit" value="link" disabled={busy}>Link corporate sign in</button>}
    </form>
    {codes.length > 0 && <div role="region" aria-label="New recovery codes"><p>Each code can be used once. These codes are shown only now.</p><pre>{codes.join("\n")}</pre><button className="button secondary" type="button" onClick={() => setCodes([])}>I have stored the codes</button></div>}
  </section>;
}

function corporateAuthorizationUrl(value: string): URL {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password) {
    throw new Error("Corporate sign in returned an invalid address.");
  }
  return url;
}
