import { useEffect, useState } from "react";
import QRCode from "qrcode";

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
        QR unavailable. Copy the secure link instead.
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
  const digest = await globalThis.crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value)
  );
  const hexadecimal = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
  return `sha256:${hexadecimal}`;
}
