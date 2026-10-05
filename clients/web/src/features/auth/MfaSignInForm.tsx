import { useEffect, useState, type FormEvent } from "react";
import type { ApiClient } from "../../api";
import type { Session } from "../../types";
import type { MfaChallenge } from "../../types/enterpriseIdentity";
import { errorText } from "../../lib/format";

export function MfaSignInForm({ api, challenge, disabled, onComplete, onRestart }: {
  api: Pick<ApiClient, "completeMfaSignIn">;
  challenge: MfaChallenge;
  disabled: boolean;
  onComplete: (session: Session) => void;
  onRestart: () => void;
}) {
  const [expiresAt] = useState(() => Date.now() + challenge.expires_in * 1_000);
  const [expired, setExpired] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const timer = window.setTimeout(() => setExpired(true), Math.max(0, expiresAt - Date.now()));
    return () => window.clearTimeout(timer);
  }, [expiresAt]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (disabled || expired || busy) return;
    const form = event.currentTarget;
    const code = String(new FormData(form).get("code") || "").trim();
    setBusy(true); setError(null);
    try {
      const session = await api.completeMfaSignIn(challenge.challenge_token, code);
      form.reset();
      onComplete(session);
    } catch (reason: unknown) { setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <form className="auth-form" onSubmit={submit}>
    <p>Enter the current code from your authenticator app or one unused recovery code.</p>
    {error && <p role="alert">{error}</p>}
    {expired && <p role="alert">This sign-in challenge expired. Sign in again to continue.</p>}
    <label className="field">Authenticator or recovery code
      <input name="code" autoComplete="one-time-code" autoFocus autoCapitalize="none" spellCheck={false} required disabled={disabled || expired || busy} />
    </label>
    <button className="button primary full" disabled={disabled || expired || busy}>{busy ? "Verifying…" : "Verify and sign in"}</button>
    <button className="button ghost" type="button" disabled={busy} onClick={onRestart}>Start sign in again</button>
  </form>;
}
