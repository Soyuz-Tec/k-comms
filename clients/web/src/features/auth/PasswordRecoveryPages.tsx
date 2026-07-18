import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import { Link } from "react-router-dom";
import { ApiError } from "../../api";
import { useSession } from "../../app/session";
import { Brand } from "../../components/Brand";
import { Field } from "../../components/Field";
import { stringValue } from "../../lib/format";

const genericRequestMessage =
  "If an account matches those details, password-reset instructions will arrive shortly. For privacy, we cannot confirm whether an account exists.";

export function ForgotPasswordPage() {
  const { api } = useSession();
  const [busy, setBusy] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = new FormData(event.currentTarget);
    setBusy(true);
    setError(null);
    try {
      await api.requestPasswordRecovery({
        tenant_slug: stringValue(values, "tenant_slug"),
        email: stringValue(values, "email")
      });
      setSubmitted(true);
    } catch (reason: unknown) {
      setError(requestError(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <RecoveryLayout title="Reset your password" description="Enter your workspace and email address. The response is intentionally private.">
      {submitted ? (
        <div className="recovery-result" role="status" tabIndex={-1} autoFocus>
          <h2>Check your email</h2>
          <p>{genericRequestMessage}</p>
          <Link className="button primary full" to="/app">Return to sign in</Link>
        </div>
      ) : (
        <form className="auth-form" onSubmit={(event) => void submit(event)}>
          {error && <div className="form-error" role="alert">{error}</div>}
          <Field label="Workspace slug" name="tenant_slug" autoComplete="organization" autoFocus required />
          <Field label="Email address" name="email" type="email" autoComplete="email" required />
          <button className="button primary full" type="submit" disabled={busy}>{busy ? "Requesting…" : "Send reset instructions"}</button>
          <Link className="recovery-back-link" to="/app">Back to sign in</Link>
        </form>
      )}
    </RecoveryLayout>
  );
}

export function ResetPasswordPage() {
  const { api } = useSession();
  const tokenRef = useRef(readResetToken());
  const mountedRef = useRef(true);
  const [hasToken, setHasToken] = useState(Boolean(tokenRef.current));
  const [busy, setBusy] = useState(false);
  const [completed, setCompleted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useLayoutEffect(() => scrubResetToken(), []);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      queueMicrotask(() => {
        if (!mountedRef.current) tokenRef.current = "";
      });
    };
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const token = tokenRef.current;
    if (!token) return setError("This reset link is invalid or expired. Request a new one.");
    const form = event.currentTarget;
    const values = new FormData(form);
    const password = stringValue(values, "new_password");
    if (password !== stringValue(values, "confirm_password")) {
      return setError("Password confirmation does not match.");
    }

    setBusy(true);
    setError(null);
    try {
      await api.resetPassword({ token, new_password: password });
      tokenRef.current = "";
      setHasToken(false);
      form.reset();
      setCompleted(true);
    } catch (reason: unknown) {
      const result = resetError(reason);
      if (result.invalidToken) {
        tokenRef.current = "";
        setHasToken(false);
      }
      setError(result.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <RecoveryLayout title="Choose a new password" description="Your reset token is held only in memory and removed from the address bar immediately.">
      {completed ? (
        <div className="recovery-result" role="status" tabIndex={-1} autoFocus>
          <h2>Password updated</h2>
          <p>Your password has been reset. Sign in again on each device you want to use.</p>
          <Link className="button primary full" to="/app">Sign in</Link>
        </div>
      ) : !hasToken ? (
        <div className="recovery-result" role="alert">
          <h2>Reset link unavailable</h2>
          <p>{error || "This reset link is invalid or expired. Request a new one."}</p>
          <Link className="button primary full" to="/forgot-password">Request another link</Link>
        </div>
      ) : (
        <form className="auth-form" onSubmit={(event) => void submit(event)}>
          {error && <div className="form-error" role="alert">{error}</div>}
          <Field label="New password" name="new_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" hint="At least 12 characters; the server applies the final password policy" autoFocus required />
          <Field label="Confirm new password" name="confirm_password" type="password" minLength={12} maxLength={256} autoComplete="new-password" required />
          <button className="button primary full" type="submit" disabled={busy}>{busy ? "Updating…" : "Update password"}</button>
          <Link className="recovery-back-link" to="/forgot-password">Request a different reset link</Link>
        </form>
      )}
    </RecoveryLayout>
  );
}

function RecoveryLayout({ title, description, children }: { title: string; description: string; children: ReactNode }) {
  return (
    <main className="recovery-page">
      <section className="recovery-shell" aria-labelledby="recovery-title">
        <Brand />
        <span className="eyebrow">Account recovery</span>
        <h1 id="recovery-title">{title}</h1>
        <p className="muted">{description}</p>
        {children}
      </section>
    </main>
  );
}

function readResetToken(): string {
  const fragmentToken = new URLSearchParams(window.location.hash.replace(/^#/, "")).get("token");
  return fragmentToken || new URLSearchParams(window.location.search).get("token") || "";
}

function scrubResetToken(): void {
  const url = new URL(window.location.href);
  let changed = false;
  if (url.searchParams.has("token")) {
    url.searchParams.delete("token");
    changed = true;
  }
  const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
  if (fragment.has("token")) {
    fragment.delete("token");
    url.hash = fragment.toString() ? `#${fragment.toString()}` : "";
    changed = true;
  }
  if (changed) window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
}

function requestError(reason: unknown): string {
  if (reason instanceof ApiError && reason.status === 429) {
    return "Too many recovery requests were made. Wait a few minutes and try again.";
  }
  return "Recovery instructions could not be requested right now. Try again shortly.";
}

function resetError(reason: unknown): { message: string; invalidToken: boolean } {
  if (reason instanceof ApiError) {
    if (["invalid_recovery_token", "invalid_reset_token", "expired_reset_token", "reset_token_used", "not_found"].includes(reason.code)) {
      return { message: "This reset link is invalid or expired. Request a new one.", invalidToken: true };
    }
    if (["weak_password", "password_policy_violation", "invalid_password", "validation_failed"].includes(reason.code)) {
      const minimum = numericMeta(reason.meta, "minimum_length") || numericMeta(reason.meta, "min_length");
      return {
        message: minimum
          ? `The password does not meet server policy. Use at least ${minimum} characters and try again.`
          : "The password does not meet the server's password policy. Choose a stronger password and try again.",
        invalidToken: false
      };
    }
  }
  return { message: "The password could not be reset right now. Try again shortly.", invalidToken: false };
}

function numericMeta(value: unknown, key: string): number | null {
  if (!value || typeof value !== "object") return null;
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "number" && Number.isFinite(candidate) ? candidate : null;
}
