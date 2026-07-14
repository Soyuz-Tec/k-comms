import { createContext, useCallback, useContext, useRef, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import { createPortal } from "react-dom";
import { ApiError } from "../api";
import { useModalDialog } from "../components/useModalDialog";
import { errorText, stringValue } from "../lib/format";
import { useSession } from "./session";

interface PendingAction {
  action: () => Promise<unknown>;
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
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
  const { api } = useSession();
  const [pending, setPending] = useState<PendingAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const formRef = useRef<HTMLFormElement | null>(null);

  const runWithStepUp = useCallback(async function runWithStepUp<T>(action: () => Promise<T>): Promise<T> {
    try {
      return await action();
    } catch (reason: unknown) {
      if (!(reason instanceof ApiError) || reason.code !== "step_up_required") throw reason;
      return new Promise<T>((resolve, reject) => {
        setError(null);
        setPending({
          action,
          resolve: (value) => resolve(value as T),
          reject
        });
      });
    }
  }, []);

  function cancel() {
    pending?.reject(new StepUpCancelledError());
    formRef.current?.reset();
    setError(null);
    setPending(null);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!pending) return;
    const form = event.currentTarget;
    const password = stringValue(new FormData(form), "current_password");
    setBusy(true);
    setError(null);
    try {
      await api.stepUp(password);
      form.reset();
      const value = await pending.action();
      pending.resolve(value);
      setPending(null);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <StepUpContext.Provider value={{ runWithStepUp }}>
      {children}
      {pending && <StepUpDialog busy={busy} error={error} formRef={formRef} onCancel={cancel} onSubmit={submit} />}
    </StepUpContext.Provider>
  );
}

function StepUpDialog({
  busy,
  error,
  formRef,
  onCancel,
  onSubmit
}: {
  busy: boolean;
  error: string | null;
  formRef: React.RefObject<HTMLFormElement | null>;
  onCancel: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
}) {
  const dialogRef = useModalDialog(onCancel);
  return createPortal(
    <div className="modal-backdrop">
      <section ref={dialogRef} className="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="step-up-title" aria-describedby="step-up-description">
        <h2 id="step-up-title">Confirm it is you</h2>
        <p id="step-up-description">Enter your current password to continue this sensitive action. The password is used only for this verification.</p>
        {error && <div className="form-error" role="alert">{error}</div>}
        <form ref={formRef} onSubmit={onSubmit}>
          <label className="field">Current password<input autoFocus data-initial-focus name="current_password" type="password" autoComplete="current-password" required /></label>
          <div className="form-actions">
            <button className="button ghost" type="button" disabled={busy} onClick={onCancel}>Cancel</button>
            <button className="button primary" type="submit" disabled={busy}>{busy ? "Verifying…" : "Continue"}</button>
          </div>
        </form>
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
