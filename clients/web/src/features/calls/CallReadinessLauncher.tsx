import { useState } from "react";
import { useNavigate } from "react-router";
import type { ApiClient } from "../../api";
import type { CreateConversationInput } from "../../api/contracts";
import { AppIcon } from "../../components/AppIcon";
import { errorText, formatDateTime } from "../../lib/format";
import type { Conversation, GuestLink } from "../../types";
import { QrCode } from "../guest/QrCode";
import { copyGuestUrl, shareGuestUrl } from "../guest/guestLink";
import {
  callReadinessGuestUrl,
  callReadinessHostPath
} from "./callReadinessNavigation";

interface CreatedReadinessRoom {
  conversation: Conversation;
  guestLink: GuestLink;
  guestUrl: string;
}

export function CallReadinessLauncher({
  api,
  audioAvailable,
  createConversation
}: {
  api: ApiClient;
  audioAvailable: boolean;
  createConversation: (input: CreateConversationInput) => Promise<Conversation>;
}) {
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [pendingConversation, setPendingConversation] = useState<Conversation | null>(null);
  const [created, setCreated] = useState<CreatedReadinessRoom | null>(null);

  async function createTestRoom() {
    if (busy || !audioAvailable) return;
    setBusy(true);
    setError("");
    setStatus("");
    try {
      const conversation = pendingConversation || await createConversation({
        title: "UAE office call test",
        kind: "group",
        visibility: "private",
        member_ids: []
      });
      setPendingConversation(conversation);
      const link = await api.createGuestLink(conversation.id, {
        expires_in_seconds: 10 * 60,
        max_uses: 1
      });
      setCreated({
        conversation,
        guestLink: link.guestLink,
        guestUrl: callReadinessGuestUrl(link.url)
      });
      setPendingConversation(null);
      setStatus("One-use office test link ready.");
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusy(false);
    }
  }

  async function copyLink() {
    if (!created) return;
    setError("");
    try {
      await copyGuestUrl(created.guestUrl);
      setStatus("Office test link copied.");
    } catch {
      setError("This browser could not copy the link. Select it and copy it manually.");
    }
  }

  async function shareLink() {
    if (!created) return;
    setError("");
    try {
      const result = await shareGuestUrl(created.guestUrl);
      setStatus(
        result === "shared"
          ? "Office test link shared."
          : result === "copied"
            ? "Office test link copied."
            : "Sharing cancelled."
      );
    } catch {
      setError("This browser could not share the link. Select it and copy it manually.");
    }
  }

  return (
    <details className="call-readiness-launcher">
      <summary>
        <AppIcon name="lock" />
        Office connection test
      </summary>
      <div className="call-readiness-content">
        <p>Create a private, one-use audio test link. Calls are not recorded.</p>

        {created ? (
          <div className="call-readiness-invite">
            <QrCode
              value={created.guestUrl}
              label="QR code for the UAE office call test"
            />
            <div className="call-readiness-invite-copy">
              <label>
                One-use office link
                <input
                  type="text"
                  value={created.guestUrl}
                  readOnly
                  onFocus={(event) => event.currentTarget.select()}
                />
              </label>
              <small>
                Expires {formatDateTime(created.guestLink.expires_at)}. The first
                admitted guest uses the link.
              </small>
              <div className="call-readiness-launch-actions">
                <button className="button ghost" type="button" onClick={() => void copyLink()}>
                  <AppIcon name="copy" />
                  Copy link
                </button>
                <button className="button ghost" type="button" onClick={() => void shareLink()}>
                  <AppIcon name="share" />
                  Share
                </button>
                <button
                  className="button primary"
                  type="button"
                  onClick={() => navigate(callReadinessHostPath(created.conversation.id))}
                >
                  <AppIcon name="phone" />
                  Open my test call
                </button>
              </div>
            </div>
          </div>
        ) : (
          <button
            className="button primary call-readiness-create"
            type="button"
            disabled={busy || !audioAvailable}
            onClick={() => void createTestRoom()}
          >
            <AppIcon name="lock" />
            {busy ? "Creating private test room…" : "Create test link"}
          </button>
        )}

        {!audioAvailable && (
          <p className="calls-availability-note" role="status">
            Audio calling is unavailable.
          </p>
        )}
        {status && <p className="form-success" role="status">{status}</p>}
        {error && (
          <div className="form-error" role="alert">
            <span>{error}</span>
            {pendingConversation && (
              <button className="button ghost compact" type="button" onClick={() => void createTestRoom()}>
                Retry secure link
              </button>
            )}
          </div>
        )}
      </div>
    </details>
  );
}
