import { useEffect, useLayoutEffect, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router-dom";
import type { BootstrapInput, LoginInput } from "../../api";
import { Brand } from "../../components/Brand";
import { Field } from "../../components/Field";
import { browserName, errorText, stringValue } from "../../lib/format";
import { useSession } from "../../app/session";

export function AuthScreen() {
  const { api, setSession } = useSession();
  const [invitationToken] = useState(() => new URLSearchParams(window.location.search).get("invitation_token") || "");
  const [mode, setMode] = useState<"login" | "invite" | "bootstrap">(invitationToken ? "invite" : "login");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [bootstrapEnabled, setBootstrapEnabled] = useState(false);

  useLayoutEffect(() => {
    if (!invitationToken) return;
    const url = new URL(window.location.href);
    url.searchParams.delete("invitation_token");
    window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
  }, [invitationToken]);

  useEffect(() => {
    let current = true;
    api.status().then((status) => {
      if (current) setBootstrapEnabled(status.capabilities?.bootstrap === true);
    }).catch(() => undefined);
    return () => { current = false; };
  }, [api]);

  async function submitLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    const input: LoginInput = {
      tenant_slug: stringValue(values, "tenant_slug"),
      email: stringValue(values, "email"),
      password: stringValue(values, "password"),
      device: { name: browserName(), platform: "web" }
    };
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      setSession(await api.login(input));
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  async function submitBootstrap(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    const input: BootstrapInput = {
      tenant_name: stringValue(values, "tenant_name"),
      tenant_slug: stringValue(values, "tenant_slug"),
      display_name: stringValue(values, "display_name"),
      email: stringValue(values, "email"),
      password: stringValue(values, "password"),
      device_name: browserName(),
      device_platform: "web"
    };
    setBusy(true);
    setError(null);
    try {
      setSession(await api.bootstrap(input));
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  async function acceptInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    const password = stringValue(values, "password");
    if (password !== stringValue(values, "confirm_password")) return setError("Password confirmation does not match.");
    setBusy(true); setError(null);
    try {
      await api.acceptInvitation({ token: stringValue(values, "token"), display_name: stringValue(values, "display_name"), password });
      form.reset();
      setMode("login");
      setError(null);
      setNotice("Invitation accepted. Sign in with your workspace slug and new password.");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-story" aria-labelledby="welcome-title">
        <Brand />
        <div className="auth-story-copy">
          <span className="eyebrow light">Durable conversation infrastructure</span>
          <h1 id="welcome-title">
            Stay in sync,
            <br />even after the signal drops.
          </h1>
          <p>K-Comms keeps messages ordered, tenant-scoped, and ready to replay across every device.</p>
        </div>
        <ul className="feature-list" aria-label="Platform capabilities">
          <li><span>01</span> Durable ordered delivery</li>
          <li><span>02</span> Realtime reconnect and replay</li>
          <li><span>03</span> Safety-gated attachments</li>
        </ul>
      </section>

      <section className="auth-panel" aria-labelledby="auth-heading">
        <div className="auth-card">
          <span className="eyebrow">Welcome to K-Comms</span>
          <h2 id="auth-heading">{mode === "login" ? "Sign in to your workspace" : mode === "invite" ? "Accept your invitation" : "Create a development workspace"}</h2>
          <p className="muted">
            {mode === "login" ? "Use your workspace slug and account credentials." : mode === "invite" ? "Set your display name and a strong password, then sign in." : "Bootstrap must be enabled by the server administrator."}
          </p>

          <div className={`auth-tabs ${bootstrapEnabled ? "three-tabs" : ""}`} role="tablist" aria-label="Authentication options">
            <button type="button" role="tab" aria-selected={mode === "login"} onClick={() => setMode("login")}>Sign in</button>
            <button type="button" role="tab" aria-selected={mode === "invite"} onClick={() => setMode("invite")}>Accept invite</button>
            {bootstrapEnabled && <button type="button" role="tab" aria-selected={mode === "bootstrap"} onClick={() => setMode("bootstrap")}>Create workspace</button>}
          </div>

          {error && <div className="form-error" role="alert">{error}</div>}
          {notice && <div className="inline-notice" role="status">{notice}</div>}

          {mode === "login" ? (
            <form className="auth-form" onSubmit={(event) => void submitLogin(event)}>
              <Field label="Workspace slug" name="tenant_slug" autoComplete="organization" required />
              <Field label="Email address" name="email" type="email" autoComplete="username" required />
              <Field label="Password" name="password" type="password" autoComplete="current-password" required />
              <div className="auth-form-help"><Link to="/forgot-password">Forgot password?</Link></div>
              <button className="button primary full" type="submit" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
            </form>
          ) : mode === "invite" ? (
            <form className="auth-form" onSubmit={(event) => void acceptInvitation(event)}>
              <Field label="Invitation token" name="token" defaultValue={invitationToken} autoComplete="off" required />
              <Field label="Display name" name="display_name" maxLength={120} autoComplete="name" required />
              <Field label="Password" name="password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required />
              <Field label="Confirm password" name="confirm_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required />
              <button className="button primary full" type="submit" disabled={busy}>{busy ? "Accepting…" : "Accept invitation"}</button>
            </form>
          ) : (
            <form className="auth-form" onSubmit={(event) => void submitBootstrap(event)}>
              <div className="field-pair">
                <Field label="Workspace name" name="tenant_name" minLength={2} maxLength={120} autoComplete="organization" required />
                <Field label="Workspace slug" name="tenant_slug" minLength={2} maxLength={80} pattern="[a-z0-9-]+" title="Lowercase letters, numbers, and hyphens" required />
              </div>
              <Field label="Your name" name="display_name" maxLength={120} autoComplete="name" required />
              <Field label="Email address" name="email" type="email" autoComplete="username" required />
              <Field label="Password" name="password" type="password" minLength={12} maxLength={256} autoComplete="new-password" hint="At least 12 characters" required />
              <button className="button primary full" type="submit" disabled={busy}>{busy ? "Creating workspace…" : "Create development workspace"}</button>
            </form>
          )}
        </div>
      </section>
    </main>
  );
}
