import { describe, expect, it } from "vitest";
import { isRasterSignature } from "./boardAssetFiles";

describe("approved raster image boundary", () => {
  it("rejects SVG, inline markup and a MIME mismatch", () => {
    const svg = new TextEncoder().encode('<svg onload="alert(1)"></svg>');
    expect(isRasterSignature(svg, "image/png")).toBe(false);
    expect(isRasterSignature(svg, "image/svg+xml")).toBe(false);
    expect(isRasterSignature(new Uint8Array([255, 216, 255, 0]), "image/png")).toBe(false);
  });
  it("recognizes only the supported raster signatures", () => {
    expect(isRasterSignature(new Uint8Array([137,80,78,71,13,10,26,10]), "image/png")).toBe(true);
    expect(isRasterSignature(new Uint8Array([255,216,255]), "image/jpeg")).toBe(true);
    expect(isRasterSignature(new TextEncoder().encode("GIF89a"), "image/gif")).toBe(true);
    expect(isRasterSignature(new TextEncoder().encode("RIFFxxxxWEBP"), "image/webp")).toBe(true);
  });
});
