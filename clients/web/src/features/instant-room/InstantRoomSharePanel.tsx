import { useCallback, useEffect, useState } from "react";
import { AppIcon } from "../../components/AppIcon";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { formatDateTime } from "../../lib/format";
import { isEncryptedUrl } from "../../lib/transportSecurity";
import type { InstantRoom } from "../../types";
import { QrCode } from "../guest/QrCode";

export function InstantRoomSharePanel({
  placement = "banner",
  room,
  shareUrl,
  title,
  participantCount
}: {
  placement?: "banner" | "menu";
  room: InstantRoom;
  shareUrl: string;
  title: string;
  participantCount: number;
}) {
  const [notice, setNotice] = useState("");
  const [expanded, setExpanded] = useState(false);
  const [linkRevealed, setLinkRevealed] = useState(false);
  const [showQr, setShowQr] = useState(false);
  const [qrDownload, setQrDownload] = useState<Blob | null>(null);
  const handleQrReady = useCallback((source: string) => {
    if (!source) {
      setQrDownload(null);
      return;
    }
    try {
      setQrDownload(pngDataUrlToBlob(source));
    } catch {
      setQrDownload(null);
    }
  }, []);
  const secureLink = isEncryptedUrl(shareUrl);
  const lifetime = instantRoomLifetime(room);
  const dialogRef = useModalDialog(
    closeDetails,
    placement === "banner" && expanded
  );

  useEffect(() => {
    if (placement === "banner" && participantCount > 1) {
      setExpanded(false);
      setLinkRevealed(false);
      setShowQr(false);
    }
  }, [participantCount, placement]);

  function closeDetails() {
    setExpanded(false);
    setLinkRevealed(false);
    setShowQr(false);
  }

  async function copyLink() {
    try {
      await copyText(shareUrl);
      setNotice(`${secureLink ? "Secure link" : "Invite link"} copied.`);
      if (placement === "banner") closeDetails();
    } catch {
      if (placement === "menu") {
        setLinkRevealed(true);
        setNotice("Copy failed. The full link is visible so you can copy it manually.");
        return;
      }
      setLinkRevealed(true);
      setShowQr(false);
      setExpanded(true);
      setNotice("Copy failed. The full link is visible so you can copy it manually.");
    }
  }

  async function shareLink() {
    if (!navigator.share) {
      await copyLink();
      return;
    }
    try {
      await navigator.share({
        title: `${title} on K-Comms`,
        text: "Join my K-Comms room. No account is required.",
        url: shareUrl
      });
      setNotice("Share sheet opened.");
      if (placement === "banner") closeDetails();
    } catch (reason: unknown) {
      if (
        !(reason instanceof DOMException) ||
        reason.name !== "AbortError"
      ) {
        if (placement === "menu") setLinkRevealed(true);
        setNotice(
          placement === "menu"
            ? "Sharing was not completed. The full link is visible so you can copy it manually."
            : "Sharing was not completed. The link is still available below."
        );
      }
    }
  }

  async function downloadQrCode() {
    if (!qrDownload) {
      setNotice("The QR code is still being prepared.");
      return;
    }
    const filename = "k-comms-room-invite-qr.png";
    const saveSheetFile = appleMobileSaveSheetFile(qrDownload, filename);
    if (saveSheetFile) {
      try {
        await navigator.share({
          files: [saveSheetFile],
          title: "Room invite QR code"
        });
        setNotice("QR code save sheet opened.");
        return;
      } catch (reason: unknown) {
        if (
          reason instanceof DOMException &&
          reason.name === "AbortError"
        ) {
          return;
        }
      }
    }
    downloadBlob(qrDownload, filename);
    setNotice("QR code downloaded.");
  }

  if (placement === "menu") {
    return (
      <section
        className="instant-room-menu-invite"
        aria-labelledby="instant-room-menu-invite-title"
      >
        <div className="instant-room-menu-invite-heading">
          <span className="instant-room-kicker">Invite people</span>
          <h3 id="instant-room-menu-invite-title">Scan to join</h3>
          <p>Let someone scan this code, or send the invite.</p>
        </div>
        <div className="instant-room-menu-qr-card">
          <div className="instant-room-menu-qr">
            <QrCode
              value={shareUrl}
              label={`Scan to join ${title}`}
              onReady={handleQrReady}
            />
          </div>
          <p className="instant-room-menu-invite-id" dir="ltr">
            {secureLink ? "Secure room invite" : "Test-network room invite"}
          </p>
        </div>
        <div
          className="instant-room-menu-invite-actions"
          role="group"
          aria-label="Invite actions"
        >
          <button
            className="instant-room-menu-invite-action"
            type="button"
            aria-label="Copy invite link"
            onClick={() => void copyLink()}
          >
            <span className="instant-room-menu-invite-action-icon">
              <AppIcon name="copy" />
            </span>
            <span>Copy</span>
          </button>
          <button
            className="instant-room-menu-invite-action"
            type="button"
            aria-label="Download QR code"
            disabled={!qrDownload}
            onClick={() => void downloadQrCode()}
          >
            <span className="instant-room-menu-invite-action-icon">
              <AppIcon name="download" />
            </span>
            <span>Download</span>
          </button>
          <button
            className="instant-room-menu-invite-action"
            type="button"
            aria-label="Share invite link"
            onClick={() => void shareLink()}
          >
            <span className="instant-room-menu-invite-action-icon">
              <AppIcon name="share" />
            </span>
            <span>Share</span>
          </button>
        </div>
        {linkRevealed && (
          <div className="instant-room-menu-link-recovery">
            <label htmlFor="instant-room-menu-share-url">
              {secureLink ? "Secure room link" : "Room invite link"}
            </label>
            <div className="instant-room-menu-link-row">
              <input
                id="instant-room-menu-share-url"
                type="text"
                value={shareUrl}
                readOnly
                spellCheck={false}
                onFocus={(event) => event.currentTarget.select()}
              />
              <button
                className="button ghost"
                type="button"
                onClick={() => setLinkRevealed(false)}
              >
                Hide
              </button>
            </div>
          </div>
        )}
        <p className="instant-room-lifetime">{lifetime}</p>
        {!secureLink && (
          <p className="transport-warning" role="note">
            <strong>This invite uses unencrypted HTTP.</strong>
            <span>Share it only on a trusted test network.</span>
          </p>
        )}
        <p
          className={`instant-room-copy-notice${notice ? "" : " sr-only"}`}
          role="status"
          aria-live="polite"
        >
          {notice || "Invite QR ready."}
        </p>
      </section>
    );
  }

  return (
    <>
      <section className="instant-room-share collapsed" aria-label="Invite people">
        <div className="instant-room-share-compact-copy">
          <strong>Invite people</strong>
          <span>{participantCount} {participantCount === 1 ? "participant" : "participants"}</span>
          {notice && <span className="instant-room-copy-notice" role="status">{notice}</span>}
        </div>
        <div className="instant-room-share-actions">
          <button
            className="button primary"
            type="button"
            aria-label="Invite people"
            aria-expanded={expanded}
            aria-controls="instant-room-invite-dialog"
            onClick={() => setExpanded(true)}
          >
            Invite
          </button>
          <button
            className="button ghost"
            type="button"
            aria-label="Copy invite link"
            onClick={() => void copyLink()}
          >
            Copy
          </button>
        </div>
      </section>

      {expanded && (
        <div
          className="instant-room-invite-backdrop"
          onPointerDown={(event) => {
            if (event.currentTarget === event.target) closeDetails();
          }}
        >
          <section
            ref={dialogRef}
            className={`instant-room-share instant-room-invite-dialog${
              showQr ? " has-qr" : ""
            }`}
            id="instant-room-invite-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="instant-share-title"
          >
            <div className="instant-room-share-copy">
              <span className="instant-room-kicker">Ready to share</span>
              <div className="instant-room-share-heading">
                <h2 id="instant-share-title" tabIndex={-1} data-initial-focus>
                  Invite someone
                </h2>
                <AppSurfaceControlButton
                  accessibleLabel="Hide invite details"
                  className="app-menu-close"
                  kind="close"
                  label="Hide invite details"
                  showLabel
                  onClick={closeDetails}
                />
              </div>
              <p className="instant-room-share-guidance">
                Show the QR code only when someone is ready to scan it.
              </p>
              <label htmlFor="instant-room-share-url">
                {secureLink ? "Secure room link" : "Room invite link"}
              </label>
              <div className="instant-room-link-row">
                <input
                  id="instant-room-share-url"
                  type="text"
                  value={linkRevealed ? shareUrl : maskedShareUrl(shareUrl)}
                  readOnly
                  spellCheck={false}
                  onFocus={(event) => event.currentTarget.select()}
                />
                <button
                  className="button ghost"
                  type="button"
                  aria-pressed={linkRevealed}
                  onClick={() => setLinkRevealed((current) => !current)}
                >
                  {linkRevealed ? "Hide" : "Reveal"}
                </button>
                <button className="button primary" type="button" onClick={() => void copyLink()}>
                  Copy
                </button>
                <button className="button ghost" type="button" onClick={() => void shareLink()}>
                  Share
                </button>
              </div>
              <button
                className="button ghost instant-room-qr-toggle"
                type="button"
                aria-expanded={showQr}
                aria-controls="instant-room-qr-panel"
                onClick={() => setShowQr((current) => !current)}
              >
                {showQr ? "Hide QR code" : "Show QR code"}
              </button>
              <p className="instant-room-lifetime">
                {lifetime}
              </p>
              {!secureLink && (
                <p className="transport-warning" role="note">
                  <strong>This invite uses unencrypted HTTP.</strong>
                  <span>
                    Share it only on a trusted test network and keep content
                    non-sensitive. Calls and account actions require HTTPS.
                  </span>
                </p>
              )}
              <p className="instant-room-continuity">
                {room.owner_kind === "registered"
                  ? "Keep this tab open while hosting. Your signed-in account can reopen this room."
                  : "Keep this tab open to manage the room. Create an account if you want to keep access across devices."}
              </p>
              <p className="sr-only" role="status" aria-live="polite">{notice}</p>
              {notice && <p className="instant-room-copy-notice" aria-hidden="true">{notice}</p>}
            </div>
            {showQr && (
              <div className="instant-room-qr-panel" id="instant-room-qr-panel">
                <QrCode value={shareUrl} label={`Scan to join ${title}`} />
                <p>Anyone who scans this code can use the room invite.</p>
              </div>
            )}
          </section>
        </div>
      )}
    </>
  );
}

