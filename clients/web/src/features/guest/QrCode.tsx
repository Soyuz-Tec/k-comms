import { useEffect, useRef, useState } from "react";
import QRCode from "qrcode";
import { sha256Hex } from "../../lib/sha256";
import { isEncryptedUrl } from "../../lib/transportSecurity";

export function QrCode({
  value,
  label,
  onReady
}: {
  value: string;
  label: string;
  onReady?: (source: string) => void;
}) {
  const [source, setSource] = useState("");
  const [fingerprint, setFingerprint] = useState("");
  const [failed, setFailed] = useState(false);
  const onReadyRef = useRef(onReady);

  useEffect(() => {
    onReadyRef.current = onReady;
  }, [onReady]);

  useEffect(() => {
    let current = true;
    setSource("");
    setFingerprint("");
    setFailed(false);
    onReadyRef.current?.("");
    void createQrDataUrl(value).then((result) => {
      if (current) {
        setSource(result);
        onReadyRef.current?.(result);
      }
    }).catch(() => {
      if (current) {
        setFailed(true);
        onReadyRef.current?.("");
      }
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

export function createQrDataUrl(value: string): Promise<string> {
  return QRCode.toDataURL(value, {
    errorCorrectionLevel: "H",
    margin: 4,
    width: 320,
    color: {
      dark: "#0b1220",
      light: "#ffffff"
    }
  });
}

export async function qrValueFingerprint(value: string): Promise<string> {
  return `sha256:${await sha256Hex(new TextEncoder().encode(value))}`;
}
