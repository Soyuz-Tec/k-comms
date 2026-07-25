import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
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

  it("encodes the exact guest URL with no mutation", async () => {
    const value = "https://comms.example.test/join#guest=one%2Btoken";
    render(<QrCode value={value} label="Scan to join Project room" />);

    await waitFor(() => expect(qrHarness.toDataURL).toHaveBeenCalled());

    expect(qrHarness.toDataURL).toHaveBeenCalledWith(
      value,
      expect.objectContaining({ errorCorrectionLevel: "M", width: 256 })
    );
    expect(screen.getByRole("img", { name: "Scan to join Project room" })).toHaveAttribute(
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
});