function instantRoomLifetime(room: InstantRoom): string {
  return room.expires_at
    ? `Available until ${formatDateTime(room.expires_at)}.`
    : room.owner_kind === "registered"
      ? "Available for 24 hours after everyone leaves."
      : "Available for 1 hour after everyone leaves.";
}

function maskedShareUrl(shareUrl: string): string {
  const fragmentIndex = shareUrl.indexOf("#");
  if (fragmentIndex < 0) return shareUrl;
  return `${shareUrl.slice(0, fragmentIndex)}#guest=••••••••••••`;
}

function pngDataUrlToBlob(source: string): Blob {
  const [, payload = ""] = source.split(",", 2);
  if (!source.startsWith("data:image/png;base64,") || !payload) {
    throw new Error("Invalid QR image");
  }
  const binary = window.atob(payload);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new Blob([bytes], { type: "image/png" });
}

function appleMobileSaveSheetFile(
  blob: Blob,
  filename: string
): File | null {
  const appleMobile =
    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (
    !appleMobile ||
    typeof navigator.share !== "function" ||
    typeof navigator.canShare !== "function"
  ) {
    return null;
  }
  const file = new File([blob], filename, { type: "image/png" });
  return navigator.canShare({ files: [file] }) ? file : null;
}

function downloadBlob(blob: Blob, filename: string) {
  const source = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = source;
  link.download = filename;
  link.rel = "noopener";
  link.hidden = true;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(source), 30_000);
}

async function copyText(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const fallback = document.createElement("textarea");
  fallback.value = value;
  fallback.setAttribute("readonly", "");
  fallback.style.position = "fixed";
  fallback.style.opacity = "0";
  document.body.appendChild(fallback);
  fallback.select();
  const copied = document.execCommand("copy");
  fallback.remove();
  if (!copied) throw new Error("Copy was rejected");
}
