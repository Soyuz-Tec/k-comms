import { useEffect, useLayoutEffect, useState } from "react";
import type { FormEvent, InputHTMLAttributes } from "react";
import { Link, useNavigate } from "react-router";
import type { BootstrapInput, LoginInput } from "../../api";
import { Brand } from "../../components/Brand";
import { Field } from "../../components/Field";
import { browserName, errorText, stringValue } from "../../lib/format";
import {
  readRememberedWorkspaceSlug,
  validWorkspaceSlug
} from "../../lib/workspacePreference";
import { useSession } from "../../app/session";

type AuthMode = "login" | "invite" | "bootstrap";
type BootstrapAvailability = "checking" | "enabled" | "disabled" | "unavailable";

export function AuthScreen() {
  const { api, setSession } = useSession();
  const navigate = useNavigate();
  const [invitationContext] = useState(readInvitationContext);
  const [bootstrapRequested] = useState(readBootstrapRequest);
  const [invitationToken, setInvitationToken] = useState(invitationContext.token);
  const initialWorkspaceSlug =
    invitationContext.tenantSlug || readRememberedWorkspaceSlug();
  const [mode, setMode] = useState<AuthMode>(
    invitationToken ? "invite" : bootstrapRequested ? "bootstrap" : "login"
  );
  const [loginWorkspaceSlug, setLoginWorkspaceSlug] = useState(initialWorkspaceSlug);
  const [loginEmail, setLoginEmail] = useState("");
  const [editingWorkspace, setEditingWorkspace] = useState(!initialWorkspaceSlug);
  const [workspaceName, setWorkspaceName] = useState("");
  const [workspaceSlug, setWorkspaceSlug] = useState("");
  const [workspaceSlugEdited, setWorkspaceSlugEdited] = useState(false);
  const [customizeWorkspaceSlug, setCustomizeWorkspaceSlug] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [bootstrapAvailability, setBootstrapAvailability] =
    useState<BootstrapAvailability>("checking");
  const [statusAttempt, setStatusAttempt] = useState(0);

  useLayoutEffect(() => {
    if (!invitationToken) return;
    const url = new URL(window.location.href);
    url.searchParams.delete("invitation_token");
    const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
    hash.delete("invitation_token");
    url.hash = hash.toString();
    navigate(`${url.pathname}${url.search}${url.hash}`, { replace: true });
  }, [invitationToken, navigate]);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      const heading = document.getElementById("auth-heading");
      const activeElement = document.activeElement;
      const userAlreadyFocusedControl =
        activeElement instanceof HTMLElement &&
        activeElement.matches("input, select, textarea, button, a[href]");
      if (heading && !userAlreadyFocusedControl) {
        const hadTabIndex = heading.hasAttribute("tabindex");
        if (!hadTabIndex) heading.setAttribute("tabindex", "-1");
        heading.focus({ preventScroll: true });
        if (!hadTabIndex) {
          heading.addEventListener(
            "blur",
            () => heading.removeAttribute("tabindex"),
            { once: true }
          );
        }
      }
      document.title = `${authModeTitle(mode)} | K-Comms`;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [mode]);

  useEffect(() => {
    let current = true;
    setBootstrapAvailability("checking");
    api.status().then((status) => {
      if (!current) return;
      setBootstrapAvailability(
        status.capabilities?.bootstrap === true ? "enabled" : "disabled"
      );
    }).catch(() => {
      if (current) setBootstrapAvailability("unavailable");
    });
    return () => { current = false; };
  }, [api, statusAttempt]);

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
    const slug = workspaceSlug.trim().toLowerCase();
    if (!validWorkspaceSlug(slug)) {
      setCustomizeWorkspaceSlug(true);
      setError(
        "Choose a workspace address with 2–80 lowercase letters, numbers, or single hyphens."
      );
      return;
    }

    const values = new FormData(event.currentTarget);
    const input: BootstrapInput = {
      tenant_name: stringValue(values, "tenant_name"),
      tenant_slug: slug,
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
    const token = invitationToken || stringValue(values, "token");
    const tenantSlug =
      invitationContext.tenantSlug || stringValue(values, "tenant_slug");
    let trustedTenantSlug = tenantSlug;
    let fallbackNotice =
      "Invitation accepted. Your workspace and email are ready; sign in with the password you just created.";
    const password = stringValue(values, "password");

    setBusy(true);
    setError(null);
    try {
      const acceptedUser = await api.acceptInvitation({
        token,
        display_name: stringValue(values, "display_name"),
        password
      });
      const email = acceptedUser.email || "";
      form.reset();

      if (tenantSlug && email) {
        try {
          const session = await api.login({
            tenant_slug: tenantSlug,
            email,
            password,
            device: { name: browserName(), platform: "web" }
          });
          if (
            session.tenant.id !== acceptedUser.tenant_id ||
            session.user.id !== acceptedUser.id
          ) {
            trustedTenantSlug = "";
            fallbackNotice =
              "Invitation accepted, but the workspace link did not match the accepted account. Enter the workspace address supplied by your administrator.";
            throw new Error("Invitation workspace mismatch");
          }
          setSession(session);
          return;
        } catch {
          // Acceptance succeeded. Preserve a safe, prefilled manual sign-in
          // fallback rather than treating the whole operation as failed.
        }
      }

      setInvitationToken("");
      setLoginWorkspaceSlug(trustedTenantSlug);
      setLoginEmail(email);
      setEditingWorkspace(!trustedTenantSlug);
      selectMode("login");
      setError(null);
      setNotice(fallbackNotice);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  function selectMode(nextMode: AuthMode) {
    setMode(nextMode);
    setError(null);
    setNotice(null);
    const url = new URL(window.location.href);
    if (nextMode === "bootstrap") url.searchParams.set("setup", "workspace");
    else url.searchParams.delete("setup");
    navigate(`${url.pathname}${url.search}${url.hash}`, { replace: true });
  }

  function editRememberedWorkspace() {
    setEditingWorkspace(true);
    window.requestAnimationFrame(() => {
      document.getElementById("login-workspace")?.focus();
    });
  }

  const bootstrapEnabled = bootstrapAvailability === "enabled";
  const manualInvitation = mode === "invite" && !invitationToken;
  const eyebrow =
    mode === "login"
      ? "Welcome back"
      : mode === "invite"
        ? "You’re invited"
        : "Workspace setup";
  const heading =
    mode === "login"
      ? "Sign in to your workspace"
      : mode === "invite"
        ? manualInvitation
          ? "Join with an invitation code"
          : "Join your workspace"
        : "Create your workspace";
  const description =
    mode === "login"
      ? "Enter your email and password to continue."
      : mode === "invite"
        ? manualInvitation
          ? "Enter the code and workspace address supplied by your administrator."
          : "Create your profile and go straight to K-Comms."
        : "Set up your team and sign in as the workspace owner.";

  return (
    <main className="auth-page">
      <span className="sr-only" aria-live="polite" aria-atomic="true">
        {authModeTitle(mode)} view
      </span>
      <section className="auth-story" aria-labelledby="welcome-title">
        <Brand />
        <div className="auth-story-copy">
          <span className="eyebrow light">One place for your team</span>
          <h1 id="welcome-title">
            Chat, call, and share files
            <br />in one workspace.
          </h1>
          <p>Pick up where you left off on any device—even after the signal drops.</p>
        </div>
        <ul className="feature-list" aria-label="Platform capabilities">
          <li><span aria-hidden="true">01</span> Direct and room messaging</li>
          <li><span aria-hidden="true">02</span> Voice and video calls</li>
          <li><span aria-hidden="true">03</span> Safe file sharing</li>
        </ul>
      </section>

      <section className="auth-panel" aria-labelledby="auth-heading">
        <div className="auth-card">
          <span className="eyebrow">{eyebrow}</span>
          <h2 id="auth-heading" data-route-focus>{heading}</h2>
          <p className="muted">{description}</p>

          {error && <div className="form-error" role="alert">{error}</div>}
          {notice && <div className="inline-notice" role="status">{notice}</div>}

          {mode === "login" ? (
            <>
              <form key="login" className="auth-form" onSubmit={(event) => void submitLogin(event)}>
                {editingWorkspace || !loginWorkspaceSlug ? (
                  <Field
                    id="login-workspace"
                    label="Workspace address"
                    name="tenant_slug"
                    value={loginWorkspaceSlug}
                    onChange={(event) =>
                      setLoginWorkspaceSlug(event.target.value.toLowerCase())
                    }
                    autoComplete="organization"
                    autoCapitalize="none"
                    spellCheck={false}
                    hint="The short address from your invitation, such as acme."
                    required
                  />
                ) : (
                  <div className="auth-workspace-summary">
                    <span>Workspace address</span>
                    <strong>{loginWorkspaceSlug}</strong>
                    <button type="button" onClick={editRememberedWorkspace}>Change</button>
                    <input type="hidden" name="tenant_slug" value={loginWorkspaceSlug} />
                  </div>
                )}
                <Field
                  label="Email address"
                  name="email"
                  type="email"
                  value={loginEmail}
                  onChange={(event) => setLoginEmail(event.target.value)}
                  autoComplete="username"
                  required
                />
                <PasswordField
                  label="Password"
                  name="password"
                  autoComplete="current-password"
                  required
                />
                <div className="auth-form-help">
                  <Link to="/forgot-password">Forgot password?</Link>
                </div>
                <button className="button primary full" type="submit" disabled={busy}>
                  {busy ? "Signing in…" : "Sign in"}
                </button>
              </form>
              <div
                className="auth-entry-options"
                role="group"
                aria-label="Other ways to continue"
              >
                <button type="button" onClick={() => selectMode("invite")}>
                  Use invitation code
                </button>
                {bootstrapEnabled && (
                  <button type="button" onClick={() => selectMode("bootstrap")}>
                    Create workspace
                  </button>
                )}
              </div>
            </>
          ) : mode === "invite" ? (
            <>
              {invitationContext.tenantSlug && (
                <div className="auth-workspace-summary static">
                  <span>Workspace address</span>
                  <strong>{invitationContext.tenantSlug}</strong>
                </div>
              )}
              <form key="invite" className="auth-form" onSubmit={(event) => void acceptInvitation(event)}>
                {manualInvitation && (
                  <>
                    <Field
                      label="Invitation code"
                      name="token"
                      autoComplete="off"
                      required
                    />
                    <Field
                      label="Workspace address"
                      name="tenant_slug"
                      defaultValue={loginWorkspaceSlug}
                      autoComplete="organization"
                      autoCapitalize="none"
                      spellCheck={false}
                      required
                    />
                  </>
                )}
                <Field
                  label="Your name"
                  name="display_name"
                  maxLength={120}
                  autoComplete="name"
                  required
                />
                <PasswordField
                  label="Create password"
                  name="password"
                  minLength={12}
                  maxLength={256}
                  autoComplete="new-password"
                  hint="At least 12 characters"
                  required
                />
                <button className="button primary full" type="submit" disabled={busy}>
                  {busy ? "Joining…" : "Join workspace"}
                </button>
              </form>
              <button className="auth-back-button" type="button" onClick={() => selectMode("login")}>
                Back to sign in
              </button>
            </>
          ) : bootstrapAvailability === "checking" ? (
            <div className="auth-status" role="status">
              <span className="spinner" aria-hidden="true" />
              Checking workspace setup…
            </div>
          ) : bootstrapAvailability === "enabled" ? (
            <>
              <form key="bootstrap" className="auth-form" onSubmit={(event) => void submitBootstrap(event)}>
                <Field
                  label="Workspace name"
                  name="tenant_name"
                  value={workspaceName}
                  onChange={(event) => {
                    const nextName = event.target.value;
                    setWorkspaceName(nextName);
                    if (!workspaceSlugEdited) {
                      setWorkspaceSlug(workspaceSlugFromName(nextName));
                    }
                  }}
                  minLength={2}
                  maxLength={120}
                  autoComplete="organization"
                  required
                />
                <Field
                  label="Your name"
                  name="display_name"
                  maxLength={120}
                  autoComplete="name"
                  required
                />
                <Field
                  label="Work email"
                  name="email"
                  type="email"
                  autoComplete="username"
                  required
                />
                <PasswordField
                  label="Create password"
                  name="password"
                  minLength={12}
                  maxLength={256}
                  autoComplete="new-password"
                  hint="At least 12 characters"
                  required
                />
                <details
                  className="auth-disclosure"
                  open={customizeWorkspaceSlug}
                  onToggle={(event) =>
                    setCustomizeWorkspaceSlug(event.currentTarget.open)
                  }
                >
                  <summary>Customize workspace address</summary>
                  <Field
                    label="Workspace address"
                    name="tenant_slug"
                    value={workspaceSlug}
                    onChange={(event) => {
                      setWorkspaceSlugEdited(true);
                      setWorkspaceSlug(event.target.value.toLowerCase());
                    }}
                    minLength={2}
                    maxLength={80}
                    hint="Lowercase letters, numbers, and single hyphens."
                  />
                </details>
                <button className="button primary full" type="submit" disabled={busy}>
                  {busy ? "Creating workspace…" : "Create workspace"}
                </button>
              </form>
              <button className="auth-back-button" type="button" onClick={() => selectMode("login")}>
                Back to sign in
              </button>
            </>
          ) : (
            <div className="auth-unavailable" role="status">
              <p>
                {bootstrapAvailability === "disabled"
                  ? "Workspace creation is not available on this deployment. Ask an administrator for an invitation."
                  : "K-Comms could not verify workspace setup right now."}
              </p>
              {bootstrapAvailability === "unavailable" && (
                <button
                  className="button ghost full"
                  type="button"
                  onClick={() => setStatusAttempt((attempt) => attempt + 1)}
                >
                  Try again
                </button>
              )}
              <button className="auth-back-button" type="button" onClick={() => selectMode("login")}>
                Back to sign in
              </button>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}

function PasswordField({
  label,
  hint,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }) {
  const [visible, setVisible] = useState(false);
  return (
    <div className="password-field">
      <Field {...props} label={label} hint={hint} type={visible ? "text" : "password"} />
      <button
        className="password-visibility"
        type="button"
        aria-label={`${visible ? "Hide" : "Show"} ${label.toLowerCase()}`}
        aria-pressed={visible}
        onClick={() => setVisible((current) => !current)}
      >
        {visible ? "Hide" : "Show"}
      </button>
    </div>
  );
}

function authModeTitle(mode: AuthMode): string {
  if (mode === "invite") return "Invitation";
  if (mode === "bootstrap") return "Workspace setup";
  return "Sign in";
}

function readInvitationContext(): { token: string; tenantSlug: string } {
  const search = new URLSearchParams(window.location.search);
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  return {
    token: hash.get("invitation_token") || search.get("invitation_token") || "",
    tenantSlug: hash.get("tenant_slug") || search.get("tenant_slug") || ""
  };
}

function readBootstrapRequest(): boolean {
  const search = new URLSearchParams(window.location.search);
  return search.get("setup") === "workspace";
}

function workspaceSlugFromName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}
