import type { FormEvent, RefObject } from "react";
import type { GuestSession } from "../../types";

export interface ConversionReceipt {
  displayName: string;
  workspaceSlug: string;
}

interface GuestConversionPanelProps {
  accountActionsAllowed: boolean;
  accountEmailRef: RefObject<HTMLInputElement | null>;
  conversionEnabled: boolean;
  conversionNotice: string;
  converting: boolean;
  initialSession: GuestSession;
  onClose: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  open: boolean;
  receipt: ConversionReceipt | null;
  selfServiceConversion: boolean;
}

export function GuestConversionPanel({
  accountActionsAllowed,
  accountEmailRef,
  conversionEnabled,
  conversionNotice,
  converting,
  initialSession,
  onClose,
  onSubmit,
  open,
  receipt,
  selfServiceConversion
}: GuestConversionPanelProps) {
  return (
    <>
      <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {conversionNotice}
      </p>

      {receipt && (
        <section
          className="guest-conversion-receipt"
          aria-labelledby="guest-conversion-receipt-title"
        >
          <div>
            <strong id="guest-conversion-receipt-title">
              Room saved for {receipt.displayName}
            </strong>
            <span>
              Use this workspace address to sign in from another device.
            </span>
          </div>
          <label>
            Workspace address
            <input
              type="text"
              value={receipt.workspaceSlug}
              readOnly
              spellCheck={false}
              onFocus={(event) => event.currentTarget.select()}
            />
          </label>
          <a
            className="button ghost"
            href={`/sign-in?tenant_slug=${encodeURIComponent(
              receipt.workspaceSlug
            )}`}
          >
            Workspace sign-in link
          </a>
        </section>
      )}

      {conversionEnabled && !receipt && open && (
        <section
          className="guest-account-card"
          id="guest-account-conversion"
          aria-labelledby="guest-account-title"
        >
          <div>
            <h2 id="guest-account-title">Keep your conversation</h2>
            <p id="guest-account-email-help">
              {selfServiceConversion
                ? "Add an email and password without leaving the room. Your identity, membership and conversation history stay in place."
                : (
                  <>
                    Enter the full email authorized by the host
                    {initialSession.capabilities.email_hint
                      ? <> ({initialSession.capabilities.email_hint})</>
                      : null}
                    , plus the one-time verification code the host sent separately.
                    Your identity and conversation history stay in place.
                  </>
                )}
            </p>
          </div>
          <form onSubmit={onSubmit}>
            <label className="field">
              Work email
              <input
                ref={accountEmailRef}
                name="email"
                type="email"
                maxLength={320}
                autoComplete="email"
                aria-describedby="guest-account-email-help"
                disabled={!accountActionsAllowed}
                required
              />
            </label>
            {selfServiceConversion && (
              <label className="field">
                Display name <span className="optional">(optional)</span>
                <input
                  name="display_name"
                  type="text"
                  maxLength={120}
                  autoComplete="name"
                  defaultValue={initialSession.user.display_name}
                  disabled={!accountActionsAllowed}
                />
              </label>
            )}
            {!selfServiceConversion && <div className="field">
              <label htmlFor="guest-account-verification-code">
                Account verification code
              </label>
              <input
                id="guest-account-verification-code"
                name="verification_code"
                type="text"
                minLength={43}
                maxLength={43}
                pattern="[A-Za-z0-9_-]{43}"
                autoComplete="one-time-code"
                aria-describedby="guest-account-verification-help"
                spellCheck={false}
                disabled={!accountActionsAllowed}
                required
              />
              <small id="guest-account-verification-help">
                This code is separate from the room link and can be used only for this account conversion.
              </small>
            </div>}
            <label className="field">
              Password
              <input
                name="password"
                type="password"
                minLength={12}
                maxLength={256}
                autoComplete="new-password"
                disabled={!accountActionsAllowed}
                required
              />
              <small>At least 12 characters; the server applies the final password policy.</small>
            </label>
            <button
              className="button primary"
              type="submit"
              disabled={converting || !accountActionsAllowed}
            >
              {converting ? "Creating account…" : "Create account"}
            </button>
            <button className="button ghost" type="button" onClick={onClose}>
              Not now
            </button>
          </form>
        </section>
      )}
    </>
  );
}
