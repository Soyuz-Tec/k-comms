import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { QrCode } from "./QrCode";

const qrHarness = vi.hoisted(() => ({
  toDataURL: vi.fn()
}));

vi.mock("qrcode", () => ({
  default: {
    toDataURL: qrHarness.toDataURL
  }
}));

describe("QrCode", () => {
  beforeEach(() => {
    qrHarness.toDataURL.mockReset().mockResolvedValue("data:image/png;base64,qr");
  });

  afterEach(() => vi.unstubAllGlobals());

  it("encodes the exact guest URL with no mutation", async () => {
    const value = "https://comms.example.test/join#guest=one%2Btoken";
    render(<QrCode value={value} label="Scan to join Project room" />);

    await waitFor(() => expect(qrHarness.toDataURL).toHaveBeenCalled());

    expect(qrHarness.toDataURL).toHaveBeenCalledWith(
      value,
      expect.objectContaining({ errorCorrectionLevel: "M", width: 256 })
    );
    expect(await screen.findByRole("img", { name: "Scan to join Project room" })).toHaveAttribute(
      "src",
      "data:image/png;base64,qr"
    );
    await waitFor(() =>
      expect(screen.getByRole("img").parentElement).toHaveAttribute(
        "data-qr-fingerprint",
        "sha256:673304175e437e4568fa8376f418d33dc2e5cb06bd935feab457dee85f4c3fa0"
      )
    );
    expect(screen.getByRole("img").parentElement).not.toHaveAttribute("data-qr-value");
  });

  it("keeps a generated QR visible when SubtleCrypto is unavailable on plain LAN HTTP", async () => {
    vi.stubGlobal("crypto", {});
    render(
      <QrCode
        value="http://192.168.1.177:4188/join#guest=lan-token"
        label="Scan to join LAN room"
      />
    );

    await waitFor(() =>
      expect(screen.getByRole("img", { name: "Scan to join LAN room" }).parentElement)
        .toHaveAttribute(
          "data-qr-fingerprint",
          "sha256:80cbd1a51d37e71b1a497648abfa0dab11fa5f225f5e7cf10212e6a8e1be44c1"
        )
    );
    expect(screen.queryByText("QR unavailable. Copy the secure link instead.")).not
      .toBeInTheDocument();
  });

  it("does not call an HTTP invitation secure when QR generation fails", async () => {
    qrHarness.toDataURL.mockRejectedValue(new Error("QR failed"));
    render(
      <QrCode
        value="http://192.168.1.177:4188/join#guest=lan-token"
        label="Scan to join LAN room"
      />
    );

    expect(
      await screen.findByText("QR unavailable. Copy the invite link instead.")
    ).toBeVisible();
  });
});
