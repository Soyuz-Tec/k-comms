import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { sha256Hex } from "../../lib/sha256";
import { isEncryptedUrl } from "../../lib/transportSecurity";

export function QrCode({
  value,
  label
}: {
  value: string;
  label: string;
}) {
  const [source, setSource] = useState("");
  const [fingerprint, setFingerprint] = useState("");
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let current = true;
    setSource("");
    setFingerprint("");
    setFailed(false);
    void QRCode.toDataURL(value, {
      errorCorrectionLevel: "M",
      margin: 2,
      width: 256,
      color: {
        dark: "#12302d",
        light: "#ffffff"
      }
    }).then((result) => {
      if (current) setSource(result);
    }).catch(() => {
      if (current) setFailed(true);
    });
    void qrValueFingerprint(value).then((result) => {
      if (current) setFingerprint(result);
    }).catch(() => {
      if (current) setFailed(true);
    });
    return () => {
      current = false;
    };
  }, [value]);

  if (failed) {
    return (
      <div className="guest-qr-unavailable" role="status">
        QR unavailable. Copy the{" "}
        {isEncryptedUrl(value) ? "secure link" : "invite link"} instead.
      </div>
    );
  }

  return (
    <div
      className="guest-qr"
      aria-busy={!source || !fingerprint}
      data-qr-fingerprint={fingerprint || undefined}
    >
      {source ? (
        <img src={source} alt={label} width="256" height="256" />
      ) : (
        <span className="spinner" aria-hidden="true" />
      )}
    </div>
  );
}

export async function qrValueFingerprint(value: string): Promise<string> {
  return `sha256:${await sha256Hex(new TextEncoder().encode(value))}`;
}
