import { useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api";
import { stepUpWasCancelled } from "../../app/step-up";
import { ConfirmDialog } from "../../components/ActionDialog";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText, formatDateTime, conversationTitle } from "../../lib/format";
import type { Conversation, GuestLink } from "../../types";
import { QrCode } from "./QrCode";
import {
  copyGuestUrl,
  shareGuestUrl
} from "./guestLink";
import "./GuestAccess.css";

export function canCreateGuestLink(conversation: Conversation): boolean {
  return conversation.kind !== "direct" &&
    ["owner", "moderator"].includes(conversation.membership_role || "");
}

export function ConversationShareDialog({
  api,
  conversation,
  canPreauthorizeAccount = false,
  runPrivilegedAction,
  onClose
}: {
  api: ApiClient;
  conversation: Conversation;
  canPreauthorizeAccount?: boolean;
  runPrivilegedAction?: <T>(action: () => Promise<T>) => Promise<T>;
  onClose: () => void;
}) {
  const dialogRef = useModalDialog(onClose);
  const [expiresInSeconds, setExpiresInSeconds] = useState(24 * 60 * 60);
  const [maxUses, setMaxUses] = useState(10);
  const [created, setCreated] = useState<{
    guestLink: GuestLink;
    url: string;
    conversionVerificationCode?: string;
  } | null>(null);
  const [links, setLinks] = useState<GuestLink[]>([]);
  const [linksLoading, setLinksLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [conversionEnabled, setConversionEnabled] = useState(false);
  const [conversionEmail, setConversionEmail] = useState("");
  const [pendingRevocation, setPendingRevocation] = useState<GuestLink | null>(null);
  const [revocationError, setRevocationError] = useState("");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const direct = conversation.kind === "direct";
  const manageable = canCreateGuestLink(conversation);
  const priorGuestLimitRef = useRef(10);

  useEffect(() => {
    if (!manageable) return;
    let current = true;
    setLinksLoading(true);
    void api.guestLinks(conversation.id)
      .then((result) => {
        if (current) setLinks(result.filter(({ status: linkStatus }) => linkStatus === "active"));
      })
      .catch((reason: unknown) => {
        if (current) setError(errorText(reason));
      })
      .finally(() => {
        if (current) setLinksLoading(false);
      });
    return () => {
      current = false;
    };
  }, [api, conversation.id, manageable]);

  async function createLink() {
    setBusy(true);
    setError("");
    setStatus("");
    try {
      const input = {
        expires_in_seconds: expiresInSeconds,
        max_uses: conversionEnabled ? 1 : maxUses,
        ...(conversionEnabled
          ? { conversion_email: conversionEmail.trim() }
          : {})
      };
      const command = () => api.createGuestLink(conversation.id, input);
      const result = conversionEnabled && runPrivilegedAction
        ? await runPrivilegedAction(command)
        : await command();
      setCreated({
        guestLink: result.guestLink,
        url: result.url,
        conversionVerificationCode: result.conversionVerificationCode
      });
      setLinks((current) => [
        result.guestLink,
        ...current.filter(({ id }) => id !== result.guestLink.id)
      ]);
      setStatus("Guest link and QR code ready.");
    } catch (reason: unknown) {
      if (stepUpWasCancelled(reason)) return;
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  function toggleConversionPolicy() {
    setConversionEnabled((enabled) => {
      if (enabled) {
        setConversionEmail("");
        setMaxUses(priorGuestLimitRef.current);
        return false;
      }

      priorGuestLimitRef.current = maxUses;
      setMaxUses(1);
      return true;
    });
  }

  async function copyLink() {
    if (!created) return;
    setError("");
    try {
      await copyGuestUrl(created.url);
      setStatus("Guest link copied.");
    } catch {
      setError("This browser could not copy the link. Select the link and copy it manually.");
    }
  }

  async function shareLink() {
    if (!created) return;
    setError("");
    try {
      const result = await shareGuestUrl(created.url);
      setStatus(
        result === "shared"
          ? "Guest link shared."
          : result === "copied"
            ? "Guest link copied."
            : "Sharing cancelled."
      );
    } catch {
      setError("This browser could not share or copy the link. Select it and copy it manually.");
    }
  }

  async function copyConversionVerificationCode() {
    if (!created?.conversionVerificationCode) return;
    setError("");
    try {
      await copyGuestUrl(created.conversionVerificationCode);
      setStatus("Account verification code copied.");
    } catch {
      setError(
        "This browser could not copy the verification code. Select it and copy it manually."
      );
    }
  }

  async function revokeLink(guestLink: GuestLink) {
    setBusy(true);
    setRevocationError("");
    try {
      await api.revokeGuestLink(
        conversation.id,
        guestLink.id
      );
      if (created?.guestLink.id === guestLink.id) setCreated(null);
      setLinks((current) => current.filter(({ id }) => id !== guestLink.id));
      setPendingRevocation(null);
      setStatus("Guest link revoked. New joins are blocked and active guest sessions were ended.");
    } catch (reason: unknown) {
      setRevocationError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="guest-dialog-backdrop">
      <section
        ref={dialogRef}
        className="guest-share-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="guest-share-title"
        tabIndex={-1}
      >
        <header>
          <div>
            <span className="eyebrow">Guest access</span>
            <h2 id="guest-share-title">Invite to {conversationTitle(conversation)}</h2>
          </div>
          <button className="icon-button" type="button" aria-label="Close guest invitation" onClick={onClose}>
            ×
          </button>
        </header>

        {direct ? (
          <div className="guest-direct-guidance">
            <h3>Create a room to invite a guest</h3>
            <p>
              Guest links are intentionally unavailable for direct messages.
              Create a private group, then use its Invite guest action.
            </p>
            <button className="button primary" type="button" onClick={onClose}>
              Got it
            </button>
          </div>
        ) : !manageable ? (
          <p className="support-note">
            Only room owners and moderators can create guest links.
          </p>
        ) : created ? (
          <div className="guest-link-result">
            <QrCode
              value={created.url}
              label={`QR code for the guest link to ${conversationTitle(conversation)}`}
            />
            <label className="field">
              Secure guest link
              <input
                type="text"
                value={created.url}
                readOnly
                aria-label="Secure guest link"
                onFocus={(event) => event.currentTarget.select()}
              />
            </label>
            <p className="guest-expiry">
              Expires {formatDateTime(created.guestLink.expires_at)} · Up to{" "}
              {created.guestLink.max_uses} {created.guestLink.max_uses === 1 ? "guest" : "guests"}
            </p>
            <p className="guest-conversion-summary">
              {created.guestLink.conversion_enabled
                ? `Optional account creation is preauthorized for ${created.guestLink.email_hint || "the approved email"} and requires the separate one-time code below.`
                : "Communication-only access. This link does not permit account creation."}
            </p>
            {created.conversionVerificationCode && (
              <div className="guest-conversion-code">
                <label className="field">
                  Account verification code
                  <input
                    type="text"
                    value={created.conversionVerificationCode}
                    readOnly
                    aria-label="Account verification code"
                    onFocus={(event) => event.currentTarget.select()}
                  />
                </label>
                <button
                  className="button ghost"
                  type="button"
                  onClick={() => void copyConversionVerificationCode()}
                >
                  Copy verification code
                </button>
                <p className="support-note">
                  Send this code separately to the authorized email recipient. It is not
                  contained in the link or QR and cannot be displayed again after this
                  dialog closes.
                </p>
              </div>
            )}
            <div className="guest-share-actions">
              <button className="button primary" type="button" onClick={() => void copyLink()}>
                Copy link
              </button>
              <button className="button ghost" type="button" onClick={() => void shareLink()}>
                Share…
              </button>
              <button
                className="button danger"
                type="button"
                disabled={busy}
                onClick={() => {
                  setRevocationError("");
                  setPendingRevocation(created.guestLink);
                }}
              >
                {busy ? "Revoking…" : "Revoke"}
              </button>
            </div>
            <p className="support-note">
              The QR and both share actions use this exact link. Anyone with it can join
              until it expires, reaches its guest limit or is revoked.
            </p>
          </div>
        ) : (
          <form
            className="guest-link-setup"
            onSubmit={(event) => {
              event.preventDefault();
              void createLink();
            }}
          >
            <p>
              Create one expiring, communication-only link. Guests enter only this
              room and do not need an account.
            </p>
            {canPreauthorizeAccount && (
              <div className="guest-conversion-policy">
                <button
                  className="button ghost compact"
                  type="button"
                  aria-expanded={conversionEnabled}
                  aria-controls="guest-conversion-policy-fields"
                  onClick={toggleConversionPolicy}
                >
                  {conversionEnabled
                    ? "Use communication-only link"
                    : "Preauthorize optional account creation"}
                </button>
                {conversionEnabled && (
                  <div id="guest-conversion-policy-fields">
                    <label className="field">
                      Authorized account email
                      <input
                        type="email"
                        value={conversionEmail}
                        maxLength={320}
                        autoComplete="off"
                        required
                        onChange={(event) => setConversionEmail(event.target.value)}
                      />
                    </label>
                    <small>
                      This creates a single-use link and a separate one-time
                      verification code. Only the exact email plus that code can
                      convert the guest identity into an account.
                    </small>
                  </div>
                )}
              </div>
            )}
            <div className="field-pair">
              <label className="field">
                Link expires
                <select
                  value={expiresInSeconds}
                  onChange={(event) => setExpiresInSeconds(Number(event.target.value))}
                >
                  <option value={60 * 60}>In 1 hour</option>
                  <option value={8 * 60 * 60}>In 8 hours</option>
                  <option value={24 * 60 * 60}>In 24 hours</option>
                </select>
              </label>
              <label className="field">
                Guest limit
                <select
                  value={conversionEnabled ? 1 : maxUses}
                  disabled={conversionEnabled}
                  aria-describedby={conversionEnabled ? "guest-single-use-help" : undefined}
                  onChange={(event) => setMaxUses(Number(event.target.value))}
                >
                  <option value={1}>1 guest</option>
                  <option value={5}>5 guests</option>
                  <option value={10}>10 guests</option>
                  <option value={25}>25 guests</option>
                </select>
                {conversionEnabled && (
                  <small id="guest-single-use-help">
                    Account-enabled links are single-use for identity safety.
                  </small>
                )}
              </label>
            </div>
            <button
              className="button primary full"
              type="submit"
              disabled={busy}
            >
              {busy ? "Creating secure link…" : "Create link and QR"}
            </button>
            <ActiveGuestLinks
              links={links}
              loading={linksLoading}
              busy={busy}
              onRevoke={(guestLink) => {
                setRevocationError("");
                setPendingRevocation(guestLink);
              }}
            />
          </form>
        )}

        {status && <p className="form-success" role="status">{status}</p>}
        {error && <p className="form-error" role="alert">{error}</p>}
        {pendingRevocation && (
          <ConfirmDialog
            title="Revoke this guest link?"
            description="This action takes effect immediately for this link."
            impact="New joins will be blocked. Active guests admitted through this link will be signed out and removed from active audio or video calls. Guests who already created accounts will keep their access."
            confirmLabel="Revoke guest link"
            tone="danger"
            busy={busy}
            error={revocationError}
            onCancel={() => {
              if (!busy) {
                setPendingRevocation(null);
                setRevocationError("");
              }
            }}
            onConfirm={() => void revokeLink(pendingRevocation)}
          />
        )}
      </section>
    </div>
  );
}

function ActiveGuestLinks({
  links,
  loading,
  busy,
  onRevoke
}: {
  links: GuestLink[];
  loading: boolean;
  busy: boolean;
  onRevoke: (guestLink: GuestLink) => void;
}) {
  if (loading) {
    return <p className="support-note" role="status">Loading active guest links…</p>;
  }
  if (links.length === 0) return null;

  return (
    <section className="active-guest-links" aria-labelledby="active-guest-links-title">
      <div>
        <h3 id="active-guest-links-title">Active guest links</h3>
        <small>For security, an existing link’s secret cannot be displayed again.</small>
      </div>
      <ul>
        {links.map((guestLink) => (
          <li key={guestLink.id}>
            <span>
              <strong>Expires {formatDateTime(guestLink.expires_at)}</strong>
              <small>{guestLink.use_count} of {guestLink.max_uses} guest admissions used</small>
              <small>
                {guestLink.conversion_enabled
                  ? `Account preauthorized for ${guestLink.email_hint || "approved email"}`
                  : "Communication only"}
              </small>
            </span>
            <button
              className="button danger compact"
              type="button"
              disabled={busy}
              aria-label={`Revoke guest link expiring ${formatDateTime(guestLink.expires_at)}`}
              onClick={() => onRevoke(guestLink)}
            >
              Revoke
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}
