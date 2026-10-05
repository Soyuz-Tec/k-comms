import { createContext, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import { createPortal } from "react-dom";
import { ApiError } from "../api";
import { AppSurfaceControlButton } from "../components/AppMenuControls";
import { useModalDialog } from "../components/useModalDialog";
import { errorText, stringValue } from "../lib/format";
import { useSession } from "./session";

interface AuthorityBound {
  actorBinding: object;
  generation: number;
}

interface PendingAction extends AuthorityBound {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
}

interface VerificationGate extends AuthorityBound {
  promise: Promise<void>;
  resolve: () => void;
  reject: (reason: unknown) => void;
  verifying: boolean;
}

interface StepUpContextValue {
  runWithStepUp: <T>(action: () => Promise<T>) => Promise<T>;
}

const StepUpContext = createContext<StepUpContextValue | null>(null);

export class StepUpCancelledError extends Error {
  constructor() {
    super("Sensitive action cancelled");
    this.name = "StepUpCancelledError";
  }
}

export function StepUpProvider({ children }: { children: ReactNode }) {
  const { api, session } = useSession();
  const [pending, setPending] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const formRef = useRef<HTMLFormElement | null>(null);
  const actorBinding = useMemo(() => ({
    tenant: session?.tenant.id, user: session?.user.id, device: session?.device.id,
    role: session?.user.role, status: session?.user.status, version: session?.user.version,
    accountType: session?.user.account_type, accessScope: session?.user.access_scope,
    credential: session?.access_token, refreshCredential: session?.refresh_token
  }), [session?.tenant.id, session?.user.id, session?.device.id, session?.user.role,
    session?.user.status, session?.user.version, session?.user.account_type,
    session?.user.access_scope, session?.access_token, session?.refresh_token]);
  const owner = useRef(actorBinding);
  const mounted = useRef(false);
  const generation = useRef(0);
  const completedProofs = useRef(0);
  const actions = useRef(new Set<PendingAction>());
  const verification = useRef<VerificationGate | null>(null);

  const isCurrent = useCallback((action: AuthorityBound) => mounted.current &&
    action.actorBinding === owner.current && action.generation === generation.current, []);

  const cancel = useCallback(() => {
    generation.current += 1;
    completedProofs.current = 0;
    const gate = verification.current;
    verification.current = null;
    gate?.reject(new StepUpCancelledError());
    actions.current.forEach(action => action.reject(new StepUpCancelledError()));
    actions.current.clear();
    formRef.current?.reset();
    if (mounted.current) { setError(null); setPending(false); setBusy(false); }
  }, []);

  useLayoutEffect(() => {
    owner.current = actorBinding;
    mounted.current = true;
    setError(null); setPending(false); setBusy(false);
    return () => { mounted.current = false; cancel(); };
  }, [actorBinding, cancel]);

  const runWithStepUp = useCallback(function runWithStepUp<T>(action: () => Promise<T>): Promise<T> {
    if (!mounted.current) return Promise.reject(new StepUpCancelledError());
    const proofAtStart = completedProofs.current;
    return new Promise<T>((resolve, reject) => {
      const caller: PendingAction = { actorBinding: owner.current, generation: generation.current,
        resolve: value => resolve(value as T), reject };
      actions.current.add(caller);
      const requireCurrent = () => { if (!isCurrent(caller)) throw new StepUpCancelledError(); };
      void (async () => {
        try {
          const value = await action(); requireCurrent(); caller.resolve(value);
        } catch (reason: unknown) {
          if (!isCurrent(caller)) caller.reject(new StepUpCancelledError());
          else if (!(reason instanceof ApiError) || reason.code !== "step_up_required") caller.reject(reason);
          else {
            try {
              // Every concurrent 428 joins the same proof. A late initial 428
              // also uses proof completed since that caller started.
              if (completedProofs.current === proofAtStart) {
                let gate = verification.current;
                if (!gate) {
                  let approve!: () => void; let deny!: (reason: unknown) => void;
                  const promise = new Promise<void>((done, fail) => { approve = done; deny = fail; });
                  gate = { actorBinding: caller.actorBinding, generation: caller.generation,
                    promise, resolve: approve, reject: deny, verifying: false };
                  verification.current = gate; setError(null); setPending(true);
                }
                await gate.promise;
              }
              requireCurrent();
              // One retry only. A second 428 is returned to this caller;
              // another proof is never triggered automatically.
              const value = await action(); requireCurrent(); caller.resolve(value);
            } catch (failure: unknown) { caller.reject(isCurrent(caller) ? failure : new StepUpCancelledError()); }
          }
        } finally { actions.current.delete(caller); }
      })();
    });
  }, [isCurrent]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const gate = verification.current;
    if (!gate || gate.verifying || !isCurrent(gate)) return;
    const form = event.currentTarget;
    const data = new FormData(form);
    const password = stringValue(data, "current_password");
    const mfaCode = stringValue(data, "mfa_code") || undefined;
    gate.verifying = true; setBusy(true);
    setError(null);
    try {
      await api.stepUp(password, mfaCode);
      if (verification.current !== gate || !isCurrent(gate)) return;
      form.reset();
      completedProofs.current += 1;
      verification.current = null;
      setPending(false); setBusy(false);
      gate.resolve();
    } catch (reason: unknown) {
      if (verification.current === gate && isCurrent(gate)) setError(errorText(reason));
    } finally {
      if (verification.current === gate && isCurrent(gate)) { gate.verifying = false; setBusy(false); }
    }
  }

  async function corporateVerification() {
    const gate = verification.current;
    if (!session || !gate || gate.verifying || !isCurrent(gate)) return;
    gate.verifying = true; setBusy(true); setError(null);
    try {
      const result = await api.stepUpOidc(session.tenant.slug);
      if (verification.current !== gate || !isCurrent(gate)) return;
      const url = new URL(result.authorization_url);
      if (url.protocol !== "https:" || url.username || url.password) throw new Error("The corporate verification address could not be verified.");
      sessionStorage.setItem("kcomms:oidc-link", "1");
      // A redirect drops the in-memory action; the user retries it after proof.
      cancel();
      window.location.assign(url.href);
    } catch (reason: unknown) {
      if (verification.current === gate && isCurrent(gate)) { gate.verifying = false; setError(errorText(reason)); setBusy(false); }
    }
  }

  return (
    <StepUpContext.Provider value={{ runWithStepUp }}>
      {children}
      {pending && <StepUpDialog busy={busy} error={error} formRef={formRef} onCancel={cancel} onSubmit={submit} onCorporateVerification={typeof api.stepUpOidc === "function" ? corporateVerification : undefined} />}
    </StepUpContext.Provider>
  );
}

function StepUpDialog({
  busy,
  error,
  formRef,
  onCancel,
  onSubmit,
  onCorporateVerification
}: {
  busy: boolean;
  error: string | null;
  formRef: React.RefObject<HTMLFormElement | null>;
  onCancel: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  onCorporateVerification?: () => Promise<void>;
}) {
  const dialogRef = useModalDialog(() => {
    if (!busy) onCancel();
  });
  return createPortal(
    <div className="modal-backdrop">
      <section ref={dialogRef} className="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="step-up-title" aria-describedby="step-up-description">
        <header className="app-dialog-heading">
          <h2 id="step-up-title">Confirm it is you</h2>
          <AppSurfaceControlButton
            accessibleLabel="Close identity confirmation"
            disabled={busy}
            kind="close"
            onClick={onCancel}
          />
        </header>
        <p id="step-up-description">Enter your current password to continue this sensitive action. The password is used only for this verification.</p>
        {error && <div className="form-error" role="alert">{error}</div>}
        <form ref={formRef} onSubmit={onSubmit}>
          <label className="field">Current password<input autoFocus data-initial-focus name="current_password" type="password" autoComplete="current-password" required /></label>
          <label className="field">Authenticator or recovery code, if enabled<input name="mfa_code" autoComplete="one-time-code" /></label>
          <div className="form-actions">
            <button className="button ghost" type="button" disabled={busy} onClick={onCancel}>Cancel</button>
            <button className="button primary" type="submit" disabled={busy}>{busy ? "Verifying…" : "Continue"}</button>
          </div>
        </form>
        {onCorporateVerification && <><button className="button ghost" type="button" disabled={busy} onClick={() => void onCorporateVerification()}>Verify with corporate sign in</button><p>After verification, return to this action and try again.</p></>}
      </section>
    </div>,
    document.body
  );
}

export function useStepUp(): StepUpContextValue {
  const value = useContext(StepUpContext);
  if (!value) throw new Error("useStepUp must be used within StepUpProvider");
  return value;
}

export function stepUpWasCancelled(reason: unknown): boolean {
  return reason instanceof StepUpCancelledError;
}
